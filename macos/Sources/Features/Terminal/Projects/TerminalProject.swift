import Foundation

/// Stable identity shared by the tabs that belong to a directory project.
///
/// A project is identified by `id`, so two projects may share the same
/// directory or display name. `directory` is the fixed directory the project
/// was created from — changing directories inside a tab never updates it.
/// `nameOverride` is a user-supplied rename; nil means the name is derived.
struct TerminalProject: Codable, Equatable, Identifiable {
    var id = UUID()
    var directory: String?
    var nameOverride: String?
    var selectedTabID: UUID?

    /// Legacy-compatible display name. Prefer `displayName` in new code.
    var name: String {
        get { displayName }
        set { nameOverride = newValue }
    }

    /// The name shown in the UI: an explicit rename when set, otherwise the
    /// basename of the project directory, otherwise a generic fallback.
    var displayName: String {
        if let override = nameOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        return automaticName
    }

    /// The derived name without any user override: the directory basename,
    /// with root staying "/" and a generic fallback when directory is missing.
    var automaticName: String {
        if let directory, !directory.isEmpty {
            if directory == "/" { return "/" }
            let base = URL(fileURLWithPath: directory).lastPathComponent
            if !base.isEmpty { return base }
            return directory
        }
        return "Terminal"
    }

    /// The project directory with the current user's home abbreviated to `~`.
    /// Paths outside the home directory (including spaces and Unicode) pass
    /// through unchanged.
    var abbreviatedDirectory: String? {
        directory.map { ($0 as NSString).abbreviatingWithTildeInPath }
    }

    init(
        id: UUID = UUID(),
        directory: String? = nil,
        nameOverride: String? = nil,
        selectedTabID: UUID? = nil
    ) {
        self.id = id
        self.directory = directory
        self.nameOverride = nameOverride
        self.selectedTabID = selectedTabID
    }

    /// Legacy initializer: pre-directory projects were identified by name,
    /// which is preserved as the override.
    init(id: UUID = UUID(), name: String, selectedTabID: UUID? = nil, directory: String? = nil) {
        self.init(
            id: id,
            directory: directory,
            nameOverride: name.isEmpty ? nil : name,
            selectedTabID: selectedTabID)
    }

    /// Copy with a new selected tab.
    func withSelectedTab(_ tabID: UUID?) -> TerminalProject {
        var copy = self
        copy.selectedTabID = tabID
        return copy
    }

    /// Remember the project's directory once without changing its display
    /// name. Later `cd`s must never call this: the directory is identity.
    mutating func backfillDirectory(from pwd: String?) {
        guard directory == nil, let pwd, !pwd.isEmpty else { return }
        directory = pwd
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case nameOverride
        case directory
        case selectedTabID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        directory = try container.decodeIfPresent(String.self, forKey: .directory)
        if container.contains(.nameOverride) {
            nameOverride = try container.decodeIfPresent(String.self, forKey: .nameOverride)
        } else if let legacy = try container.decodeIfPresent(String.self, forKey: .name) {
            // Old records only carry the resolved `name`; preserve it as the
            // override so the display name survives the migration.
            nameOverride = legacy
        } else {
            nameOverride = nil
        }
        selectedTabID = try container.decodeIfPresent(UUID.self, forKey: .selectedTabID)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        // The resolved legacy field stays encoded for older clients.
        try container.encode(displayName, forKey: .name)
        // Encoded explicitly (including null) so derived names stay
        // distinguishable from overridden ones across a round-trip.
        try container.encode(nameOverride, forKey: .nameOverride)
        try container.encode(directory, forKey: .directory)
        try container.encode(selectedTabID, forKey: .selectedTabID)
    }
}

