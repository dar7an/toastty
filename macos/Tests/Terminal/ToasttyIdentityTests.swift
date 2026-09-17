import AppKit
import Testing
@testable import Ghostty

@MainActor
struct ToasttyIdentityTests {
    @Test func defaultIconRefreshDoesNotCreateFinderOverride() async throws {
        let appURL = Bundle.main.bundleURL
        #expect(try appURL.resourceValues(forKeys: [.customIconKey]).customIcon == nil)
        await AppIconUpdater().update(icon: nil)
        #expect(try appURL.resourceValues(forKeys: [.customIconKey]).customIcon == nil)
        #expect(NSApp.applicationIconImage != nil)
    }

    @Test func applicationHasIndependentIdentityAndBundledCredits() {
        #expect(Bundle.main.bundleIdentifier == "com.dar7an.toastty.debug")
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Toastty")
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "toastty")
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String == "Toastty")
        #expect(Bundle.main.url(forResource: "Toastty", withExtension: "icns") != nil)
        #expect(Bundle.main.image(forResource: "AppIconImage") != nil)
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") == nil)
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool == false)
        #expect(Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") != nil)
    }
}
