import Foundation
import Combine
import UIKit

/// One finalized piece of the streaming reply. Its id is monotonic and its text never changes,
/// so SwiftUI keeps the laid-out Text and never re-measures it on later flushes.
struct StreamChunk: Identifiable, Equatable {
    let id: Int
    let text: String
}

/// Fast-changing streaming display state lives here, SEPARATE from ChatViewModel, so token updates
/// re-render ONLY the streaming bubble — not the whole ChatView (whose body carries the UITextView,
/// keyboard avoidance and scroll; re-rendering all of that ~30x/sec hung the device).
///
/// The reply is stored as immutable CHUNKS plus a small mutable TAIL — never one big string.
/// TextKit lays out a single Text in O(length), so re-rendering the entire accumulated reply on
/// every flush went O(n²) and hard-pegged the main thread on long replies (the on-device freeze
/// where only the spinner kept animating). With chunks, each flush re-lays out ≤ ~2k chars no
/// matter how big the reply gets. The live view keeps only the newest chunks; the full text
/// always arrives as the finalized message on `done`.
@MainActor
final class StreamBuffer: ObservableObject {
    @Published private(set) var chunks: [StreamChunk] = []
    @Published private(set) var tail = ""
    @Published private(set) var trimmedChars = 0        // chars dropped from the top of the live view
    @Published private(set) var thinkingTail = ""       // live thinking shows a bounded tail only
    @Published private(set) var thinkingChars = 0
    @Published var tools: [ToolInfo] = []
    @Published var questions: [AskQuestion] = []
    @Published private(set) var growTick = 0            // cheap change signal for scroll-follow

    static let chunkSize = 2000
    static let maxLiveChunks = 8                        // ~16k chars on screen while streaming

    private var nextChunkID = 0

    var isEmpty: Bool {
        chunks.isEmpty && tail.isEmpty && trimmedChars == 0 && thinkingChars == 0
            && tools.isEmpty && questions.isEmpty
    }

    private var tailLines = 0

    func appendText(_ s: String) {
        guard !s.isEmpty else { return }
        tail += s
        tailLines += s.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        // Roll the tail into finalized chunks on char OR line budget (TextChunker enforces both —
        // a Text hundreds of short lines tall overflows the GPU texture cap and draws blank).
        if tail.count > Self.chunkSize || tailLines >= TextChunker.maxLines {
            var pieces = TextChunker.chunks(tail)
            let newTail = pieces.popLast() ?? ""
            for p in pieces {
                chunks.append(StreamChunk(id: nextChunkID, text: p))
                nextChunkID += 1
            }
            tail = newTail
            tailLines = newTail.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        }
        if chunks.count > Self.maxLiveChunks {
            let overflow = chunks.count - Self.maxLiveChunks
            trimmedChars += chunks[..<overflow].reduce(0) { $0 + $1.text.count }
            chunks.removeFirst(overflow)
        }
        growTick &+= 1
    }

    func appendThinking(_ s: String) {
        guard !s.isEmpty else { return }
        thinkingChars += s.count
        thinkingTail += s
        if thinkingTail.count > 2400 { thinkingTail = String(thinkingTail.suffix(1600)) }
        growTick &+= 1
    }

    func noteActivity() { growTick &+= 1 }              // tool/question arrivals move the scroll too

    func reset() {
        chunks = []; tail = ""; tailLines = 0; trimmedChars = 0
        thinkingTail = ""; thinkingChars = 0
        tools = []; questions = []
        nextChunkID = 0
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    let threadID: String
    var api: HarnessAPI

    @Published var detail: ThreadDetail?
    @Published var messages: [Message] = []
    @Published var isStreaming = false
    @Published var errorText: String?

    let buf = StreamBuffer()        // observed by the streaming bubble only — NOT by ChatView

    @Published var provider: String = "claude"
    @Published var model: String = ""        // free-form; empty = provider's default
    @Published var effort: String = "default"
    @Published var pendingCwd: String?
    @Published var permissionMode: String = "bypass"
    @Published var pendingImageData: [Data] = []
    @Published var artifacts: [Artifact] = []

    private var streamTask: Task<Void, Never>?
    private var streamGen = 0
    // Full accumulations, kept for the finalized message on `done` (never rendered live).
    private var textBuf = ""
    private var thinkBuf = ""
    // Deltas not yet pushed to the StreamBuffer — flushed as appends, so no O(n) work per flush.
    private var pendingText = ""
    private var pendingThink = ""
    private var flushPending = false

    init(threadID: String, api: HarnessAPI) {
        self.threadID = threadID
        self.api = api
    }

    func loadArtifacts() async {
        if Demo.active { artifacts = Demo.artifacts(threadID); return }
        artifacts = ((try? await api.artifacts(threadID))?.artifacts) ?? []
    }

    func load() async {
        if Demo.active {
            let d = Demo.detail(threadID)
            detail = d; messages = d.messages
            provider = d.provider
            permissionMode = d.permission_mode ?? "bypass"
            effort = d.effort ?? "default"
            model = d.model ?? ""
            return
        }
        do {
            let d = try await api.thread(threadID)
            detail = d
            messages = d.messages
            provider = d.provider
            permissionMode = d.permission_mode ?? "bypass"
            effort = d.effort ?? "default"
            model = d.model ?? ""
        } catch {
            errorText = error.localizedDescription
        }
    }

    @discardableResult
    func send(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !pendingImageData.isEmpty), !isStreaming else { return false }
        let imgs = pendingImageData.map { "data:image/jpeg;base64," + $0.base64EncodedString() }
        var umsg = Message(role: "user", text: text.isEmpty ? "(image)" : text, ts: nil)
        if !pendingImageData.isEmpty { umsg.images = pendingImageData.count }
        messages.append(umsg)
        pendingImageData = []
        if Demo.active { playDemoResponse(); return true }
        let toSend = text.isEmpty ? "What's in this image?" : text
        let cwd = pendingCwd
        pendingCwd = nil
        let p = provider, m = model, e = effort, pm = permissionMode
        consume(reconnect: false) {
            self.api.stream(threadID: self.threadID, text: toSend, provider: p, cwd: cwd,
                            permissionMode: pm, effort: e, model: m, images: imgs)
        }
        return true
    }

    /// Tapping a multiple-choice option just sends the chosen answer as the next turn.
    func answer(_ text: String) { send(text) }

    /// Foreground resync that never clobbers an in-flight turn's optimistic state.
    func resync() async {
        guard !Demo.active, !isStreaming else { return }
        do {
            let d = try await api.thread(threadID)
            detail = d
            if d.running == true {
                reconnectIfRunning()
            } else {
                guard !isStreaming else { return }
                if d.messages.count != messages.count { messages = d.messages }
                provider = d.provider
                permissionMode = d.permission_mode ?? permissionMode
                effort = d.effort ?? effort
                model = d.model ?? model
            }
        } catch { /* offline; keep what we have */ }
    }

    func reconnectIfRunning() {
        guard !Demo.active, !isStreaming else { return }
        consume(reconnect: true) { self.api.reconnect(threadID: self.threadID) }
    }

    private func consume(reconnect: Bool, _ make: @escaping () -> AsyncThrowingStream<StreamEvent, Error>) {
        streamTask?.cancel()
        streamGen += 1
        let myGen = streamGen
        isStreaming = true
        buf.reset(); textBuf = ""; thinkBuf = ""; pendingText = ""; pendingThink = ""
        flushPending = false; errorText = nil
        streamTask = Task {
            var sawDone = false
            var failed = false
            do {
                for try await ev in make() {
                    guard streamGen == myGen else { break }
                    if reconnect && ev.type == "done" { sawDone = true; break }
                    handle(ev)
                }
            } catch {
                if !(error is CancellationError) {
                    errorText = error.localizedDescription
                    failed = true
                }
            }
            guard streamGen == myGen else { return }
            isStreaming = false
            if reconnect {
                buf.reset()
                if sawDone { await load() }
            }
            // Self-heal a dropped stream: the job keeps running server-side, so re-attach —
            // or, if the turn actually finished while we were dark, pull the final messages.
            if failed { scheduleReheal() }
        }
    }

    private func scheduleReheal() {
        let gen = streamGen
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, self.streamGen == gen, !self.isStreaming, !Demo.active else { return }
            await self.resync()
            if self.detail?.running == true || self.isStreaming { self.errorText = nil }
        }
    }

    private func handle(_ ev: StreamEvent) {
        switch ev.type {
        case "text":
            let d = ev.delta ?? ""
            textBuf += d; pendingText += d; scheduleFlush()
        case "thinking":
            let d = ev.delta ?? ""
            thinkBuf += d; pendingThink += d; scheduleFlush()
        case "tool":
            buf.tools.append(ToolInfo(name: ev.name ?? "tool", summary: ev.summary, detail: ev.detail))
            buf.noteActivity()
        case "question":
            buf.questions.append(contentsOf: ev.questions ?? [])
            buf.noteActivity()
        case "session":
            if let s = ev.id { detail?.session_id = s }
        case "done":
            let final = ev.text ?? textBuf
            var m = Message(role: "assistant", text: final, ts: nil)
            m.id = Message.stableID(role: "assistant", ts: nil, text: final)
            m.tools = ev.tools ?? (buf.tools.isEmpty ? nil : buf.tools)
            m.usage = ev.usage
            m.thinking = ev.thinking ?? (thinkBuf.isEmpty ? nil : thinkBuf)
            m.questions = ev.questions ?? (buf.questions.isEmpty ? nil : buf.questions)
            if !messages.contains(where: { $0.id == m.id }) { messages.append(m) }
            buf.reset(); textBuf = ""; thinkBuf = ""; pendingText = ""; pendingThink = ""
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "error":
            errorText = ev.message ?? "error"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        default:
            break
        }
    }

    /// Coalesce token deltas and push them to the StreamBuffer ~20x/sec. Appends only —
    /// per-flush cost is bounded by the delta size, never by how long the reply has grown.
    private func scheduleFlush() {
        guard !flushPending else { return }
        flushPending = true
        let gen = streamGen
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self, self.streamGen == gen else { return }
            self.flushPending = false
            if !self.pendingText.isEmpty { self.buf.appendText(self.pendingText); self.pendingText = "" }
            if !self.pendingThink.isEmpty { self.buf.appendThinking(self.pendingThink); self.pendingThink = "" }
        }
    }

    /// Plays a canned thinking→reply stream so Demo Mode feels live (no network).
    private func playDemoResponse() {
        streamTask?.cancel()
        streamGen += 1
        let myGen = streamGen
        isStreaming = true
        buf.reset(); textBuf = ""; thinkBuf = ""; pendingText = ""; pendingThink = ""
        flushPending = false; errorText = nil
        let think = Demo.chunks(Demo.thinkingScript)
        let reply = Demo.chunks(Demo.replyScript)
        streamTask = Task {
            var thinkAcc = "", replyAcc = ""
            for c in think {
                guard streamGen == myGen else { return }
                thinkAcc += c
                buf.appendThinking(c)
                try? await Task.sleep(nanoseconds: 26_000_000)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            for c in reply {
                guard streamGen == myGen else { return }
                replyAcc += c
                buf.appendText(c)
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            guard streamGen == myGen else { return }
            var m = Message(role: "assistant", text: replyAcc, ts: nil)
            m.id = Message.stableID(role: "assistant", ts: nil, text: replyAcc)
            m.thinking = thinkAcc
            messages.append(m)
            buf.reset()
            isStreaming = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    func stop() {
        streamTask?.cancel()
        streamGen += 1                       // disarm any pending scheduleFlush
        let id = threadID
        let a = api
        Task { try? await a.stop(id) }
        isStreaming = false
        buf.reset(); textBuf = ""; thinkBuf = ""; pendingText = ""; pendingThink = ""; flushPending = false
    }
}
