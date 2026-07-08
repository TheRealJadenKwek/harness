import SwiftUI
import PhotosUI
import UIKit
import AVKit
import PDFKit
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var store: Store
    let chatID: String
    @State private var input = ""
    @State private var showPicker = false
    @State private var pendingImages: [String] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showDocPicker = false
    @State private var pendingDocs: [(name: String, text: String)] = []
    @FocusState private var inputFocused: Bool
    @AppStorage("ondeviceThink") private var ondeviceThink = true

    private var chat: Chat { store.chat(chatID) ?? Chat(model: store.defaultModel) }
    private var streaming: Bool { store.live.contains(chatID) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if chat.messages.isEmpty {
                            EmptyHomeView { fill in input = fill; inputFocused = true }
                                .padding(.top, 90)
                        }
                        ForEach(Array(chat.messages.enumerated()), id: \.offset) { i, m in
                            MessageBubble(msg: m, index: i, chatID: chatID, streaming: streaming,
                                          onRewind: { idx in if let t = store.rewind(chatID: chatID, msgIndex: idx) { input = t } },
                                          onFork: { idx in _ = store.fork(chatID: chatID, msgIndex: idx) })
                        }
                        if let ts = store.toolStatus[chatID] {
                            HStack(spacing: 6) {
                                Text("✳").foregroundStyle(Color(red: 0.30, green: 0.49, blue: 1.0))
                                Text(ts).font(.caption).foregroundStyle(.secondary)
                            }
                        } else if streaming && chat.messages.last?.role == "user" {
                            HStack(spacing: 6) {
                                Text("✳").foregroundStyle(Color(red: 0.30, green: 0.49, blue: 1.0))
                                Text("Thinking…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let e = store.errors[chatID] {
                            Text("⚠︎ " + e).font(.caption).foregroundStyle(.red)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 14).padding(.top, 10)
                }
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture { inputFocused = false }
                .animation(.easeOut(duration: 0.18), value: chat.messages.count)
                .onChange(of: chat.messages.count) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: chat.messages.last?.content) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: inputFocused) { _, f in
                    // settle the scroll after the keyboard animates in OR out — without the
                    // dismiss pass the content sits over-scrolled, leaving a blank band where
                    // the keyboard was until the next touch
                    DispatchQueue.main.asyncAfter(deadline: .now() + (f ? 0.25 : 0.3)) {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
            }
            VStack(spacing: 6) {
                if !pendingDocs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(pendingDocs.enumerated()), id: \.offset) { i, d in
                                HStack(spacing: 5) {
                                    Image(systemName: "doc.text").font(.caption)
                                    Text(d.name).font(.caption).lineLimit(1)
                                    Button { pendingDocs.remove(at: i) } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
                                }
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(Color(.systemGray6), in: Capsule())
                            }
                        }.padding(.horizontal, 4).padding(.top, 6)
                    }
                }
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
                    Menu {
                        Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                        photoPickerButton
                        Button { showDocPicker = true } label: { Label("Attach Document", systemImage: "doc.badge.plus") }
                    } label: {
                        Image(systemName: "plus.circle").font(.system(size: 24)).foregroundStyle(.secondary)
                    }
                    TextField("Message…", text: $input, axis: .vertical)
                        .focused($inputFocused)
                        .lineLimit(1...5)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color(.systemGray6).opacity(0.7), in: RoundedRectangle(cornerRadius: 20))
                        .onSubmit(send)
                    Button(action: sendOrStop) {
                        Image(systemName: streaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 30))
                    }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty && pendingImages.isEmpty && !streaming)
                }
                HStack(spacing: 14) {
                    Button { showPicker = true } label: {
                        Label(shortModel(chat.model), systemImage: LocalModels.isLocal(chat.model) ? "iphone" : "cpu")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if LocalModels.isLocal(chat.model) {
                        Button { ondeviceThink.toggle() } label: {
                            Label(ondeviceThink ? "Think" : "No think", systemImage: "brain")
                                .font(.caption)
                                .foregroundStyle(ondeviceThink ? Color(red: 0.30, green: 0.49, blue: 1.0) : .secondary)
                        }
                    } else {
                        Menu {
                            ForEach([nil, "low", "medium", "high"], id: \.self) { e in
                                Button((e ?? "auto") + (chat.effort == e ? " ✓" : "")) {
                                    var c = chat; c.effort = e; store.update(c)
                                }
                            }
                        } label: {
                            Label(chat.effort ?? "auto", systemImage: "brain")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let stat = statText {
                        Text(stat).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
            .padding(.horizontal, 10).padding(.bottom, 6)
        }
        .navigationTitle(chat.title).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPicker) {
            ModelPickerView(selected: Binding(
                get: { chat.model },
                set: { v in var c = chat; c.model = v; store.update(c); store.defaultModel = v }
            ))
            .onDisappear { if !modelSupportsVision { pendingImages = [] } }
        }
        .fileImporter(isPresented: $showDocPicker,
                      allowedContentTypes: [.pdf, .plainText, .text, .sourceCode, .commaSeparatedText, .json,
                                            .spreadsheet, .presentation,
                                            UTType(filenameExtension: "xlsx"), UTType(filenameExtension: "docx"),
                                            UTType(filenameExtension: "pptx")].compactMap { $0 },
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls.prefix(4) {
                let ok = url.startAccessingSecurityScopedResource()
                let ext = url.pathExtension.lowercased()
                let name = url.lastPathComponent
                if ["xlsx", "xls", "docx", "pptx"].contains(ext) {
                    guard let data = try? Data(contentsOf: url) else { if ok { url.stopAccessingSecurityScopedResource() }; continue }
                    if ok { url.stopAccessingSecurityScopedResource() }
                    Task { @MainActor in
                        let text = await WebArtifactBuilder.shared.extractOffice(base64: data.base64EncodedString(), ext: ext)
                        if !text.isEmpty { pendingDocs.append((name: name, text: String(text.prefix(60000)))) }
                    }
                    continue
                }
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                var text = ""
                if ext == "pdf", let doc = PDFDocument(url: url) {
                    text = doc.string ?? ""
                } else {
                    text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                }
                if !text.isEmpty { pendingDocs.append((name: name, text: String(text.prefix(60000)))) }
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

    private var statText: String? {
        var parts: [String] = []
        if let s = chat.spend, s > 0 { parts.append(String(format: s < 0.1 ? "$%.4f" : "$%.2f", s)) }
        if let t = chat.ctxTokens, t > 0,
           let ctx = store.models.first(where: { $0.id == chat.model })?.context, ctx > 0 {
            parts.append("\(Int(Double(t) / Double(ctx) * 100))% ctx")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var modelSupportsVision: Bool {
        if LocalModels.isLocal(chat.model) { return false }
        return store.models.first { $0.id == chat.model }?.vision ?? false
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

    func sendOrStop() { if streaming { store.stop(chatID) } else { send() } }
    func send() {
        if streaming { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty || !pendingDocs.isEmpty else { return }
        input = ""
        var docBlock = ""
        for d in pendingDocs { docBlock += "[Attached document: " + d.name + "]\n-----BEGIN DOCUMENT-----\n" + d.text.prefix(40000) + "\n-----END DOCUMENT-----\n\n" }
        pendingDocs = []
        let imgs = pendingImages
        pendingImages = []
        store.send(chatID: chatID, text: docBlock + text, images: imgs)
    }
}

struct MessageBubble: View {
    let msg: Msg
    let index: Int
    let chatID: String
    let streaming: Bool
    var onRewind: (Int) -> Void = { _ in }
    var onFork: (Int) -> Void = { _ in }

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
                let parts = splitThink(msg.content)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(msg.toolNotes ?? [], id: \.self) { n in
                        Label(n, systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(msg.execs ?? [], id: \.self) { x in ExecCardView(spec: x) }
                    ForEach(msg.files ?? [], id: \.self) { f in
                        if f.kind == "image", let du = f.dataUrl { InlineMediaView(dataUrl: du, isVideo: false, filename: f.filename) }
                        else if f.kind == "video", let du = f.dataUrl { InlineMediaView(dataUrl: du, isVideo: true, filename: f.filename) }
                        else if f.kind == "html" { HTMLFileCardView(spec: f) }
                        else { FileCardView(spec: f) }
                    }
                    if let think = parts.think {
                        DisclosureGroup {
                            Text(think).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        } label: {
                            Label(parts.answer.isEmpty ? "thinking…" : "thought", systemImage: "brain")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !parts.answer.isEmpty || parts.think == nil {
                        AssistantText(text: parts.think == nil ? msg.content : parts.answer)
                    }
                }
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: msg.role == "user" ? .trailing : .leading)
        .contextMenu {
            Button { UIPasteboard.general.string = msg.content } label: { Label("Copy", systemImage: "doc.on.doc") }
            if msg.role == "user" && !streaming {
                Button { onRewind(index) } label: { Label("Rewind to here", systemImage: "arrow.uturn.backward") }
                Button { onFork(index) } label: { Label("Fork from here", systemImage: "arrow.triangle.branch") }
            }
        }
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
            if let nl = rest.firstIndex(of: "\n") { rest = rest[rest.index(after: nl)...] }
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

struct FileCardView: View {
    let spec: FileSpec
    @State private var building = false
    @State private var shareURL: URL?
    @State private var err: String?

    private var icon: String {
        switch spec.kind {
        case "pdf": return "doc.richtext"
        case "xlsx": return "tablecells"
        case "pptx": return "rectangle.on.rectangle.angled"
        case "html": return "globe"
        case "zip": return "shippingbox"
        default: return "doc.text"
        }
    }
    var body: some View {
        Button {
            guard !building else { return }
            building = true; err = nil
            Task {
                do { shareURL = try await FileBuilder.build(spec) }
                catch { err = error.localizedDescription }
                building = false
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(Color(red: 0.30, green: 0.49, blue: 1.0))
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.filename).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(err ?? (building ? "building…" : spec.kind.uppercased() + " · tap to save/share"))
                        .font(.caption2).foregroundStyle(err == nil ? Color.secondary : Color.red)
                }
                Spacer(minLength: 8)
                if building { ProgressView().controlSize(.small) }
                else { Image(systemName: "square.and.arrow.down").foregroundStyle(.secondary) }
            }
            .padding(12)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 300, alignment: .leading)
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { _ in shareURL = nil })) { item in
            ShareSheet(url: item.url)
        }
    }
}
struct ShareItem: Identifiable { let url: URL; var id: String { url.path } }
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
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


struct ExecCardView: View {
    let spec: ExecSpec
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("ran " + spec.language, systemImage: "terminal").font(.caption).foregroundStyle(.secondary)
            Text(spec.code.prefix(600))
                .font(.system(.caption2, design: .monospaced))
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
            if let out = spec.output, !out.isEmpty {
                Text(out.prefix(600))
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: 320)
    }
}

struct InlineMediaView: View {
    let dataUrl: String
    let isVideo: Bool
    let filename: String
    @State private var tmpURL: URL?
    @State private var shareURL: URL?

    private func materialize() -> URL? {
        guard let comma = dataUrl.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataUrl[dataUrl.index(after: comma)...])) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename.isEmpty ? (isVideo ? "video.mp4" : "image.png") : filename)
        try? data.write(to: url)
        return url
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if isVideo {
                if let u = tmpURL {
                    VideoPlayer(player: AVPlayer(url: u))
                        .frame(width: 280, height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    ProgressView().frame(width: 280, height: 120)
                        .onAppear { tmpURL = materialize() }
                }
            } else {
                DataURLImage(url: dataUrl)
                    .frame(maxWidth: 280, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            Button { shareURL = materialize() } label: {
                Label("Save", systemImage: "square.and.arrow.down").font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { _ in shareURL = nil })) { item in
            ShareSheet(url: item.url)
        }
    }
}


import WebKit

struct HTMLFileCardView: View {
    let spec: FileSpec
    @State private var showPreview = false
    var body: some View {
        Button { showPreview = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "globe").font(.system(size: 22)).foregroundStyle(Color(red: 0.30, green: 0.49, blue: 1.0))
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.filename).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text("HTML · tap to preview").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "play.circle").foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 300, alignment: .leading)
        .fullScreenCover(isPresented: $showPreview) { HTMLPreviewSheet(spec: spec) }
    }
}

struct HTMLPreviewSheet: View {
    let spec: FileSpec
    @Environment(\.dismiss) private var dismiss
    @State private var shareURL: URL?
    @State private var tab = 0
    var body: some View {
        NavigationStack {
            Group {
                if tab == 0 {
                    HTMLWebView(html: spec.content ?? "")
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        Text(spec.content ?? "")
                            .font(.system(size: 11, design: .monospaced))
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
                .ignoresSafeArea(edges: .bottom)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("", selection: $tab) {
                            Text("Preview").tag(0)
                            Text("Code").tag(1)
                        }.pickerStyle(.segmented).frame(width: 180)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent(spec.filename.isEmpty ? "page.html" : spec.filename)
                            try? (spec.content ?? "").data(using: .utf8)?.write(to: url)
                            shareURL = url
                        } label: { Image(systemName: "square.and.arrow.up") }
                    }
                }
                .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { _ in shareURL = nil })) { item in
                    ShareSheet(url: item.url)
                }
        }
    }
}

struct HTMLWebView: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.loadHTMLString(html, baseURL: nil)
        return wv
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}


struct EmptyHomeView: View {
    let onPick: (String) -> Void
    private let ideas: [(icon: String, title: String, sub: String, fill: String)] = [
        ("pencil.line", "Write something", "an email, a message, a caption", "Help me write "),
        ("gamecontroller", "Make a little app or game", "live preview you can play with", "Make me a small web game: "),
        ("magnifyingglass", "Look something up", "searches the web, reads sources", "Search the web: "),
    ]
    var body: some View {
        VStack(spacing: 8) {
            Text("What can I do for you?")
                .font(.title3.weight(.semibold))
                .padding(.bottom, 14)
            ForEach(ideas, id: \.title) { idea in
                Button { onPick(idea.fill) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: idea.icon)
                            .font(.system(size: 17))
                            .foregroundStyle(Color(red: 0.30, green: 0.49, blue: 1.0))
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(idea.title).font(.subheadline.weight(.semibold))
                            Text(idea.sub).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 15).padding(.vertical, 12)
                    .background(Color(.systemGray6).opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
    }
}
