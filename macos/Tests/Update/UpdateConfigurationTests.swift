import Foundation
import Testing
@testable import Ghostty

struct UpdateConfigurationTests {
    private var nightly: [String: Any] {
        [
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
            "SUFeedURL": "https://github.com/dar7an/toastty/releases/download/nightly/appcast.xml",
            "SUVerifyUpdateBeforeExtraction": true,
            "SURequireSignedFeed": true,
        ]
    }

    @Test func nightlyEnablesSignedUpdates() {
        #expect(UpdateController.isEnabled(bundleIdentifier: "com.dar7an.toastty.nightly", info: nightly))
    }

    @Test(arguments: ["com.dar7an.toastty", "com.dar7an.toastty.debug", "com.dar7an.toastty.local", "com.mitchellh.ghostty"])
    func otherAppsNeverJoinNightly(bundleID: String) {
        #expect(!UpdateController.isEnabled(bundleIdentifier: bundleID, info: nightly))
    }

    @Test(arguments: ["SUPublicEDKey", "SUFeedURL", "SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"])
    func incompleteConfigurationIsDisabled(key: String) {
        var info = nightly
        info.removeValue(forKey: key)
        #expect(!UpdateController.isEnabled(bundleIdentifier: "com.dar7an.toastty.nightly", info: info))
    }

    @Test(arguments: ["", "invalid", Data(repeating: 0, count: 31).base64EncodedString()])
    func malformedSigningKeyIsRejected(key: String) {
        var info = nightly
        info["SUPublicEDKey"] = key
        #expect(!UpdateController.isEnabled(bundleIdentifier: "com.dar7an.toastty.nightly", info: info))
    }

    @Test(arguments: ["https://example.com/appcast.xml", "http://127.0.0.1:8765/appcast.xml"])
    func installedNightlyCannotUseAnotherFeed(feed: String) {
        var info = nightly
        info["SUFeedURL"] = feed
        #expect(!UpdateController.isEnabled(bundleIdentifier: "com.dar7an.toastty.nightly", info: info))
    }

    @Test func testAppOnlyAcceptsLoopbackFeed() {
        var info = nightly
        #expect(!UpdateController.isEnabled(bundleIdentifier: "com.dar7an.toastty.nightly.test", info: info))
        info["SUFeedURL"] = "http://127.0.0.1:8765/appcast.xml"
        #expect(UpdateController.isEnabled(bundleIdentifier: "com.dar7an.toastty.nightly.test", info: info))
        info["SUFeedURL"] = "http://127.0.0.1.example.com/appcast.xml"
        #expect(!UpdateController.isEnabled(bundleIdentifier: "com.dar7an.toastty.nightly.test", info: info))
    }
}
