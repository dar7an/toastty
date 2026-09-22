import AppKit
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
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /bin/cat")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        Self.directoryFixtureApp = app
        let core = try #require(app.app)
        let alpha = TerminalProject(name: "Alpha", directory: "/tmp/alpha-dir")
        let surfaces = [Ghostty.SurfaceView(core), Ghostty.SurfaceView(core)]
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

        // With no live pwd the fixed creation directory is shown.
        surfaces.forEach { $0.pwd = nil }
        await drainMainQueue()
        #expect(model.directory(for: controllers[0].project) == "/tmp/alpha-dir")
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
        surface.pwd = "/tmp/fixed-dir"
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
        #expect(created.project.directory == "/tmp/fixed-dir")
        #expect(created.project.displayName == "fixed-dir")
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

    @Test func lateDirectorySeedsOnceAndIgnoresCd() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let core = try #require(app.app)
        let surface = Ghostty.SurfaceView(core)
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

        // Late-arriving shell directory initializes the identity once…
        surface.pwd = "/tmp/late dir/ünicode"
        await drainMainQueue()
        #expect(controller.project.directory == "/tmp/late dir/ünicode")
        #expect(controller.project.displayName == "ünicode")

        // …and a later cd never changes the stored directory.
        surface.pwd = "/tmp/elsewhere"
        await drainMainQueue()
        #expect(controller.project.directory == "/tmp/late dir/ünicode")
        #expect(controller.project.displayName == "ünicode")

        // Unwind the focused-surface observation before teardown so the live
        // surface destroys deterministically instead of racing test exit.
        controller.focusedSurface = nil
        await drainMainQueue()
    }

    @Test func legacyBackfillKeepsLegacyName() async throws {
        let config = try TemporaryConfig("macos-tabs-sidebar = true\nshell-integration = none\ncommand = /usr/bin/true")
        let app = Ghostty.App(configPath: config.temporaryFile.path)
        let core = try #require(app.app)
        let surface = Ghostty.SurfaceView(core)
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
        first.pwd = "/tmp/aaa"
        let second = Ghostty.SurfaceView(core)
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

    private func drainMainQueue() async {
        // Row rebuilding and Combine delivery each defer one main-queue turn.
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}
