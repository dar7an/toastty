import SwiftUI

protocol ConfigurationErrorsViewModel: ObservableObject {
    var errors: [String] { get set }
}

struct ConfigurationErrorsView<ViewModel: ConfigurationErrorsViewModel>: View {
    @ObservedObject var model: ViewModel

    var body: some View {
        VStack {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 52))
                    .padding()
                    .frame(alignment: .center)
                    .accessibilityLabel("Configuration error warning")

                Text("""
                    ^[\(model.errors.count) error(s) were](inflect: true) found while loading the configuration. \
                    Please review the errors below and reload your configuration or ignore the erroneous lines.
                    """)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(model.errors, id: \.self) { error in
                            Text(error)
                                .lineLimit(nil)
                                .font(.system(size: 12).monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }

                        Spacer()
                    }
                    .padding(.all)
                    .frame(minHeight: geo.size.height)
                    .background(Color(.controlBackgroundColor))
                }
            }

            HStack {
                Button("Open Configuration…") { openConfig() }
                Spacer()
                Button("Ignore") { model.errors = [] }
                    .keyboardShortcut(.cancelAction)
                Button("Reload Configuration") { reloadConfig() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding([.bottom, .trailing])
        }
        .frame(minWidth: 480, maxWidth: 960, minHeight: 270)
    }

    private func reloadConfig() {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
        delegate.reloadConfig(nil)
    }

    /// Opens the active configuration file through the application delegate.
    private func openConfig() {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
        delegate.openConfig(nil)
    }
}
