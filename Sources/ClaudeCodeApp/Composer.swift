import AppKit
import SwiftUI

/// Multi-line message box: Enter sends, Shift+Enter inserts a newline, pasting files or
/// images turns them into attachments, and arrow/Tab/Esc keys can be claimed by the caller
/// (used for slash command suggestions).
struct ComposerTextView: NSViewRepresentable {
    enum Key { case up, down, tab, escape, enter }

    @Binding var text: String
    @Binding var height: CGFloat
    var isEnabled: Bool
    var fontSize: CGFloat = 14
    var focusTrigger: Int
    var onSubmit: () -> Void
    var onKey: (Key) -> Bool
    var onPaste: (NSPasteboard) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PastingTextView()
        textView.delegate = context.coordinator
        textView.onPaste = { context.coordinator.parent.onPaste($0) }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: fontSize)
        textView.drawsBackground = false
        textView.insertionPointColor = NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x45 / 255, alpha: 1)
        textView.textColor = NSColor(srgbRed: 0xEC / 255, green: 0xEC / 255, blue: 0xED / 255, alpha: 1)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255,
                                                                    blue: 0x45 / 255, alpha: 0.35)]
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            context.coordinator.updateHeight(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEnabled
        if textView.font?.pointSize != fontSize {
            textView.font = .systemFont(ofSize: fontSize)
            context.coordinator.updateHeight(textView)
        }
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.updateHeight(textView)
        }
        if context.coordinator.lastFocusTrigger != focusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var lastFocusTrigger = 0

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            updateHeight(textView)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                if parent.onKey(.enter) { return true }
                parent.onSubmit()
                return true
            case #selector(NSResponder.moveUp(_:)):
                return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onKey(.down)
            case #selector(NSResponder.insertTab(_:)):
                return parent.onKey(.tab)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onKey(.escape)
            default:
                return false
            }
        }

        func updateHeight(_ textView: NSTextView) {
            guard let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + textView.textContainerInset.height * 2
            let height = min(max(used, 20), 200)
            if abs(parent.height - height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = height }
            }
        }
    }
}

private final class PastingTextView: NSTextView {
    var onPaste: ((NSPasteboard) -> Bool)?

    override func paste(_ sender: Any?) {
        if onPaste?(.general) == true { return }
        pasteAsPlainText(sender)
    }
}
