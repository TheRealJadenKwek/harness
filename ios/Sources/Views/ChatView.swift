import SwiftUI
import UIKit
import PhotosUI

struct ChatView: View {
    let threadID: String
    @EnvironmentObject var app: AppState
    @StateObject private var vm: ChatViewModel
    @State private var input = ""
    @State private var showCd = false
    @State private var cdInput = ""
    @State private var showCommands = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showModelCustom = false
    @State private var modelCustomText = ""
    @State private var atBottom = true          // is the scroll parked at the latest message?
    @State private var viewportH: CGFloat = 0
    @State private var didInitialScroll = false
    @StateObject private var speech = SpeechRecognizer()
    @State private var speechBase = ""          // text already in the box when dictation started
    @State private var showMicHelp = false
    @State private var showPreview = false
    @State private var loadingArtifacts = false
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var inputFocused = false
    @State private var draftTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    private var draftKey: String { "draft_\(threadID)" }

    private func engineOf(_ providerId: String) -> String {
        app.providers.first { $0.id == providerId }?.engine ?? "claude"
    }

    private func providerLabel(_ providerId: String) -> String {
        app.providers.first { $0.id == providerId }?.label ?? providerId
    }

    private func providerModels(_ providerId: String) -> [ModelOption] {
        if let p = app.providers.first(where: { $0.id == providerId }) {
            if let m = p.models, !m.isEmpty { return m }
            return ModelCatalog.options(for: p.engine)
        }
        return ModelCatalog.options(for: engineOf(providerId))
    }
    private func defaultModelText(_ providerId: String) -> String {
        if let dm = app.providers.first(where: { $0.id == providerId })?.default_model, !dm.isEmpty {
            return "Default (\(dm))"
        }
        return "Default"
    }
    private func defaultEffortText(_ providerId: String) -> String {
        if let de = app.providers.first(where: { $0.id == providerId })?.default_effort, !de.isEmpty {
            return "Default (\(de))"
        }
        return "Default"
    }
    private func modelLabelText(_ providerId: String, _ value: String) -> String {
        providerModels(providerId).first { $0.value == value }?.label ?? value
    }
    private func providerDefaultEffort(_ providerId: String) -> String? {
        app.providers.first { $0.id == providerId }?.default_effort
    }
    // Engines without a config default effort (Claude) drop the "Default" option, so use High.
    private func coerceEffort() {
        if let p = app.providers.first(where: { $0.id == vm.provider }),
           p.default_effort == nil, vm.effort == "default" {
            vm.effort = "high"
        }
    }

    init(threadID: String) {
        self.threadID = threadID
        _vm = StateObject(wrappedValue: ChatViewModel(threadID: threadID,
                                                      api: HarnessAPI(baseURL: "", token: "")))
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespaces).isEmpty || !vm.pendingImageData.isEmpty
    }

    @ViewBuilder private func messageList(_ proxy: ScrollViewProxy) -> some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(vm.messages) { m in
                MessageBubble(message: m,
                              interactive: m.id == vm.messages.last?.id && !vm.isStreaming,
                              onAnswer: { vm.answer($0) })
                    .equatable()     // skip re-render (and markdown re-parse) when this message is unchanged
            }
            // The streaming reply observes vm.buf only, so token updates re-render JUST this bubble —
            // not the whole ChatView (keyboard/field/scroll), which was hanging the device.
            if vm.isStreaming {
                StreamingBubbleHost(buf: vm.buf, onGrow: { followBottom(proxy, animated: false) })
            }
            if let e = vm.errorText {
                Text(e).foregroundStyle(.red).font(.footnote)
            }
            // bottom sentinel: reports its position so we know if we're parked at the latest
            Color.clear.frame(height: 1).id("bottom")
                .background(GeometryReader { g in
                    Color.clear.preference(key: BottomOffsetKey.self,
                                           value: g.frame(in: .named("chatScroll")).maxY)
                })
        }
    }

    private var viewportReader: some View {
        GeometryReader { g in
            Color.clear
                .onAppear { viewportH = g.size.height }
                .onChange(of: g.size.height) { _, h in viewportH = h }
        }
    }

    private func handlePhotoPick(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoItems = []
        Task {
            for item in items {
                guard let d = try? await item.loadTransferable(type: Data.self) else { continue }
                let jpeg: Data? = await Task.detached(priority: .userInitiated) {
                    guard let ui = UIImage(data: d) else { return nil }
                    return downscaledJPEG(ui)
                }.value
                if let jpeg { await MainActor.run { vm.pendingImageData.append(jpeg) } }
            }
        }
    }

    private func followBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard atBottom else { return }            // only follow if the user hasn't scrolled up to read
        if animated { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
        else { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    /// One scrollTo in a LazyVStack lands on ESTIMATED item heights; once items realize their
    /// true (much taller) sizes the offset is stale and the viewport can strand past the content
    /// — a blank screen. Re-pin after layout settles.
    private func pinToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo("bottom", anchor: .bottom)
        atBottom = true
        for delay in [0.3, 0.9, 1.8] {      // late pins bail if the user has scrolled up to read
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if atBottom { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private func jumpButton(_ proxy: ScrollViewProxy) -> some View {
        if !atBottom {
            Button {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom); atBottom = true }
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.appText)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.appSurface))
                    .overlay(Circle().stroke(Color.appBorder, lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            .padding(.trailing, 16).padding(.bottom, 8)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var coreStack: some View {
        VStack(spacing: 0) {
            contextBar
            Divider().overlay(Color.appBorder)
            ScrollViewReader { proxy in
                ScrollView {
                    messageList(proxy)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                }
                .coordinateSpace(name: "chatScroll")
                .background(viewportReader)
                .onPreferenceChange(BottomOffsetKey.self) { maxY in
                    // Ignore pre-layout (viewportH==0) and keyboard transitions (focused), which
                    // shrink the viewport and would otherwise falsely flip us off the bottom.
                    guard viewportH > 0, !inputFocused else { return }
                    let nearBottom = maxY <= viewportH + 120
                    if nearBottom != atBottom { atBottom = nearBottom }
                }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(TapGesture().onEnded {   // tap anywhere above to drop the keyboard
                    if inputFocused {
                        inputFocused = false
                        // resign immediately so the bar rides down *with* the keyboard (not a frame behind)
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                        to: nil, from: nil, for: nil)
                    }
                })
                .onChange(of: vm.messages.count) { _, _ in
                    if !didInitialScroll {                 // first open -> land on the latest, unconditionally
                        didInitialScroll = true
                        DispatchQueue.main.async { pinToBottom(proxy) }
                    } else { followBottom(proxy, animated: true) }
                }
                .onChange(of: vm.isStreaming) { was, now in   // turn ended -> content swapped; re-pin
                    if was && !now && atBottom { DispatchQueue.main.async { pinToBottom(proxy) } }
                }
                .onChange(of: inputFocused) { _, f in     // re-pin when the keyboard opens at the bottom
                    if f && atBottom { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .overlay(alignment: .bottomTrailing) { jumpButton(proxy) }
            }
            if !vm.pendingImageData.isEmpty {
                PendingImagesStrip(images: $vm.pendingImageData)
            }
            inputBar
        }
    }

    private var chrome: some View {
        coreStack
            .background(Color.appBG)
            .navigationTitle(vm.detail?.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.appBG, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { toolbarContent }
    }

    private var lifecycle: some View {
        chrome
        .task {
            vm.api = app.api
            if input.isEmpty { input = UserDefaults.standard.string(forKey: draftKey) ?? "" }
            if vm.messages.isEmpty { await vm.load() }
            if vm.detail?.running == true { vm.reconnectIfRunning() }
            app.markSeen(threadID, count: vm.messages.count)
            coerceEffort()
        }
        .onChange(of: input) { _, v in
            // Debounced: a per-keystroke write copies the whole draft, which drags on long prompts.
            draftTask?.cancel()
            let key = draftKey
            draftTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                if v.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
                else { UserDefaults.standard.set(v, forKey: key) }
            }
        }
        .onChange(of: speech.transcript) { _, t in
            guard speech.isRecording, !t.isEmpty else { return }
            input = speechBase.isEmpty ? t : speechBase + " " + t   // append dictation to existing text
        }
        .onChange(of: speech.status) { _, s in if s == .denied { showMicHelp = true } }
        .onChange(of: vm.isStreaming) { was, now in              // a turn finished while viewing -> mark seen
            if was && !now { app.markSeen(threadID, count: vm.messages.count) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await vm.resync() } }   // resync never clobbers an in-flight turn
            else { speech.stop() }                                // background -> stop dictation cleanly
        }
        .onAppear { PushManager.currentThreadID = threadID }   // suppress this thread's completion banners
        .onDisappear {
            draftTask?.cancel()                                    // flush the debounced draft now
            if input.isEmpty { UserDefaults.standard.removeObject(forKey: draftKey) }
            else { UserDefaults.standard.set(input, forKey: draftKey) }
            app.markSeen(threadID, count: vm.messages.count)
            if PushManager.currentThreadID == threadID { PushManager.currentThreadID = nil }
        }
    }

    var body: some View {
        lifecycle
        .alert("Microphone access needed", isPresented: $showMicHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable Microphone and Speech Recognition for Harness in Settings to dictate.")
        }
        .onChange(of: vm.provider) { _, _ in coerceEffort() }
        .alert("Change directory", isPresented: $showCd) {
            TextField("~/path/to/repo", text: $cdInput)
            Button("Set") { vm.pendingCwd = cdInput.trimmingCharacters(in: .whitespaces) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your next message runs in this directory (starts a fresh session there).")
        }
        .alert("Custom model", isPresented: $showModelCustom) {
            TextField("model id", text: $modelCustomText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Set") { vm.model = modelCustomText.trimmingCharacters(in: .whitespaces) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Type any model id the CLI supports — including new releases.")
        }
        .sheet(isPresented: $showCommands) {
            SlashCommandPalette(engine: engineOf(vm.provider)) { cmd in
                input = input.isEmpty ? cmd + " " : input + " " + cmd
            }
        }
        .onChange(of: photoItems) { _, items in handlePhotoPick(items) }
        .sheet(isPresented: $showPreview) {
            PreviewView(tid: threadID, artifacts: vm.artifacts, index: 0).environmentObject(app)
        }
        .photosPicker(isPresented: $showLibrary, selection: $photoItems, maxSelectionCount: 4, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in addCapturedImage(img) }.ignoresSafeArea()
        }
    }

    private func pasteImage() {
        if UIPasteboard.general.hasImages, let img = UIPasteboard.general.image {
            Task {
                let jpeg = await Task.detached(priority: .userInitiated) { downscaledJPEG(img) }.value
                if let jpeg { vm.pendingImageData.append(jpeg) }
            }
        }
    }

    private func addCapturedImage(_ img: UIImage) {
        Task {
            let jpeg = await Task.detached(priority: .userInitiated) { downscaledJPEG(img) }.value
            if let jpeg { vm.pendingImageData.append(jpeg) }
        }
    }

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                loadingArtifacts = true
                Task { await vm.loadArtifacts(); loadingArtifacts = false; showPreview = true }
            } label: {
                if loadingArtifacts { ProgressView() }
                else { Image(systemName: "doc.viewfinder") }   // preview artifacts
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Engine", selection: $vm.provider) {
                    ForEach(app.enabledProviders) { p in Text(p.label).tag(p.id) }
                }
                Picker("Model", selection: $vm.model) {
                    Text(defaultModelText(vm.provider)).tag("")
                    ForEach(providerModels(vm.provider), id: \.value) { o in
                        Text(o.label).tag(o.value)
                    }
                    if !vm.model.isEmpty && !providerModels(vm.provider).contains(where: { $0.value == vm.model }) {
                        Text(vm.model).tag(vm.model)
                    }
                }
                Button {
                    modelCustomText = vm.model
                    showModelCustom = true
                } label: { Label("Custom model…", systemImage: "pencil") }
                Picker("Permissions", selection: $vm.permissionMode) {
                    Text("Full access").tag("bypass")
                    Text("Plan only").tag("plan")
                    Text("Accept edits").tag("acceptEdits")
                    Text("Ask (read-only)").tag("default")
                }
                Picker("Effort", selection: $vm.effort) {
                    if providerDefaultEffort(vm.provider) != nil {
                        Text(defaultEffortText(vm.provider)).tag("default")
                    }
                    ForEach(EffortCatalog.options(for: engineOf(vm.provider)).filter { $0.value != "default" }, id: \.value) { o in
                        Text(o.label).tag(o.value)
                    }
                }
                Button {
                    cdInput = vm.detail?.cwd ?? ""
                    showCd = true
                } label: {
                    Label("Change directory", systemImage: "folder")
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .tint(Color.appText)
        }
    }

    var contextBar: some View {
        HStack(spacing: 8) {
            Image(systemName: engineIcon(vm.detail?.engine))
            Text(vm.model.isEmpty ? providerLabel(vm.provider)
                                  : providerLabel(vm.provider) + " · " + modelLabelText(vm.provider, vm.model))
            if vm.permissionMode != "bypass" {
                Text(permLabel(vm.permissionMode))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.appSecondary.opacity(0.18))
                    .foregroundStyle(Color.appText)
                    .clipShape(Capsule())
            }
            if vm.effort != "default" {
                Text(EffortCatalog.label(for: vm.effort, engine: engineOf(vm.provider)))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.appSecondary.opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()
            if let cwd = vm.detail?.cwd, cwd != NSHomeDirectory() {
                Label((cwd as NSString).lastPathComponent, systemImage: "folder")
            }
        }
        .font(.caption2)
        .foregroundStyle(Color.appSecondary)
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(Color.appBG)
    }

    func permLabel(_ m: String) -> String {
        switch m {
        case "plan": return "plan"
        case "acceptEdits": return "auto-edit"
        case "default": return "ask"
        default: return m
        }
    }

    var inputBar: some View {
        HStack(alignment: .center, spacing: 2) {
            Menu {
                Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                Button { showLibrary = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                Button { pasteImage() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 21))
                    .foregroundStyle(Color.appSecondary)
                    .frame(width: 36, height: 36)
            }
            if !CommandCatalog.commands(for: engineOf(vm.provider)).isEmpty {
                Button { showCommands = true } label: {
                    Image(systemName: "slash.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.appSecondary)
                        .frame(width: 36, height: 36)
                }
            }
            GrowingTextView(text: $input, focused: $inputFocused,
                            placeholder: speech.isRecording ? "Listening…" : "Message…")
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 4)
            // Tap to start dictation, tap again to stop (on-device when available).
            Button {
                if speech.isRecording {
                    speech.stop()
                } else {
                    speechBase = input
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    speech.start()
                }
            } label: {
                Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 19))
                    .foregroundStyle(speech.isRecording ? Color.red : Color.appSecondary)
                    .frame(width: 34, height: 34)
                    .scaleEffect(speech.isRecording ? 1.15 : 1)
                    .animation(.easeInOut(duration: 0.15), value: speech.isRecording)
            }
            if vm.isStreaming {
                Button { vm.stop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.appBG)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.appText))
                }
            } else {
                Button {
                    if vm.send(input) {
                        input = ""                      // clear (and drop draft) only once it's enqueued
                        inputFocused = false             // drop the keyboard so it's out of the streaming layout
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                        to: nil, from: nil, for: nil)
                    }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.appBG)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(canSend ? Color.claudeAccent : Color.appSecondary.opacity(0.4)))
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.appSurface)
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Color.appBorder, lineWidth: 1))
        )
        .padding(.horizontal, 12).padding(.bottom, 8).padding(.top, 4)
        .background(Color.appBG)
    }
}

// Reports the bottom sentinel's position within the scroll viewport, so ChatView can tell
// whether the user is parked at the latest message (auto-follow) or has scrolled up to read.
struct BottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct MessageBubble: View, Equatable {
    let message: Message
    var interactive: Bool = false
    var onAnswer: ((String) -> Void)? = nil
    var isUser: Bool { message.role == "user" }

    // Ignore the closure; identity is the message content + interactivity.
    static func == (l: MessageBubble, r: MessageBubble) -> Bool {
        l.message == r.message && l.interactive == r.interactive
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let n = message.images, n > 0 {
                Label("\(n) image\(n == 1 ? "" : "s")", systemImage: "photo")
                    .font(.caption2).foregroundStyle(Color.appSecondary)
            }
            if !isUser, let t = message.thinking, !t.isEmpty {
                ThinkingDisclosure(text: t, live: false)
            }
            if let tools = message.tools, !tools.isEmpty {
                ToolList(tools: tools)
            }
            if isUser {
                // Collapsible: a giant pasted prompt as one Text hung layout the moment it was sent.
                CollapsibleText(text: message.text).foregroundStyle(Color.appText)
            } else {
                MarkdownText(text: message.text).foregroundStyle(Color.appText)
            }
            if !isUser, let qs = message.questions, !qs.isEmpty {
                QuestionGroup(questions: qs, interactive: interactive, onSubmit: { onAnswer?($0) })
            }
            if let u = message.usage, let footer = usageFooter(u) {
                Text(footer).font(.caption2).foregroundStyle(Color.appSecondary)
            }
        }
    }

    var body: some View {
        if isUser {
            HStack {
                Spacer(minLength: 48)
                content
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.userBubble)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .contextMenu { copyButton }
        } else {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu { copyButton }
        }
    }

    private var copyButton: some View {
        Button { UIPasteboard.general.string = message.text } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }
}

/// Observes ONLY the StreamBuffer, so streaming tokens re-render this view alone (not ChatView).
/// Reports growth via `onGrow` so the parent can keep the scroll pinned without observing the buffer.
struct StreamingBubbleHost: View {
    @ObservedObject var buf: StreamBuffer
    var onGrow: () -> Void
    @State private var lastGrow = Date.distantPast
    var body: some View {
        StreamingBubble(buf: buf)
            .onChange(of: buf.growTick) { _, _ in throttledGrow() }
    }
    // Auto-scroll at most ~4x/sec while streaming — each scrollTo forces a scroll-content layout
    // pass, and doing that on every token (with the keyboard up) was pegging the main thread.
    private func throttledGrow() {
        let now = Date()
        guard now.timeIntervalSince(lastGrow) >= 0.25 else { return }
        lastGrow = now
        onGrow()
    }
}

/// The reply streams as finalized chunk Texts plus one small mutable tail — each flush re-lays
/// out only the tail, so cost per flush is flat no matter how long the reply grows. Older chunks
/// beyond the live window are summarized; the full text lands as the finalized message on done.
struct StreamingBubble: View {
    @ObservedObject var buf: StreamBuffer
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if buf.thinkingChars > 0 {
                ThinkingDisclosure(
                    text: (buf.thinkingChars > buf.thinkingTail.count ? "… " : "") + buf.thinkingTail,
                    live: true)
            }
            ForEach(Array(buf.tools.enumerated()), id: \.offset) { _, t in
                ToolRow(tool: t)
            }
            if buf.trimmedChars > 0 {
                Text("… earlier output (\(buf.trimmedChars.formatted()) chars) — full reply shown when finished")
                    .font(.caption2).foregroundStyle(Color.appSecondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(buf.chunks) { c in
                    Text(c.text).foregroundStyle(Color.appText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !buf.tail.isEmpty {
                    Text(buf.tail).foregroundStyle(Color.appText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !buf.questions.isEmpty {
                QuestionGroup(questions: buf.questions, interactive: false, onSubmit: { _ in })
            }
            if buf.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.callout).foregroundStyle(Color.appSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Coordinates EVERY question in one AskUserQuestion call (Claude often asks 2–4 at once):
/// accumulates a selection per question, keeps all cards live until each is answered, then
/// sends ONE combined reply. A lone single-select question auto-submits on tap for snappiness.
struct QuestionGroup: View {
    let questions: [AskQuestion]
    let interactive: Bool
    let onSubmit: (String) -> Void

    @State private var selections: [Int: Set<String>] = [:]
    @State private var submitted = false
    @State private var otherFor: Int? = nil
    @State private var otherText = ""

    private var autoSubmitSingle: Bool { questions.count == 1 && !(questions[0].multiSelect ?? false) }
    private var answeredCount: Int { questions.indices.filter { !(selections[$0]?.isEmpty ?? true) }.count }
    private var allAnswered: Bool { answeredCount == questions.count && !questions.isEmpty }
    private var enabled: Bool { interactive && !submitted }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(questions.enumerated()), id: \.offset) { idx, q in
                QuestionCardView(question: q, enabled: enabled, selected: selections[idx] ?? [],
                                 onPick: { pick(idx, q, $0) },
                                 onOther: { otherText = ""; otherFor = idx })
            }
            if enabled && !autoSubmitSingle {
                Button { submit() } label: {
                    Text(questions.count > 1 ? "Send answers (\(answeredCount)/\(questions.count))" : "Send answer")
                        .font(.subheadline).bold()
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(allAnswered ? Color.appText : Color.appSurface)
                        .foregroundStyle(allAnswered ? Color.appBG : Color.appSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain).disabled(!allAnswered)
            }
        }
        .alert("Your answer", isPresented: Binding(get: { otherFor != nil }, set: { if !$0 { otherFor = nil } })) {
            TextField("Type a reply", text: $otherText)
            Button("OK") {
                if let idx = otherFor {
                    let t = otherText.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { selections[idx] = [t]; if autoSubmitSingle { submit() } }
                }
                otherFor = nil
            }
            Button("Cancel", role: .cancel) { otherFor = nil }
        }
    }

    private func pick(_ idx: Int, _ q: AskQuestion, _ label: String) {
        guard enabled else { return }
        var set = selections[idx] ?? []
        if q.multiSelect ?? false {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = [label]
        }
        selections[idx] = set
        if autoSubmitSingle { submit() }
    }

    private func submit() {
        guard enabled, allAnswered else { return }
        submitted = true
        let parts: [String] = questions.enumerated().map { idx, q in
            let label = (q.header.flatMap { $0.isEmpty ? nil : $0 }) ?? q.question
            let chosen = (selections[idx] ?? []).sorted().joined(separator: ", ")
            return "\(label): \(chosen)"
        }
        onSubmit(parts.joined(separator: "\n"))
    }
}

/// One presentational question card (no submit logic — the group owns that).
struct QuestionCardView: View {
    let question: AskQuestion
    let enabled: Bool
    let selected: Set<String>
    let onPick: (String) -> Void
    let onOther: () -> Void

    private var multi: Bool { question.multiSelect ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let h = question.header, !h.isEmpty {
                Text(h.uppercased()).font(.caption2).bold().foregroundStyle(Color.appSecondary)
            }
            Text(question.question).font(.callout).foregroundStyle(Color.appText)
            VStack(spacing: 6) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { _, opt in
                    optionRow(opt)
                }
                Button { onOther() } label: {
                    HStack { Image(systemName: "square.and.pencil"); Text("Other…"); Spacer() }
                        .font(.subheadline).foregroundStyle(Color.appSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.appSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain).disabled(!enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSecondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.appBorder, lineWidth: 1))
    }

    @ViewBuilder
    private func optionRow(_ opt: AskOption) -> some View {
        let isPicked = selected.contains(opt.label)
        Button { onPick(opt.label) } label: {
            HStack(alignment: .top, spacing: 8) {
                if multi {
                    Image(systemName: isPicked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isPicked ? Color.appText : Color.appSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(opt.label).font(.subheadline).bold().foregroundStyle(Color.appText)
                    if let d = opt.description, !d.isEmpty {
                        Text(d).font(.caption2).foregroundStyle(Color.appSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isPicked ? Color.appText.opacity(0.10) : Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isPicked ? Color.appText.opacity(0.4) : Color.appBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled && !isPicked)
        .opacity(enabled || isPicked ? 1 : 0.85)
    }
}

struct ThinkingDisclosure: View {
    let text: String
    let live: Bool
    @State private var expanded: Bool

    init(text: String, live: Bool) {
        self.text = text
        self.live = live
        _expanded = State(initialValue: live)   // open while streaming, collapsed once saved
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "brain")
                    Text(live ? "Thinking…" : "Thought process")
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9))
                }
                .font(.caption).foregroundStyle(Color.appSecondary)
            }
            .buttonStyle(.plain)
            if expanded && !text.isEmpty {
                ChunkedText(text: text, font: .caption)   // long reasoning stays cheap to lay out
                    .foregroundStyle(Color.appSecondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.appSecondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

struct ToolList: View {
    let tools: [ToolInfo]
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                Label("\(tools.count) tool\(tools.count == 1 ? "" : "s")",
                      systemImage: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2).foregroundStyle(Color.appSecondary)
            }
            .buttonStyle(.borderless)
            if expanded {
                ForEach(Array(tools.enumerated()), id: \.offset) { _, t in
                    ToolRow(tool: t)
                }
            }
        }
    }
}

struct ToolRow: View {
    let tool: ToolInfo
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if tool.detail != nil { expanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: toolIcon(tool.name))
                        .font(.caption2).foregroundStyle(Color.appSecondary).frame(width: 15)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tool.name == "Task" ? "Agent" : tool.name)
                            .font(.caption2).fontWeight(.semibold).foregroundStyle(Color.appText)
                        if let s = tool.summary, !s.isEmpty {
                            Text(s).font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Color.appSecondary).lineLimit(expanded ? nil : 2)
                        }
                    }
                    Spacer(minLength: 0)
                    if tool.detail != nil {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9)).foregroundStyle(Color.appSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
            if expanded, let detail = tool.detail {
                DiffText(detail)
            }
        }
        .padding(8)
        .background(Color.codeBG.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct DiffText: View {
    let text: String
    init(_ t: String) { text = t }
    private static let maxLines = 250     // a per-line Text each; huge diffs would stall layout
    var body: some View {
        let all = text.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(all.prefix(Self.maxLines).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(lineColor(line))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .background(lineBg(line))
            }
            if all.count > Self.maxLines {
                Text("… \(all.count - Self.maxLines) more lines")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.appSecondary)
                    .padding(.horizontal, 4).padding(.top, 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.leading, 22)
    }
    private func lineColor(_ l: String) -> Color {
        if l.hasPrefix("+ ") { return .green }
        if l.hasPrefix("- ") { return .red }
        return Color.appSecondary
    }
    private func lineBg(_ l: String) -> Color {
        if l.hasPrefix("+ ") { return .green.opacity(0.10) }
        if l.hasPrefix("- ") { return .red.opacity(0.10) }
        return .clear
    }
}

func toolIcon(_ n: String) -> String {
    switch n {
    case "Bash": return "terminal"
    case "Read": return "doc.text"
    case "Edit", "Write", "MultiEdit", "NotebookEdit": return "pencil"
    case "Grep", "Glob": return "magnifyingglass"
    case "WebFetch", "WebSearch": return "globe"
    case "Task": return "person.2"
    case "TodoWrite": return "checklist"
    default: return "wrench.and.screwdriver"
    }
}

func usageFooter(_ u: Usage) -> String? {
    var parts: [String] = []
    if let c = u.cost { parts.append(String(format: "~$%.4f", c)) }   // subscription usage, est. API value
    if let i = u.input_tokens, let o = u.output_tokens {
        parts.append("\(tokStr(i))→\(tokStr(o)) tok")
    }
    if let d = u.duration_ms { parts.append(String(format: "%.1fs", d / 1000)) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

func tokStr(_ n: Int) -> String {
    n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
}
