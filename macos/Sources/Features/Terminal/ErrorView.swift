import AppKit
import SwiftUI

struct ErrorView: View {
    var body: some View {
        HStack {
            Image("AppIconImage")
                .resizable()
                .scaledToFit()
                .frame(width: 128, height: 128)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Something Went Wrong").font(.title)
                Text("Toastty encountered a fatal error and cannot continue. Restart the app and check the logs in Console.app if the problem persists.")
                HStack(spacing: 12) {
                    Button("Copy Diagnostics") {
                        let details = "Toastty fatal error. App: \(Bundle.main.bundleIdentifier ?? "toastty") Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(details, forType: .string)
                    }
                    .accessibilityLabel("Copy diagnostics to clipboard")
                    Button("Quit Toastty") {
                        NSApp.terminate(nil)
                    }
                    .accessibilityLabel("Quit Toastty")
                }
                .buttonStyle(.link)
            }
        }
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Toastty encountered a fatal error. Restart the app.")
    }
}

struct ErrorView_Previews: PreviewProvider {
    static var previews: some View {
        ErrorView()
    }
}
