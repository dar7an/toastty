import SwiftUI

/// Project icon picker presented in a popover over the sidebar icon.
/// A curated grid replaces the system Character Viewer, whose insertion
/// never reliably reached an input client inside this SwiftUI sidebar.
struct ProjectEmojiPicker: View {
    let onSelect: (String) -> Void

    private static let columnCount = 8

    // The popover never scrolls, so a static grid builds every button (and
    // its accessibility element) up front; a lazy grid would defer both.
    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(Array(stride(from: 0, to: Self.emojis.count, by: Self.columnCount)), id: \.self) { start in
                GridRow {
                    ForEach(Self.emojis[start..<min(start + Self.columnCount, Self.emojis.count)], id: \.self) { emoji in
                        Button { onSelect(emoji) } label: {
                            Text(emoji)
                                .font(.system(size: 19))
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Choose \(emoji)")
                    }
                }
            }
        }
        .padding(10)
    }

    static let emojis: [String] = [
        "📁", "📂", "🗂️", "💼", "🏠", "🏢", "🏗️", "🧱",
        "🚀", "⚡", "🔥", "⭐", "🌟", "✨", "💡", "🎯",
        "🎨", "🎭", "🎪", "🎬", "🎮", "🎲", "🎸", "🥁",
        "📱", "💻", "🖥️", "⌨️", "💾", "🧮", "📷", "🎥",
        "📺", "📻", "📡", "🔋", "🔌", "💰", "💳", "💎",
        "🔧", "🔨", "⚙️", "🛠️", "🧪", "🧬", "🔬", "🔭",
        "📈", "📉", "📊", "📋", "📌", "📍", "✏️", "📝",
        "🔍", "🔒", "🔓", "🔑", "🛡️", "🏆", "🥇", "🎁",
        "🎉", "📦", "📬", "✉️", "📅", "🌍", "🗺️", "🧭",
    ]
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
