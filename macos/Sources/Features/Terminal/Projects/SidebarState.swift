import Foundation

/// Sidebar layout shared by a native tab group and saved with each member.
/// Validate widths at the data boundary, including archives from older builds.
struct SidebarState: Codable, Equatable {
    static let minWidth: CGFloat = 160
    static let maxWidth: CGFloat = 320
    static let defaultWidth: CGFloat = 220

    var isVisible: Bool
    var expandedWidth: CGFloat {
        didSet { expandedWidth = Self.normalizedWidth(expandedWidth) }
    }

    init(isVisible: Bool, expandedWidth: CGFloat) {
        self.isVisible = isVisible
        self.expandedWidth = Self.normalizedWidth(expandedWidth)
    }

    private static func normalizedWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return defaultWidth }
        return min(maxWidth, max(minWidth, width))
    }

    private enum CodingKeys: String, CodingKey {
        case isVisible
        case expandedWidth
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isVisible: try container.decode(Bool.self, forKey: .isVisible),
            expandedWidth: try container.decode(CGFloat.self, forKey: .expandedWidth))
    }
}
