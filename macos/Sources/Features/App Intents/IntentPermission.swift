import AppKit

/// Requests permission for Shortcuts app to interact with Toastty
///
/// This function displays a permission dialog asking the user to allow Shortcuts
/// to interact with Toastty. The permission is cached persistently
/// (allowDuration: .forever) if the user selects "Allow", meaning subsequent
/// intent calls won't show the dialog again.
///
/// The permission uses a shared UserDefaults key across all intents, so granting
/// permission for one intent allows all Toastty intents to execute without additional
/// prompts.
/// 
/// - Returns: `true` if permission is granted, `false` if denied
/// 
/// ## Usage
/// Add this check at the beginning of any App Intent's `perform()` method:
/// ```swift
/// @MainActor
/// func perform() async throws -> some IntentResult {
///     guard await requestIntentPermission() else {
///         throw GhosttyIntentError.permissionDenied
///     }
///     // ... continue with intent implementation
/// }
/// ```
func requestIntentPermission() async -> Bool {
    await withCheckedContinuation { continuation in
        Task { @MainActor in
            if let delegate = NSApp.delegate as? AppDelegate {
                switch delegate.ghostty.config.macosShortcuts {
                case .allow:
                    continuation.resume(returning: true)
                    return

                case .deny:
                    continuation.resume(returning: false)
                    return

                case .ask:
                    // Continue with the permission dialog
                    break
                }
            }

            PermissionRequest.show(
                "com.dar7an.toastty.shortcutsPermission",
                message: "Allow Shortcuts to interact with Toastty?",
                allowDuration: .forever,
                rememberDuration: nil,
            ) { response in
                continuation.resume(returning: response)
            }
        }
    }
}
