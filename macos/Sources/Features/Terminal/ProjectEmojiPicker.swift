import AppKit
import SwiftUI

/// A native field editor receives the system picker's insertion directly.
/// The first valid emoji commits immediately; no visible editor or Done step.
struct ProjectEmojiPicker: NSViewRepresentable {
    let isPresented: Bool
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ProjectEmojiInputField {
        let field = ProjectEmojiInputField(frame: .zero)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.textColor = .clear
        field.focusRingType = .none
        field.isEditable = false
        field.isSelectable = false
        field.delegate = field
        field.setAccessibilityElement(false)
        return field
    }

    func updateNSView(_ field: ProjectEmojiInputField, context: Context) {
        field.onSelect = onSelect
        field.onCancel = onCancel
        field.setPresented(isPresented)
    }
}

final class ProjectEmojiInputField: NSTextField, NSTextFieldDelegate {
    var onSelect: (String) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var showPicker: () -> Void = { NSApp.orderFrontCharacterPalette(nil) }
    private(set) var isPresented = false
    private var isFinishing = false

    // Preserve normal sidebar selection while the picker is inactive.
    override func hitTest(_ point: NSPoint) -> NSView? { isPresented ? super.hitTest(point) : nil }

    func setPresented(_ presented: Bool) {
        guard !isFinishing, presented != isPresented else { return }
        isPresented = presented
        isEditable = presented
        isSelectable = presented
        guard presented else { return }
        stringValue = ""
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPresented, let window = self.window,
                  window.makeFirstResponder(self) else { return }
            self.showPicker()
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (currentEditor() as? NSTextView)?.hasMarkedText() != true,
              let emoji = TerminalProject.normalizedEmoji(stringValue) else { return }
        finish { [onSelect] in onSelect(emoji) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelOperation(nil)
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        finish(onCancel)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finish(onCancel)
    }

    private func finish(_ completion: @escaping () -> Void) {
        guard isPresented, !isFinishing else { return }
        isFinishing = true
        // Character Viewer is still delivering text through the input system.
        // End editing, rebuild the row, and restore terminal focus only after
        // that callback returns, avoiding a reentrant input-method transition.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isFinishing = false
            self.setPresented(false)
            completion()
        }
    }
}

@available(macOS 14.0, *)
struct ProjectSidebarFolderIcon: View {
    let color: TerminalTabColor
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Image(systemName: "folder.fill")
            .font(.system(size: 15))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(prominence == .increased
                ? Color(nsColor: .alternateSelectedControlTextColor)
                : color.displayColor.map(Color.init(nsColor:)) ?? .accentColor)
    }
}
