import AppKit
import SwiftUI

/// NSTextField natif — contourne les bugs de focus du TextField SwiftUI.
struct SearchTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.stringValue = text
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.isUpdatingFromBinding = true
        defer { context.coordinator.isUpdatingFromBinding = false }

        guard nsView.stringValue != text else { return }
        nsView.stringValue = text

        // Force la synchro même si le champ a le focus (ex. retour historique).
        if let editor = nsView.currentEditor() {
            let selected = editor.selectedRange
            editor.string = text
            let capped = min(selected.location, (text as NSString).length)
            editor.selectedRange = NSRange(location: capped, length: 0)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchTextField
        var isUpdatingFromBinding = false

        init(_ parent: SearchTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard !isUpdatingFromBinding else { return }
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        @objc func submit(_ sender: NSTextField) {
            parent.text = sender.stringValue
            parent.onSubmit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.text = (control as? NSTextField)?.stringValue ?? parent.text
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}
