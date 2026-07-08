import SwiftUI
import PhotosUI
import UIKit

struct ChatView: View {
    @EnvironmentObject var store: Store
    @State var chat: Chat
    @State private var input = ""
    @State private var streaming = false
    @State private var errorText: String?
    @State private var showPicker = false
    @State private var pendingImages: [String] = []     // data URLs awaiting send
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false

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
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.messages) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            Divider()
            VStack(spacing: 6) {
                if !pendingImages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(pendingImages.enumerated()), id: \.offset) { i, url in
                                ZStack(alignment: .topTrailing) {
                                    DataURLImage(url: url).frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    Button { pendingImages.remove(at: i) } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }.offset(x: 6, y: -6)
                                }
                            }
                        }.padding(.horizontal, 4).padding(.top, 6)
                    }
                }
                HStack(spacing: 10) {
                    if modelSupportsVision {
                        Menu {
                            Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                            photoPickerButton
                        } label: {
                            Image(systemName: "plus.circle").font(.system(size: 24)).foregroundStyle(.secondary)
                        }
                    }
                    TextField("Message…", text: $input, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 20))
                        .onSubmit(send)
                    Button(action: send) {
                        Image(systemName: streaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 30))
                    }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty && pendingImages.isEmpty && !streaming)
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
                .onDisappear {
                    store.defaultModel = chat.model
                    store.update(chat)
                    if !modelSupportsVision { pendingImages = [] }
                }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in addImage(img) }.ignoresSafeArea()
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                        addImage(img)
                    }
                }
                photoItems = []
            }
        }
    }

    private var modelSupportsVision: Bool {
        store.models.first { $0.id == chat.model }?.vision ?? false
    }

    private var photoPickerButton: some View {
        PhotosPicker(selection: $photoItems, maxSelectionCount: 4, matching: .images) {
            Label("Photo Library", systemImage: "photo.on.rectangle")
        }
    }

    func addImage(_ img: UIImage) {
        let maxDim: CGFloat = 1280
        let scale = min(1, maxDim / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let r = UIGraphicsImageRenderer(size: size)
        let small = r.image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        if let d = small.jpegData(compressionQuality: 0.7) {
            pendingImages.append("data:image/jpeg;base64," + d.base64EncodedString())
        }
    }

    private var streamTask: Task<Void, Never>? { nil }

    func send() {
        if streaming { return }   // stop handled implicitly by task cancel on nav; keep simple
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty else { return }
        input = ""
        errorText = nil
        chat.messages.append(Msg(role: "user", content: text.isEmpty ? "What's in this image?" : text,
                                 images: pendingImages.isEmpty ? nil : pendingImages))
        pendingImages = []
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
                VStack(alignment: .trailing, spacing: 6) {
                    if let imgs = msg.images, !imgs.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(imgs.enumerated()), id: \.offset) { _, u in
                                DataURLImage(url: u).frame(width: 110, height: 110)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    }
                    Text(msg.content)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 18))
                }
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


struct DataURLImage: View {
    let url: String
    var body: some View {
        if let comma = url.firstIndex(of: ","),
           let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
           let img = UIImage(data: data) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            Color(.systemGray5)
        }
    }
}
