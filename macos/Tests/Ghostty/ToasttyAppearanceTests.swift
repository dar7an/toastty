import AppKit
import SwiftUI
import Testing
@testable import Ghostty
import GhosttyKit

@MainActor
@Suite(.serialized)
struct ToasttyAppearanceTests {
    @Test func defaultsFollowSystemAndSwitchTerminalPalette() throws {
        let file = try TemporaryConfig("")
        let app = Ghostty.App(configPath: file.temporaryFile.path)
        let core = try #require(app.app)
        #expect(app.config.errors.isEmpty)
        #expect(app.config.windowTheme == "system")

        ghostty_app_set_color_scheme(core, GHOSTTY_COLOR_SCHEME_LIGHT)
        #expect(NSColor(app.config.backgroundColor).isLightColor)
        ghostty_app_set_color_scheme(core, GHOSTTY_COLOR_SCHEME_DARK)
        #expect(!NSColor(app.config.backgroundColor).isLightColor)
        ghostty_app_set_color_scheme(core, GHOSTTY_COLOR_SCHEME_LIGHT)
        #expect(NSColor(app.config.backgroundColor).isLightColor)
    }

    @Test(arguments: ToasttyAppearance.allCases)
    func appearanceOverrideLoadsAfterUserConfiguration(_ appearance: ToasttyAppearance) throws {
        let file = try TemporaryConfig("window-theme = dark")
        let config = Ghostty.Config(config: Ghostty.Config.loadConfig(
            at: file.temporaryFile.path, finalize: true, appearanceOverride: appearance))
        #expect(appearance.configurationURL != nil)
        #expect(config.errors.isEmpty)
        #expect(config.windowTheme == appearance.rawValue)
        if appearance == .system {
            #expect(NSAppearance(ghosttyConfig: config) == nil)
        } else {
            #expect(NSAppearance(ghosttyConfig: config)?.isDark == (appearance == .dark))
        }
    }

    @Test func customThemeAndColorsRemainAuthoritative() throws {
        let file = try TemporaryConfig("theme = GitHub Dark Default\nbackground = 123456\nwindow-theme = light")
        #expect(file.errors.isEmpty)
        #expect(file.windowTheme == "light")
        let color = try #require(NSColor(file.backgroundColor).usingColorSpace(.sRGB))
        #expect(abs(color.redComponent - 0x12 / 255.0) < 0.001)
        #expect(abs(color.greenComponent - 0x34 / 255.0) < 0.001)
        #expect(abs(color.blueComponent - 0x56 / 255.0) < 0.001)
    }
}
