import AppKit
import Combine
import GhosttyKit
import Testing
@testable import Ghostty

@MainActor
@Suite(.serialized)
struct TabSidebarModelTests {
    // AppKit can retain attached views past fixture teardown. Keep their core
    // alive for the process lifetime, as the real application does.
    private static var directoryFixtureApp: Ghostty.App?

    @Test func projectReorderingPersistsWithoutMovingTabsOrChangingSelection() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let alpha = TerminalProject(name: "Alpha")
        let beta = TerminalProject(name: "Beta")
        let gamma = TerminalProject(name: "Gamma")
        let controllers = [alpha, beta, alpha, gamma].map { project in
            let controller = TerminalController(app, withSurfaceTree: .init(), project: project)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .preferred
            controller.window = window
            return controller
        }
        let windows = controllers.compactMap(\.window)
        defer {
            controllers.forEach { $0.window = nil }
            windows.forEach { $0.close() }
        }
        for window in windows.dropFirst() { windows[0].addTabbedWindow(window, ordered: .above) }
        let group = try #require(windows[0].tabGroup)
        let model = group.tabSidebarModel
        await drainMainQueue()
        model.select(ObjectIdentifier(windows[2]), stealFocus: false)
        var redundantUpdates = 0
        let selectionObservation = model.objectWillChange.sink { redundantUpdates += 1 }
        model.selectProject(alpha.id, stealFocus: false)
        #expect(redundantUpdates == 0)
        withExtendedLifetime(selectionObservation) {}
        let nativeOrder = group.windows
        let original = model.projects.map(\.id)
        let selected = model.selection
        let alphaTabs = model.visibleTabs.map(\.id)
        let expected = Array(original.dropFirst()) + [original[0]]

        let item = try #require(model.dragItem(for: original[0]))
        let data = try #require(item.data(forType: .init(ProjectSidebarDragPayload.typeIdentifier)))
        let payload = try JSONDecoder().decode(ProjectSidebarDragPayload.self, from: data)
        #expect(!model.acceptProjectDrop(.init(groupID: UUID(), projectID: original[0]), at: 3))
        #expect(!model.acceptProjectDrop(.init(groupID: model.dragID, projectID: UUID()), at: 3))
        #expect(!model.acceptProjectDrop(payload, at: 4))
        #expect(model.acceptProjectDrop(payload, at: 3))
        #expect(model.projects.map(\.id) == expected)
        #expect(group.windows == nativeOrder)
        #expect(model.selection == selected)
        #expect(model.visibleTabs.map(\.id) == alphaTabs)
        #expect(model.restoreTargetRow(for: alpha.id)?.window === windows[2])

        // Every tab carries the same persisted project rank. Restoring the
        // metadata into a fresh model must not depend on native tab order.
        for controller in controllers {
            let encoded = try JSONEncoder().encode(controller.project)
            controller.project = try JSONDecoder().decode(TerminalProject.self, from: encoded)
            #expect(controller.project.sidebarOrder == expected.firstIndex(of: controller.project.id))
        }
        let restored = TabSidebarModel(tabGroup: group)
        restored.refresh()
        #expect(restored.projects.map(\.id) == expected)
        #expect(!restored.canMoveProject(expected[0], by: -1))
        #expect(!restored.canMoveProject(expected[2], by: 1))
        restored.moveProject(original[0], by: -2)
        #expect(restored.projects.map(\.id) == original)

        // Invalid/native no-op drops leave ranks and selection alone.
        let previous = controllers.map(\.project)
        restored.moveProjects(fromOffsets: [3], toOffset: 0)
        restored.moveProjects(fromOffsets: [0], toOffset: 1)
        #expect(controllers.map(\.project) == previous)
        #expect(group.selectedWindow === windows[2])
    }

    @Test func directoryFollowsOnlyTheFocusedSplit() async throws {
        let config = try TemporaryConfig("shell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let core = try #require(app.app)
        let first = Ghostty.SurfaceView(core)
        let second = Ghostty.SurfaceView(core)
        try await waitForSyntheticDirectory(on: first, app: app)
        try await waitForSyntheticDirectory(on: second, app: app)
        let controller = TerminalController(app, withSurfaceTree: .init())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        controller.window = window
        defer { controller.window = nil; window.close() }

        first.pwd = "/tmp/first"
        second.pwd = "/tmp/second"
        controller.focusedSurface = first
        let group = try #require(window.tabGroup)
        let model = group.tabSidebarModel
        await drainMainQueue()
        #expect(model.rows.first?.pwd == "/tmp/first")

        controller.focusedSurface = second
        await drainMainQueue()
        #expect(model.rows.first?.pwd == "/tmp/second")

        // Background output from an old split must not overwrite the active one.
        first.pwd = "/tmp/background"
        await drainMainQueue()
        #expect(model.rows.first?.pwd == "/tmp/second")

        second.pwd = "/tmp/current"
        await drainMainQueue()
        #expect(model.rows.first?.pwd == "/tmp/current")

        controller.focusedSurface = nil
        await drainMainQueue()
        second.pwd = "/tmp/closed"
        await drainMainQueue()
        #expect(model.rows.first?.pwd == nil)
    }

    @Test func directoryPrefersSelectedTabsLivePwd() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        Self.directoryFixtureApp = app
        let core = try #require(app.app)
        let alpha = TerminalProject(name: "Alpha", directory: "/tmp/alpha-dir")
        let surfaces = [Ghostty.SurfaceView(core), Ghostty.SurfaceView(core)]
        for surface in surfaces {
            try await waitForSyntheticDirectory(on: surface, app: app)
        }
        let controllers = [alpha, alpha].enumerated().map { index, project in
            let controller = TerminalController(app, withSurfaceTree: .init())
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .preferred
            controller.window = window
            controller.project = project
            window.contentView = surfaces[index]
            controller.focusedSurface = surfaces[index]
            return controller
        }
        let windows = controllers.compactMap(\.window)
        defer {
            controllers.forEach {
                $0.focusedSurface = nil
                $0.window?.contentView = nil
                $0.window = nil
            }
            windows.forEach { $0.close() }
        }
        windows[0].addTabbedWindow(windows[1], ordered: .above)
        windows[0].makeKeyAndOrderFront(nil)
        let group = try #require(windows[0].tabGroup)
        let model = group.tabSidebarModel
        surfaces[0].pwd = "/tmp/first"
        surfaces[1].pwd = "/tmp/second"
        await drainMainQueue()

        // The label tracks the tab the project would restore to.
        model.select(ObjectIdentifier(windows[1]), stealFocus: false)
        await drainMainQueue()
        #expect(group.selectedWindow === windows[1])
        #expect(model.directory(for: controllers[0].project) == "/tmp/second")
        model.select(ObjectIdentifier(windows[0]), stealFocus: false)
        await drainMainQueue()
        #expect(group.selectedWindow === windows[0])
        #expect(model.directory(for: controllers[0].project) == "/tmp/first")

        // When the restore target has no pwd, a sibling tab's live pwd wins.
        surfaces[0].pwd = nil
        await drainMainQueue()
        #expect(model.directory(for: controllers[0].project) == "/tmp/second")

        // With no live pwd the last tracked directory is shown.
        surfaces.forEach { $0.pwd = nil }
        await drainMainQueue()
        #expect(model.directory(for: controllers[0].project) == "/tmp/first")
    }

    @Test func projectsOwnTabsAndRememberSelection() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let alpha = TerminalProject(name: "Alpha")
        let beta = TerminalProject(name: "Beta")
        let controllers = [alpha, alpha, beta, beta].map { project in
            let controller = TerminalController(app, withSurfaceTree: .init())
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .preferred
            controller.window = window
            controller.project = project
            return controller
        }
        let windows = controllers.compactMap(\.window)
        defer {
            controllers.forEach { $0.window = nil }
            windows.forEach { $0.close() }
        }
        for window in windows.dropFirst() { windows[0].addTabbedWindow(window, ordered: .above) }
        let group = try #require(windows[0].tabGroup)
        let model = group.tabSidebarModel
        await drainMainQueue()

        model.select(ObjectIdentifier(windows[1]))
        #expect(Set(model.visibleTabs.map(\.id)) == Set(windows.prefix(2).map(ObjectIdentifier.init)))
        #expect(controllers[0].projectTabWindows.count == 2)
        model.select(ObjectIdentifier(windows[3]))
        #expect(model.selectedProjectID == beta.id)
        #expect(Set(model.visibleTabs.map(\.id)) == Set(windows.suffix(2).map(ObjectIdentifier.init)))
        model.selectProject(alpha.id)
        #expect(model.selection == ObjectIdentifier(windows[1]))
        model.selectProject(beta.id)
        #expect(model.selection == ObjectIdentifier(windows[3]))

        // Closing other tabs is confined to the selected project.
        controllers[3].closeOtherTabs(nil)
        await drainMainQueue()
        #expect(group.windows.contains(windows[0]))
        #expect(group.windows.contains(windows[1]))
        #expect(!group.windows.contains(windows[2]))
        #expect(group.windows.contains(windows[3]))
        model.selectProject(alpha.id)
        #expect(model.selection == ObjectIdentifier(windows[1]))
    }

    @Test func legacyRestoredTabsBecomeOneProject() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let controllers = (0..<2).map { _ in
            let controller = TerminalController(app, withSurfaceTree: .init())
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .preferred
            controller.window = window
            controller.projectNeedsMigration = true
            return controller
        }
        let windows = controllers.compactMap(\.window)
        defer {
            controllers.forEach { $0.window = nil }
            windows.forEach { $0.close() }
        }
        // AppKit initially restores windows independently, then assembles groups.
        _ = windows[0].tabGroup?.tabSidebarModel
        _ = windows[1].tabGroup?.tabSidebarModel
        await drainMainQueue()
        #expect(controllers[0].project.id != controllers[1].project.id)
        windows[0].addTabbedWindow(windows[1], ordered: .above)
        await drainMainQueue()
        let model = try #require(windows[0].tabGroup?.tabSidebarModel)
        #expect(model.projects.count == 1)
        #expect(controllers[0].project.id == controllers[1].project.id)
        #expect(model.visibleTabs.count == 2)
    }

    @Test func inheritedProjectLayoutIsAppliedBeforeWindowLoad() throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = false\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let project = TerminalProject(name: "Existing project")
        let controller = TerminalController(app, withSurfaceTree: .init(),
                                            project: project, usesProjectSidebar: true)
        // Setting opacity may load the window before newTab reaches showWindow.
        controller.isBackgroundOpaque = true
        let window = try #require(controller.window as? TerminalWindow)
        defer { window.close() }
        #expect(controller.project.id == project.id)
        #expect(controller.usesProjectSidebar)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .hidden)
        #expect(window.toolbar?.identifier.hasPrefix("ProjectToolbar.") == true)
    }

    @Test func tabColorTargetsClickedTabAndNoneClears() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let controllers = (0..<2).map { _ in
            let controller = TerminalController(app, withSurfaceTree: .init())
            let window = TerminalWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .preferred
            controller.window = window
            return controller
        }
        let windows = controllers.compactMap(\.window)
        defer {
            controllers.forEach { $0.window = nil }
            windows.forEach { $0.close() }
        }
        windows[0].addTabbedWindow(windows[1], ordered: .above)
        let group = try #require(windows[0].tabGroup)
        let model = group.tabSidebarModel
        await drainMainQueue()
        #expect(model.rows.allSatisfy { $0.tabColor == TerminalTabColor.none })

        // Coloring the second tab (even while inactive) affects only that tab.
        (windows[1] as? TerminalWindow)?.tabColor = .blue
        await drainMainQueue()
        #expect(model.rows.first(where: { $0.window == windows[1] })?.tabColor == TerminalTabColor.blue)
        #expect(model.rows.first(where: { $0.window == windows[0] })?.tabColor == TerminalTabColor.none)

        // None clears the color.
        (windows[1] as? TerminalWindow)?.tabColor = .none
        await drainMainQueue()
        #expect(model.rows.first(where: { $0.window == windows[1] })?.tabColor == TerminalTabColor.none)
    }

    @Test func colorPaletteOrderMatchesEnumOrder() {
        #expect(TabColorMenuView.paletteColors == TerminalTabColor.allCases)
        #expect(TabColorMenuView.paletteColors.first == TerminalTabColor.none)
        // Pinned so an accidental palette addition fails instead of passing silently.
        #expect(TabColorMenuView.paletteColors.count == 10)
    }

    @Test func renameCommitChangesOnlyDisplayName() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let alpha = TerminalProject(name: "Alpha", directory: "/tmp/alpha-dir")
        let beta = TerminalProject(name: "Beta", directory: "/tmp/beta-dir")
        let controllers = [alpha, alpha, beta].map { project in
            let controller = TerminalController(app, withSurfaceTree: .init())
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .preferred
            controller.window = window
            controller.project = project
            return controller
        }
        let windows = controllers.compactMap(\.window)
        defer {
            controllers.forEach { $0.window = nil }
            windows.forEach { $0.close() }
        }
        for window in windows.dropFirst() { windows[0].addTabbedWindow(window, ordered: .above) }
        let group = try #require(windows[0].tabGroup)
        let model = group.tabSidebarModel
        await drainMainQueue()

        // The two clicks can arrive through different windows' sidebar views.
        model.selectProject(beta.id)
        model.clickProject(alpha.id, timestamp: 10)
        #expect(model.selectedProjectID == alpha.id)
        #expect(model.editingProjectID == nil)
        await drainMainQueue()
        model.clickProject(alpha.id, timestamp: 10 + NSEvent.doubleClickInterval / 2)
        #expect(model.editingProjectID == alpha.id)
        #expect(model.editingDraft == "Alpha")
        model.editingDraft = "  Renamed  "
        // Clicking the editor must not select the terminal or reset the draft.
        model.clickProject(alpha.id, timestamp: 11)
        #expect(model.editingDraft == "  Renamed  ")
        model.commitRename()
        await drainMainQueue()

        let renamed = try #require(model.projects.first(where: { $0.id == alpha.id }))
        #expect(renamed.displayName == "Renamed")
        #expect(projectDisplayName(renamed) == "Renamed")
        #expect(renamed.id == alpha.id)
        #expect(renamed.directory == "/tmp/alpha-dir")
        // Workstream A: `name` is the resolved display name (no stored name).
        #expect(renamed.name == "Renamed")
        #expect(controllers[0].project.nameOverride == "Renamed")
        #expect(controllers[1].project.nameOverride == "Renamed")
        #expect(controllers[0].project.id == alpha.id)
        #expect(controllers[1].project.id == alpha.id)
        #expect(controllers[2].project.nameOverride == "Beta")
        #expect(model.editingProjectID == nil)
    }

    @Test func renameCancelDiscardsAndEmptyRestoresDefault() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let alpha = TerminalProject(name: "Alpha", directory: "/tmp/alpha-dir")
        let controller = TerminalController(app, withSurfaceTree: .init())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        controller.window = window
        controller.project = alpha
        defer { controller.window = nil; window.close() }
        let group = try #require(window.tabGroup)
        let model = group.tabSidebarModel
        await drainMainQueue()

        // Escape-equivalent cancel discards a valid draft.
        model.beginRename(projectID: alpha.id)
        model.editingDraft = "Discarded"
        model.cancelRename()
        await drainMainQueue()
        #expect(model.projects.first?.displayName == "Alpha")
        #expect(controller.project.nameOverride == "Alpha")
        #expect(model.editingProjectID == nil)

        // Blank clears the override and restores the derived name,
        // matching tab rename behavior.
        model.beginRename(projectID: alpha.id)
        model.editingDraft = "   "
        model.commitRename()
        await drainMainQueue()
        #expect(model.projects.first?.displayName == "alpha-dir")
        #expect(controller.project.nameOverride == nil)
        #expect(controller.project.directory == "/tmp/alpha-dir")
        #expect(model.editingProjectID == nil)
    }

    @Test func newProjectShortcutUsesCurrentDirectory() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let core = try #require(app.app)
        let surface = Ghostty.SurfaceView(core)
        // The directory must exist: the spawned surface otherwise falls back
        // to home and live tracking records the real cwd instead.
        surface.pwd = "/private/tmp"
        let controller = TerminalController(app, withSurfaceTree: .init())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        controller.window = window
        controller.project = TerminalProject(name: "Original", directory: "/tmp/orig")
        controller.focusedSurface = surface
        defer {
            let grouped = window.tabGroup?.windows ?? [window]
            grouped.compactMap { $0.windowController as? TerminalController }.forEach { $0.window = nil }
            grouped.forEach { $0.close() }
        }

        let fileMenu = try #require(NSApp.mainMenu?.items.first { $0.submenu?.title == "File" }?.submenu)
        let item = try #require(fileMenu.items.first { $0.action == #selector(TerminalController.newProject(_:)) })
        let previousTarget = item.target
        item.target = controller
        defer { item.target = previousTarget }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))
        #expect(fileMenu.performKeyEquivalent(with: event))
        await drainMainQueue()

        let grouped = try #require(window.tabGroup?.windows)
        #expect(grouped.count == 2)
        let created = try #require(grouped.compactMap { $0.windowController as? TerminalController }
            .first(where: { $0.project.id != controller.project.id }))
        #expect(created.project.directory == "/private/tmp")
        #expect(created.project.displayName == "tmp")
        #expect(created.usesProjectSidebar)

        // Unwind the focused-surface observation before teardown so the live
        // surface destroys deterministically instead of racing test exit.
        controller.focusedSurface = nil
        await drainMainQueue()
    }

    @Test func legacyProjectDecodesWithoutNewKeys() throws {
        let json = #"{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","name":"Old"}"#
        let decoded = try JSONDecoder().decode(TerminalProject.self, from: Data(json.utf8))
        #expect(decoded.directory == nil)
        #expect(decoded.emoji == nil)
        #expect(decoded.color == .none)
        // Workstream A: a legacy `name` decodes as the preserved override.
        #expect(decoded.nameOverride == "Old")
        #expect(decoded.displayName == "Old")
        #expect(projectDisplayName(decoded) == "Old")
    }

    @Test func projectEmojiValidationAndAppearanceRoundTrip() throws {
        let project = TerminalProject(
            directory: "/tmp/appearance",
            nameOverride: "Appearance",
            selectedTabID: UUID(),
            emoji: "👨‍💻",
            color: .purple)

        #expect(project.emoji == "👨‍💻")
        #expect(project.color == .purple)
        #expect(TerminalProject.normalizedEmoji("😀") == "😀")
        #expect(TerminalProject.normalizedEmoji("👍🏽") == "👍🏽")
        #expect(TerminalProject.normalizedEmoji("🏳️‍🌈") == "🏳️‍🌈")
        #expect(TerminalProject.normalizedEmoji("1️⃣") == "1️⃣")
        #expect(TerminalProject.normalizedEmoji("ordinary") == nil)
        #expect(TerminalProject.normalizedEmoji("😀😀") == nil)
        #expect(TerminalProject.normalizedEmoji("A") == nil)
        // `isEmoji` is true for ASCII digits and symbols that still render
        // as text, so validation requires default emoji presentation or the
        // U+FE0F emoji selector.
        #expect(TerminalProject.normalizedEmoji("0") == nil)
        #expect(TerminalProject.normalizedEmoji("#") == nil)
        #expect(TerminalProject.normalizedEmoji("A\u{FE0F}") == nil)

        let encoded = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(TerminalProject.self, from: encoded)
        #expect(decoded == project)

        let invalidJSON = #"{"name":"Invalid","emoji":"ordinary","color":0}"#
        let invalid = try JSONDecoder().decode(
            TerminalProject.self, from: Data(invalidJSON.utf8))
        #expect(invalid.emoji == nil)
        #expect(invalid.color == .none)

        // A color written by a newer build decodes as none instead of
        // failing the whole project's restoration.
        let unknownColorJSON = #"{"name":"Newer","color":99}"#
        let unknownColor = try JSONDecoder().decode(
            TerminalProject.self, from: Data(unknownColorJSON.utf8))
        #expect(unknownColor.color == .none)
        #expect(unknownColor.nameOverride == "Newer")
    }

    /// Verifies that project appearance changes affect only matching project tabs.
    @Test func projectAppearanceUpdatesMatchingTabsOnly() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let alpha = TerminalProject(name: "Alpha", directory: "/tmp/alpha")
        let beta = TerminalProject(name: "Beta", directory: "/tmp/beta")
        let controllers = [alpha, alpha, beta].map { project in
            let controller = TerminalController(app, withSurfaceTree: .init())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .preferred
            controller.window = window
            controller.project = project
            return controller
        }
        let windows = controllers.compactMap(\.window)
        defer {
            controllers.forEach { $0.window = nil }
            windows.forEach { $0.close() }
        }
        for window in windows.dropFirst() { windows[0].addTabbedWindow(window, ordered: .above) }
        let group = try #require(windows[0].tabGroup)
        let model = group.tabSidebarModel
        await drainMainQueue()

        let originalID = controllers[0].project.id
        let originalDirectory = controllers[0].project.directory
        let originalName = controllers[0].project.nameOverride
        let menu = makeProjectContextMenu(project: alpha, model: model)
        #expect(menu.items.last?.title == "Delete Project")
        #expect(menu.items.dropLast().last?.isSeparatorItem == true)
        #expect(!menu.items.contains { $0.title == "Reset Emoji" || $0.title == "Reset Project Appearance" })
        #expect(!menu.items.contains { $0.title == "Move Project Up" })
        #expect(menu.items.contains { $0.title == "Move Project Down" })
        let palette = try #require(menu.items.compactMap { $0.view as? TabColorPaletteRowView }.first)
        let buttons = palette.arrangedSubviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == TerminalTabColor.allCases.count)
        #expect(palette.frame.width <= 320)
        #expect(!menu.items.contains { $0.title == "Blue" })
        buttons[TerminalTabColor.blue.rawValue].performClick(nil)
        model.beginProjectEmojiEdit(projectID: alpha.id)
        model.editingProjectEmojiDraft = "🧪"
        model.commitProjectEmojiEdit()
        await drainMainQueue()

        for controller in controllers.prefix(2) {
            #expect(controller.project.id == originalID)
            #expect(controller.project.directory == originalDirectory)
            #expect(controller.project.nameOverride == originalName)
            #expect(controller.project.emoji == "🧪")
            #expect(controller.project.color == .blue)
        }
        #expect(controllers[2].project.emoji == nil)
        #expect(controllers[2].project.color == .none)
        #expect(model.projects.first(where: { $0.id == alpha.id })?.emoji == "🧪")
        #expect(model.projects.first(where: { $0.id == alpha.id })?.color == .blue)

        let customized = try #require(model.projects.first(where: { $0.id == alpha.id }))
        let customizedMenu = makeProjectContextMenu(project: customized, model: model)
        #expect(customizedMenu.items.contains { $0.title == "Reset Emoji" })
        #expect(customizedMenu.items.contains { $0.title == "Reset Project Appearance" })

        model.resetProjectEmoji(for: alpha.id)
        #expect(controllers[0].project.emoji == nil)
        #expect(controllers[1].project.emoji == nil)
        #expect(controllers[0].project.color == .blue)
        #expect(controllers[1].project.color == .blue)
        model.resetProjectAppearance(for: alpha.id)
        await drainMainQueue()
        #expect(controllers[0].project.emoji == nil)
        #expect(controllers[0].project.color == .none)
        #expect(controllers[1].project.emoji == nil)
        #expect(controllers[1].project.color == .none)
        #expect(controllers[2].project.emoji == nil)
        #expect(controllers[2].project.color == .none)
    }

    @Test func directoryDerivedDisplayNames() {
        #expect(TerminalProject(directory: "/Users/sam/Code/ghostty").displayName == "ghostty")
        #expect(TerminalProject(directory: "/tmp/with space").displayName == "with space")
        #expect(TerminalProject(directory: "/tmp/ünicode-☃").displayName == "ünicode-☃")
        #expect(TerminalProject(directory: "/").displayName == "/")
        #expect(TerminalProject(directory: "/").automaticName == "/")
        #expect(TerminalProject().displayName == "Terminal")
        #expect(TerminalProject().automaticName == "Terminal")
        #expect(TerminalProject(directory: "").displayName == "Terminal")
        // An override (even blank-tolerant) wins over the directory.
        #expect(TerminalProject(directory: "/tmp/x", nameOverride: "Custom").displayName == "Custom")
        #expect(TerminalProject(directory: "/tmp/x", nameOverride: "  ").displayName == "x")
        #expect(TerminalProject(directory: "/tmp/x", nameOverride: "").displayName == "x")
        #expect(projectDisplayName(TerminalProject(directory: "/tmp/x")) == "x")
    }

    @Test func homeDirectoryAbbreviation() {
        let home = NSHomeDirectory()
        #expect(TerminalProject(directory: home).abbreviatedDirectory == "~")
        #expect(TerminalProject(directory: home + "/Code/ghostty").abbreviatedDirectory == "~/Code/ghostty")
        // Paths outside home (including spaces and Unicode) pass through unchanged.
        #expect(TerminalProject(directory: "/tmp/with space/ünicode").abbreviatedDirectory == "/tmp/with space/ünicode")
        #expect(TerminalProject(directory: "/").abbreviatedDirectory == "/")
        #expect(TerminalProject().abbreviatedDirectory == nil)
    }

    @Test func lateDirectorySeedsThenTracksLiveCwdThroughRename() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let core = try #require(app.app)
        let surface = Ghostty.SurfaceView(core)
        try await waitForSyntheticDirectory(on: surface, app: app)
        surface.pwd = nil
        let controller = TerminalController(app, withSurfaceTree: .init())
        // Unavailable initial directory: generic name, no subtitle source.
        #expect(controller.project.directory == nil)
        #expect(controller.project.displayName == "Terminal")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        controller.window = window
        defer { controller.window = nil; window.close() }
        controller.focusedSurface = surface
        await drainMainQueue()
        #expect(controller.project.directory == nil)
        #expect(controller.project.displayName == "Terminal")

        // A late-arriving shell directory seeds the project…
        surface.pwd = "/tmp/late dir/ünicode"
        await drainMainQueue()
        #expect(controller.project.directory == "/tmp/late dir/ünicode")
        #expect(controller.project.displayName == "ünicode")

        // …and each `cd` keeps tracking it, name included.
        surface.pwd = "/tmp/elsewhere"
        await drainMainQueue()
        let model = try #require(window.tabGroup).tabSidebarModel
        #expect(controller.project.directory == "/tmp/elsewhere")
        #expect(controller.project.displayName == "elsewhere")
        #expect(model.projects.first?.displayName == "elsewhere")
        #expect(model.directory(for: controller.project) == "/tmp/elsewhere")

        // A manual rename pins only the display name; the directory keeps
        // tracking the anchor's live cwd so new tabs start there.
        model.beginRename(projectID: controller.project.id)
        model.editingDraft = "Custom"
        model.commitRename()
        surface.pwd = "/tmp/third"
        await drainMainQueue()
        #expect(controller.project.nameOverride == "Custom")
        #expect(controller.project.directory == "/tmp/third")
        #expect(controller.project.displayName == "Custom")
        #expect(model.projects.first?.displayName == "Custom")
        #expect(model.directory(for: controller.project) == "/tmp/third")

        // Unwind the focused-surface observation before teardown so the live
        // surface destroys deterministically instead of racing test exit.
        controller.focusedSurface = nil
        await drainMainQueue()
    }

    @Test func projectDirectoryTracksAnchorTabLiveCwd() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        Self.directoryFixtureApp = app
        let core = try #require(app.app)
        let alpha = TerminalProject(directory: "/tmp/alpha")
        let surfaces = [Ghostty.SurfaceView(core), Ghostty.SurfaceView(core)]
        for surface in surfaces {
            try await waitForSyntheticDirectory(on: surface, app: app)
        }
        let controllers = [alpha, alpha].enumerated().map { index, project in
            let controller = TerminalController(app, withSurfaceTree: .init())
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .preferred
            controller.window = window
            controller.project = project
            window.contentView = surfaces[index]
            controller.focusedSurface = surfaces[index]
            return controller
        }
        let windows = controllers.compactMap(\.window)
        defer {
            controllers.forEach {
                $0.focusedSurface = nil
                $0.window?.contentView = nil
                $0.window = nil
            }
            windows.forEach { $0.close() }
        }
        windows[0].addTabbedWindow(windows[1], ordered: .above)
        windows[0].makeKeyAndOrderFront(nil)
        let group = try #require(windows[0].tabGroup)
        let model = group.tabSidebarModel
        await drainMainQueue()

        // A `cd` in the anchor tab updates the directory on every sibling
        // controller and re-renders the derived name.
        model.select(ObjectIdentifier(windows[0]), stealFocus: false)
        surfaces[0].pwd = "/tmp/moved"
        await drainMainQueue()
        for controller in controllers {
            #expect(controller.project.directory == "/tmp/moved")
            #expect(controller.project.displayName == "moved")
        }
        #expect(model.projects.first?.displayName == "moved")
        #expect(model.directory(for: controllers[0].project) == "/tmp/moved")

        // A `cd` in a background (non-anchor) tab leaves the project alone.
        surfaces[1].pwd = "/tmp/other"
        await drainMainQueue()
        #expect(controllers[0].project.directory == "/tmp/moved")
        #expect(model.projects.first?.displayName == "moved")

        // Selecting the background tab makes it the anchor and adopts its
        // last reported directory without waiting for another report.
        model.select(ObjectIdentifier(windows[1]), stealFocus: false)
        await drainMainQueue()
        #expect(controllers[0].project.directory == "/tmp/other")
        #expect(controllers[1].project.directory == "/tmp/other")
        #expect(model.projects.first?.displayName == "other")
        #expect(model.directory(for: controllers[0].project) == "/tmp/other")
    }

    @Test func newProjectTabStartsInRememberedDirectory() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /bin/cat")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let parent = TerminalController(app, withSurfaceTree: .init())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        parent.window = window
        parent.project = TerminalProject(directory: "/tmp")
        defer {
            let grouped = window.tabGroup?.windows ?? [window]
            grouped.compactMap { $0.windowController as? TerminalController }.forEach { $0.window = nil }
            grouped.forEach { $0.close() }
        }

        let tab = try #require(TerminalController.newTab(app, from: window, registerUndo: false))
        #expect(tab.project.id == parent.project.id)
        let surface = try #require(tab.focusedSurface)
        try await waitForStartupDirectory(on: surface, app: app)
        #expect(try surface.pwd.map { try physicalPath(URL(fileURLWithPath: $0)) } == physicalPath(URL(fileURLWithPath: "/tmp")))

        tab.focusedSurface = nil
        await drainMainQueue()
    }

    @Test func newProjectTabOverridesInheritedTabConfig() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /bin/cat")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let core = try #require(app.app)
        let source = Ghostty.SurfaceView(core)
        try await waitForStartupDirectory(on: source, app: app)
        // The ghosttyNewTab path embeds the source surface's live pwd into a
        // `.tab`-context config; the project's directory must still win.
        var inherited = Ghostty.SurfaceConfiguration(
            from: ghostty_surface_inherited_config(
                try #require(source.surface), GHOSTTY_SURFACE_CONTEXT_TAB))
        inherited.workingDirectory = "/usr"
        let parent = TerminalController(app, withSurfaceTree: .init())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        parent.window = window
        parent.project = TerminalProject(directory: "/tmp")
        defer {
            let grouped = window.tabGroup?.windows ?? [window]
            grouped.compactMap { $0.windowController as? TerminalController }.forEach { $0.window = nil }
            grouped.forEach { $0.close() }
        }

        let tab = try #require(TerminalController.newTab(
            app, from: window, withBaseConfig: inherited, registerUndo: false))
        let surface = try #require(tab.focusedSurface)
        try await waitForStartupDirectory(on: surface, app: app)
        #expect(try surface.pwd.map { try physicalPath(URL(fileURLWithPath: $0)) } == physicalPath(URL(fileURLWithPath: "/tmp")))

        tab.focusedSurface = nil
        await drainMainQueue()
    }

    @Test func newProjectTabKeepsExplicitWorkingDirectory() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /bin/cat")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let parent = TerminalController(app, withSurfaceTree: .init())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        parent.window = window
        parent.project = TerminalProject(directory: "/tmp")
        defer {
            let grouped = window.tabGroup?.windows ?? [window]
            grouped.compactMap { $0.windowController as? TerminalController }.forEach { $0.window = nil }
            grouped.forEach { $0.close() }
        }

        // A window-context config with an explicit directory (dock drop,
        // services, script records) is not an inherited-pwd config and is
        // left alone.
        var explicit = Ghostty.SurfaceConfiguration()
        explicit.workingDirectory = "/usr"
        let tab = try #require(TerminalController.newTab(
            app, from: window, withBaseConfig: explicit, registerUndo: false))
        let surface = try #require(tab.focusedSurface)
        try await waitForStartupDirectory(on: surface, app: app)
        #expect(surface.pwd == "/usr")

        tab.focusedSurface = nil
        await drainMainQueue()
    }

    @Test func legacyBackfillKeepsLegacyName() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let core = try #require(app.app)
        let surface = Ghostty.SurfaceView(core)
        try await waitForSyntheticDirectory(on: surface, app: app)
        surface.pwd = "/tmp/remembered"
        // Legacy shape: preserved name, no directory yet.
        let legacy = TerminalProject(name: "Legacy")
        let controller = TerminalController(app, withSurfaceTree: .init())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        controller.window = window
        controller.project = legacy
        controller.focusedSurface = surface
        defer { controller.window = nil; window.close() }
        let group = try #require(window.tabGroup)
        let model = group.tabSidebarModel
        await drainMainQueue()

        #expect(controller.project.directory == "/tmp/remembered")
        #expect(controller.project.displayName == "Legacy")
        #expect(controller.project.nameOverride == "Legacy")
        #expect(model.projects.first?.directory == "/tmp/remembered")
        #expect(model.projects.first?.displayName == "Legacy")

        // Unwind the focused-surface observation before teardown so the live
        // surface destroys deterministically instead of racing test exit.
        controller.focusedSurface = nil
        await drainMainQueue()
    }

    @Test func backfillUsesRememberedSelectedTab() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let core = try #require(app.app)
        let first = Ghostty.SurfaceView(core)
        let second = Ghostty.SurfaceView(core)
        for surface in [first, second] {
            try await waitForSyntheticDirectory(on: surface, app: app)
        }
        first.pwd = "/tmp/aaa"
        second.pwd = "/tmp/bbb"
        let c0 = TerminalController(app, withSurfaceTree: .init())
        let c1 = TerminalController(app, withSurfaceTree: .init())
        var shared = TerminalProject(name: "Shared")
        shared.selectedTabID = c0.projectTabID
        c0.project = shared
        c1.project = shared
        c0.focusedSurface = first
        c1.focusedSurface = second
        let w0 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let w1 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        for w in [w0, w1] {
            w.isReleasedWhenClosed = false
            w.tabbingMode = .preferred
        }
        c0.window = w0
        c1.window = w1
        defer {
            c0.window = nil
            c1.window = nil
            w0.close()
            w1.close()
        }
        w0.addTabbedWindow(w1, ordered: .above)
        let group = try #require(w0.tabGroup)
        _ = group.tabSidebarModel
        await drainMainQueue()

        // Both tabs share the remembered tab's directory; the name is untouched.
        #expect(c0.project.directory == "/tmp/aaa")
        #expect(c1.project.directory == "/tmp/aaa")
        #expect(c0.project.displayName == "Shared")
        #expect(c1.project.displayName == "Shared")

        // Unwind the focused-surface observations before teardown so the live
        // surfaces destroy deterministically instead of racing test exit.
        c0.focusedSurface = nil
        c1.focusedSurface = nil
        await drainMainQueue()
    }

    // MARK: - Sidebar Collapse (workstream C)

    @Test func sidebarCollapseIsIndependentPerWindow() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let controllers = (0..<2).map { _ in
            let controller = TerminalController(app, withSurfaceTree: .init())
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .preferred
            controller.window = window
            return controller
        }
        let windows = controllers.compactMap(\.window)
        defer {
            controllers.forEach { $0.window = nil }
            windows.forEach { $0.close() }
        }
        // Separate windows live in separate tab groups with separate models.
        let first = try #require(windows[0].tabGroup?.tabSidebarModel)
        let second = try #require(windows[1].tabGroup?.tabSidebarModel)
        #expect(first !== second)
        await drainMainQueue()
        #expect(first.sidebarState.isVisible)
        #expect(second.sidebarState.isVisible)

        // Pick a width distinct from whatever width preference a previous run
        // persisted, so the independence assertion below is deterministic.
        let secondWidth = second.sidebarState.expandedWidth
        let firstWidth: CGFloat = secondWidth > 240 ? 160 : 320
        first.setVisible(false)
        first.setExpandedWidth(firstWidth)
        await drainMainQueue()
        #expect(!first.sidebarState.isVisible)
        #expect(first.sidebarState.expandedWidth == firstWidth)
        // The independent window keeps its own expanded state.
        #expect(second.sidebarState.isVisible)
        #expect(second.sidebarState.expandedWidth == secondWidth)
    }

    @Test func newTabsInheritSidebarStateBeforeWindowLoad() throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        // Mirrors TerminalController.newTab: the parent group's state is
        // captured into the child up front (before super.init, like the other
        // project metadata) because surface setup may load the window early.
        let inherited = SidebarState(isVisible: false, expandedWidth: 260)
        let controller = TerminalController(app, withSurfaceTree: .init(),
                                            usesProjectSidebar: true,
                                            sidebarState: inherited)
        #expect(controller.sidebarState == inherited)
        if controller.isWindowLoaded {
            let window = try #require(controller.window as? TerminalWindow)
            #expect(window.styleMask.contains(.fullSizeContentView))
            controller.window = nil
            window.close()
        }
    }

    @Test func movedTabsAdoptDestinationSidebarState() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let controllers = (0..<2).map { _ in
            let controller = TerminalController(app, withSurfaceTree: .init())
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .preferred
            controller.window = window
            return controller
        }
        let windows = controllers.compactMap(\.window)
        defer {
            controllers.forEach { $0.window = nil }
            windows.forEach { $0.close() }
        }
        try #require(windows[0].tabGroup?.tabSidebarModel).setVisible(false)
        #expect(windows[1].tabGroup?.tabSidebarModel.sidebarState.isVisible == true)

        // Moving the first window into the second window's group adopts the
        // destination group's expanded state.
        windows[1].addTabbedWindow(windows[0], ordered: .above)
        await drainMainQueue()
        let current = try #require(windows[0].tabGroup?.tabSidebarModel)
        #expect(current.sidebarState.isVisible)
        #expect(current.rows.count == 2)
        #expect(controllers[0].sidebarState == current.sidebarState)
    }

    @Test func sidebarStateSurvivesRestorableEncoding() throws {
        let tree = try SplitTreeTests.makeHorizontalSplit().0
        let sidebar = SidebarState(isVisible: false, expandedWidth: 280)
        let state = TerminalRestorableState.InternalState(
            focusedSurface: "selected", surfaceTree: tree,
            effectiveFullscreenMode: nil, tabColor: nil, titleOverride: nil,
            project: nil, projectTabID: nil, sidebarState: sidebar)
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TerminalRestorableState.InternalState<MockView>.self, from: encoded)
        #expect(decoded.sidebarState == sidebar)
    }

    @Test func undoStateCarriesMirroredSidebarState() throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let core = try #require(app.app)
        let surface = Ghostty.SurfaceView(core)
        let sidebar = SidebarState(isVisible: false, expandedWidth: 300)
        let controller = TerminalController(app, withSurfaceTree: SplitTree(view: surface),
                                            usesProjectSidebar: true,
                                            sidebarState: sidebar)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        defer { controller.window = nil; window.close() }
        let undo = try #require(controller.undoState)
        #expect(undo.sidebarState == sidebar)
    }

    @Test func livePtyCwdReportsReachProjectAndNewTabs() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let alpha = root.appendingPathComponent("alpha")
        let beta = root.appendingPathComponent("beta")
        let gamma = root.appendingPathComponent("gamma")
        for directory in [alpha, beta, gamma] {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? files.removeItem(at: root) }
        // Foundation and libproc can spell macOS's temp directory as /var
        // and /private/var respectively. Use the kernel's physical spelling
        // for both the launch config and the expected cwd reports.
        let alphaPath = try physicalPath(alpha)
        let betaPath = try physicalPath(beta)
        let gammaPath = try physicalPath(gamma)

        // A non-interactive shell wrapper stays in login(1)'s foreground
        // group, just like Kiro's outer PTY wrapper. It accepts real terminal
        // input and evaluates ordinary cd builtins, without OSC 7 reporting.
        let wrapper = root.appendingPathComponent("wrapper.sh")
        try """
        if [ "$(/bin/ps -o uid= -p "$PPID")" -eq 0 ] && \\
           [ "$(/bin/ps -o pgid= -p $$)" -eq "$PPID" ]; then
          printf 'LOGIN_TOPOLOGY\\n'
        fi
        printf 'READY\\n'
        while IFS= read -r command; do
          eval "$command"
          printf 'READY\\n'
        done
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        let config = try TemporaryConfig("""
        macos-tabs-sidebar = true
        shell-integration = none
        working-directory = \(alphaPath)
        command = direct:/bin/sh \(wrapper.path)
        """)
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        Self.directoryFixtureApp = app
        let parent = TerminalController(app)
        var ptyViews = parent.surfaceTree.root?.leaves() ?? []
        defer { stopPtyViews(ptyViews, app: app) }
        let surface = try #require(parent.surfaceTree.first)
        parent.focusedSurface = surface
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.contentView = surface
        parent.window = window
        ghostty_surface_set_size(surface.surface, 800, 600)
        defer {
            let grouped = window.tabGroup?.windows ?? [window]
            for member in grouped {
                if let controller = member.windowController as? TerminalController {
                    controller.focusedSurface = nil
                    controller.surfaceTree = .init()
                    controller.window = nil
                }
                member.contentView = nil
                member.close()
            }
        }
        let model = window.projectSidebarModel
        await drainMainQueue()
        try await waitForPty(app, "wrapper prompt") { self.ptyText(surface).contains("READY") }
        #expect(ptyText(surface).contains("LOGIN_TOPOLOGY"))
        try await waitForPty(app, "initial cwd") { surface.pwd == alphaPath }

        sendPtyCommand("cd '\(betaPath)'; pwd", to: surface)
        try await waitForPty(app, "ordinary cd propagation") {
            surface.pwd == betaPath && parent.project.directory == betaPath
                && model.directory(for: parent.project) == betaPath
        }
        #expect(parent.project.displayName == "beta")
        #expect(ptyText(surface).contains(betaPath))

        // Two changes in one input batch followed by idle exercise the trailing
        // probe and the complete IO -> action -> publisher -> sidebar path.
        parent.project.nameOverride = "Pinned"
        sendPtyCommand("cd '\(alphaPath)'; cd '\(gammaPath)'; pwd", to: surface)
        try await waitForPty(app, "rapid cd propagation") { surface.pwd == gammaPath && parent.project.directory == gammaPath }
        #expect(parent.project.displayName == "Pinned")
        #expect(model.directory(for: parent.project) == gammaPath)

        let tab = try #require(TerminalController.newTab(app, from: window, registerUndo: false))
        ptyViews += tab.surfaceTree.root?.leaves() ?? []
        let tabSurface = try #require(tab.focusedSurface)
        try await waitForPty(app, "new tab prompt") { self.ptyText(tabSurface).contains("READY") }
        sendPtyCommand("pwd", to: tabSurface)
        try await waitForPty(app, "new tab pwd output") { self.ptyText(tabSurface).contains(gammaPath) }
        #expect(tab.project.id == parent.project.id)
        #expect(tabSurface.pwd == gammaPath)
        #expect(tab.project.displayName == "Pinned")

        // An accepted OSC 7 path can represent a remote session. A subsequent
        // local process cwd change must not overwrite that authoritative path.
        sendPtyCommand("printf '\\033]7;file://localhost/remote/project\\007'; cd '\(betaPath)'; pwd", to: tabSurface)
        try await waitForPty(app, "OSC 7 authority") {
            tabSurface.pwd == "/remote/project" && self.ptyText(tabSurface).contains(betaPath)
        }
        for _ in 0..<70 {
            app.appTick()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(tabSurface.pwd == "/remote/project")
        #expect(tab.project.directory == "/remote/project")
    }

    private func physicalPath(_ url: URL) throws -> String {
        let path = try #require(realpath(url.path, nil))
        defer { free(path) }
        return String(cString: path)
    }

    private func sendPtyCommand(_ command: String, to view: Ghostty.SurfaceView) {
        (command + "\n").withCString { text in
            ghostty_surface_text(view.surface, text, UInt(strlen(text)))
        }
    }

    private func stopPtyViews(_ views: [Ghostty.SurfaceView], app: Ghostty.App) {
        for view in views where !view.processExited { sendPtyCommand("exit", to: view) }
        for _ in 0..<200 where views.contains(where: { !$0.processExited }) {
            app.appTick()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let stopped = views.allSatisfy { $0.processExited }
        #expect(stopped, "Test wrapper processes must exit before fixture files are removed")
    }

    private func ptyText(_ view: Ghostty.SurfaceView) -> String {
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(view.surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(view.surface, &text) }
        return String(cString: text.text)
    }

    private func waitForPty(_ app: Ghostty.App, _ label: String, until condition: () -> Bool) async throws {
        for _ in 0..<300 {
            app.appTick()
            await drainMainQueue()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "Real PTY \(label) did not complete")
        try #require(condition())
    }

    private func drainMainQueue() async {
        // Row rebuilding and Combine delivery each defer one main-queue turn.
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func waitForStartupDirectory(on surface: Ghostty.SurfaceView, app: Ghostty.App) async throws {
        // A real surface reports its launch directory asynchronously. Let that
        // report arrive before tests supply their own pwd transitions.
        for _ in 0..<100 where surface.pwd == nil {
            app.appTick()
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try #require(surface.pwd)
    }

    private func waitForSyntheticDirectory(on surface: Ghostty.SurfaceView, app: Ghostty.App) async throws {
        // Observer-only tests assign artificial pwd values, including nil.
        // Wait for their /usr/bin/true fixture to finish and deliver all real
        // startup reports first, so those reports cannot replace the values
        // being used to test selection, focus, naming, and legacy migration.
        try await waitForStartupDirectory(on: surface, app: app)
        try await waitForPty(app, "synthetic fixture exit") { surface.processExited }
        app.appTick()
        await drainMainQueue()
    }
}
