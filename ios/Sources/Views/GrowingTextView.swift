import SwiftUI
import UIKit

/// A UITextView-backed compose field. SwiftUI's `TextField(axis: .vertical)` freezes the main
/// thread on long text; UITextView doesn't. Height is reported through SwiftUI's native
/// `sizeThatFits` (iOS 16+) — synchronous, no @Binding/DispatchQueue round-trip — so there is NO
/// async feedback loop (the thing that hung on-device). Grows to `maxHeight`, then scrolls.
struct GrowingTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var placeholder: String
    var minHeight: CGFloat = 38
    var maxHeight: CGFloat = 130

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.backgroundColor = .clear
        tv.textColor = .label
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 2, bottom: 8, right: 2)
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.widthTracksTextView = true
        tv.isScrollEnabled = true        // always scrollable; height is capped by sizeThatFits below
        tv.text = text
        // wrap within the available width instead of insisting on the content's width
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let ph = UILabel()
        ph.font = tv.font
        ph.textColor = .secondaryLabel
        ph.translatesAutoresizingMaskIntoConstraints = false
        tv.addSubview(ph)
        NSLayoutConstraint.activate([
            ph.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: 4),
            ph.topAnchor.constraint(equalTo: tv.topAnchor, constant: 8),
            ph.trailingAnchor.constraint(lessThanOrEqualTo: tv.trailingAnchor, constant: -4),
        ])
        ph.isHidden = !text.isEmpty
        context.coordinator.placeholder = ph
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // Cheap when nothing changed — ChatView's body re-evaluates ~30x/sec while a reply streams.
        let c = context.coordinator
        if tv.text != text {
            tv.text = text
            c.placeholder?.isHidden = !text.isEmpty
        }
        if c.placeholder?.text != placeholder {
            c.placeholder?.text = placeholder
            c.placeholder?.isHidden = !tv.text.isEmpty
        }
        if focused != c.lastFocused {                  // touch first responder only on a real transition
            c.lastFocused = focused
            if focused { tv.becomeFirstResponder() } else { tv.resignFirstResponder() }
        }
    }

    /// SwiftUI asks the view how tall it wants to be for the proposed width — synchronously.
    /// No state write-back here, so it can never feed back into a layout loop.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView tv: UITextView, context: Context) -> CGSize? {
        guard let w = proposal.width ?? (tv.bounds.width > 1 ? tv.bounds.width : nil), w > 1 else { return nil }
        // PURE measurement — no mutation of `tv` here, or it re-invalidates layout and spins forever.
        let h = tv.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height
        return CGSize(width: w, height: min(max(h, minHeight), maxHeight))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: GrowingTextView
        weak var placeholder: UILabel?
        var lastFocused = false
        init(_ p: GrowingTextView) { parent = p }

        func textViewDidChange(_ tv: UITextView) {
            placeholder?.isHidden = !tv.text.isEmpty
            parent.text = tv.text          // -> @State changes -> SwiftUI re-queries sizeThatFits
        }
        func textViewDidBeginEditing(_ tv: UITextView) { if !parent.focused { parent.focused = true } }
        func textViewDidEndEditing(_ tv: UITextView) { if parent.focused { parent.focused = false } }
    }
}
