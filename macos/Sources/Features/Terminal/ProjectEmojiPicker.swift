import SwiftUI

/// Project icon picker presented in a popover over the sidebar icon.
/// A curated grid replaces the system Character Viewer, whose insertion
/// never reliably reached an input client inside this SwiftUI sidebar.
struct ProjectEmojiPicker: View {
    let onSelect: (String) -> Void

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 4), count: 8)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Self.emojis, id: \.self) { emoji in
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
