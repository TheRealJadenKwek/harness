import SwiftUI

struct ChatView: View {
    @EnvironmentObject var store: Store
    @State var chat: Chat
    @State private var input = ""
    @State private var streaming = false
    @State private var errorText: String?
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(chat.messages) { m in MessageBubble(msg: m) }
                        if streaming && chat.messages.last?.role == "user" {
                            HStack(spacing: 6) {
                                Text("✳").foregroundStyle(Color(red: 0.79, green: 0.39, blue: 0.26))
                                Text("Thinking…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let e = errorText {
                            Text("⚠︎ " + e).font(.caption).foregroundStyle(.red)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 14).padding(.top, 10)
                }
                .onChange(of: chat.messages) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            Divider()
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    TextField("Message…", text: $input, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 20))
                        .onSubmit(send)
                    Button(action: send) {
                        Image(systemName: streaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 30))
                    }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty && !streaming)
                }
                Button { showPicker = true } label: {
                    Label(shortModel(chat.model), systemImage: "cpu")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .navigationTitle(chat.title).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPicker) {
            ModelPickerView(selected: $chat.model)
                .onDisappear { store.defaultModel = chat.model; store.update(chat) }
        }
    }

    private var streamTask: Task<Void, Never>? { nil }

    func send() {
        if streaming { return }   // stop handled implicitly by task cancel on nav; keep simple
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        errorText = nil
        chat.messages.append(Msg(role: "user", content: text))
        if chat.title == "New chat" { chat.title = String(text.prefix(42)) }
        chat.updated = .now
        store.update(chat)
        streaming = true
        Task {
            var reply = Msg(role: "assistant", content: "")
            var appended = false
            do {
                for try await delta in OpenRouter.stream(model: chat.model, messages: chat.messages, key: store.apiKey) {
                    reply.content += delta
                    if !appended { chat.messages.append(reply); appended = true }
                    else { chat.messages[chat.messages.count - 1] = reply }
                }
            } catch {
                errorText = error.localizedDescription
            }
            streaming = false
            chat.updated = .now
            store.update(chat)
        }
    }
}

struct MessageBubble: View {
    let msg: Msg
    var body: some View {
        HStack {
            if msg.role == "user" { Spacer(minLength: 40) }
            if msg.role == "user" {
                Text(msg.content)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 18))
            } else {
                AssistantText(text: msg.content)
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: msg.role == "user" ? .trailing : .leading)
        .contextMenu { Button("Copy") { UIPasteboard.general.string = msg.content } }
    }
}

/// Light markdown: fenced code becomes monospaced blocks, prose gets inline markdown.
struct AssistantText: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                if seg.code {
                    Text(seg.text)
                        .font(.system(.caption, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Text((try? AttributedString(markdown: seg.text,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(seg.text))
                        .textSelection(.enabled)
                }
            }
        }
    }
    private var segments: [(code: Bool, text: String)] {
        var out: [(Bool, String)] = []
        var rest = text[...]
        while let open = rest.range(of: "```") {
            let before = String(rest[..<open.lowerBound]).trimmingCharacters(in: .newlines)
            if !before.isEmpty { out.append((false, before)) }
            rest = rest[open.upperBound...]
            if let nl = rest.firstIndex(of: "\n") { rest = rest[rest.index(after: nl)...] }   // drop language tag
            if let close = rest.range(of: "```") {
                out.append((true, String(rest[..<close.lowerBound]).trimmingCharacters(in: .newlines)))
                rest = rest[close.upperBound...]
            } else {
                out.append((true, String(rest).trimmingCharacters(in: .newlines)))
                rest = rest[rest.endIndex...]
            }
        }
        let tail = String(rest).trimmingCharacters(in: .newlines)
        if !tail.isEmpty { out.append((false, tail)) }
        return out.isEmpty ? [(false, text)] : out
    }
}
