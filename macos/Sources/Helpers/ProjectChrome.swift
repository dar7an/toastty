import GhosttyKit
import SwiftUI

/// Shared adaptive colors and hairline metrics for window chrome.
enum ProjectChrome {
    /// The system separator color, matching Xcode's tab-bar and split
    /// divider lines. It adapts to light and dark appearances and
    /// strengthens under Increase Contrast automatically.
    static let separatorColor = Color(nsColor: .separatorColor)

    /// Preview cards use a restrained corner radius; tabs use capsules.
    static let previewCornerRadius: CGFloat = 10

    /// One physical pixel at `displayScale` (`Environment(\.displayScale)`),
    /// so the line is a true hairline on Retina instead of a 1pt rule.
    static func hairline(displayScale: CGFloat) -> CGFloat {
        guard displayScale.isFinite else { return 1 }
        return 1 / max(displayScale, 1)
    }
}

extension Ghostty.Config {
    /// The user's `split-divider-color`, or nil when unset so split chrome
    /// can fall back to ``ProjectChrome/separatorColor``. This never
    /// substitutes a derived color.
    var configuredSplitDividerColor: Color? {
        guard let config else { return nil }

        var color: ghostty_config_color_s = .init()
        let key = "split-divider-color"
        guard ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8))) else {
            return nil
        }

        return Color(
            red: Double(color.r) / 255,
            green: Double(color.g) / 255,
            blue: Double(color.b) / 255
        )
    }
}
