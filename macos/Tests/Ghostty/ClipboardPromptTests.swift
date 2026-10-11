import Testing
@testable import Ghostty

struct ClipboardPromptTests {
    @Test(arguments: [Ghostty.ClipboardRequest.osc_52_read, .kitty_read])
    func readRequestsDoNotClaimAnAuthenticatedProgram(_ request: Ghostty.ClipboardRequest) {
        #expect(request.text() == """
        An application is attempting to read from the clipboard.
        The current clipboard contents are shown below.
        """)
        #expect(ClipboardConfirmationView.Action.text(.cancel, request) == "Deny")
        #expect(ClipboardConfirmationView.Action.text(.confirm, request) == "Allow")
    }

    @Test(arguments: [Ghostty.ClipboardRequest.osc_52_write, .kitty_write])
    func writeRequestsDoNotClaimAnAuthenticatedProgram(_ request: Ghostty.ClipboardRequest) {
        #expect(request.text() == """
        An application is attempting to write to the clipboard.
        The content to write is shown below.
        """)
    }

    @Test func directPasteKeepsItsDistinctWarningAndActions() {
        #expect(Ghostty.ClipboardRequest.paste.text().contains("commands may be executed"))
        #expect(ClipboardConfirmationView.Action.text(.cancel, .paste) == "Cancel")
        #expect(ClipboardConfirmationView.Action.text(.confirm, .paste) == "Paste")
    }
}
