import SwiftUI

/// TextKit lays out a single Text in O(length) — one 100k-char Text pegs the main thread for
/// seconds on an iPhone (the on-device freeze/hang). These helpers keep every individual Text
/// small so layout cost stays bounded no matter how much a CLI turn produces.
enum TextChunker {
    static let size = 2000
    static let maxLines = 48   // tall Texts (100s of short lines) exceed the GPU texture cap and silently draw BLANK

    /// Split on character budget OR line budget, at line boundaries when possible (the boundary
    /// newline is dropped; the stack break stands in for it), hard-cut otherwise. Both caps
    /// matter: chars bound layout cost, lines bound rendered HEIGHT — a single Text hundreds of
    /// short lines tall overflows Core Animation's texture limit and draws as nothing at all.
    static func chunks(_ s: String) -> [String] {
        var out: [String] = []
        var lineStart = s.startIndex   // start of the current chunk
        var chars = 0, lines = 0
        var i = s.startIndex
        var lastNL: String.Index? = nil
        while i < s.endIndex {
            if s[i] == "\n" { lastNL = i; lines += 1 }
            chars += 1
            if chars >= size || lines >= maxLines {
                if let nl = lastNL, nl >= lineStart {
                    out.append(String(s[lineStart..<nl]))
                    lineStart = s.index(after: nl)
                    i = lineStart
                } else {
                    let cut = s.index(after: i)
                    out.append(String(s[lineStart..<cut]))
                    lineStart = cut
                    i = cut
                }
                chars = 0; lines = 0; lastNL = nil
                continue
            }
            i = s.index(after: i)
        }
        if lineStart < s.endIndex { out.append(String(s[lineStart...])) }
        return out
    }
}

/// Renders arbitrarily long plain text as a stack of small Texts (bounded per-Text layout cost).
struct ChunkedText: View {
    let text: String
    var font: Font? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(TextChunker.chunks(text).enumerated()), id: \.offset) { _, c in
                Text(c)
                    .font(font)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Long text collapsed to a head with "Show all". Giant messages (100k+ dumps) would otherwise
/// lay out in full the moment a thread opens — the open-a-big-thread hang.
struct CollapsibleText: View {
    let text: String
    var font: Font? = nil
    var threshold = 6000
    var head = 2500
    @State private var expanded = false

    var body: some View {
        if text.count <= threshold {
            ChunkedText(text: text, font: font)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ChunkedText(text: expanded ? text : String(text.prefix(head)) + " …", font: font)
                Button {
                    expanded.toggle()
                } label: {
                    Text(expanded ? "Show less" : "Show all (\(text.count.formatted()) chars)")
                        .font(.caption).bold()
                        .foregroundStyle(Color.appText)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.appSurface)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.appBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
