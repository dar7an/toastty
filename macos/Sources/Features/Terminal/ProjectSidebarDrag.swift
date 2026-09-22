import AppKit
import ObjectiveC
import SwiftUI
import UniformTypeIdentifiers

struct ProjectSidebarDragPayload: Codable {
    static let contentType = UTType(exportedAs: "com.dar7an.toastty.project", conformingTo: .data)
    static var typeIdentifier: String { contentType.identifier }
    let groupID: UUID
    let projectID: UUID
}

extension TabSidebarModel {
    func dragItem(for projectID: UUID) -> NSPasteboardItem? {
        guard editingProjectID == nil, editingProjectEmojiID == nil,
              projects.contains(where: { $0.id == projectID }),
              let data = try? JSONEncoder().encode(ProjectSidebarDragPayload(groupID: dragID, projectID: projectID)) else {
            return nil
        }
        let item = NSPasteboardItem()
        item.setData(data, forType: .init(ProjectSidebarDragPayload.typeIdentifier))
        return item
    }

    @discardableResult
    func acceptProjectDrop(_ payload: ProjectSidebarDragPayload, at destination: Int) -> Bool {
        guard payload.groupID == dragID, editingProjectID == nil, editingProjectEmojiID == nil,
              let source = projects.firstIndex(where: { $0.id == payload.projectID }),
              (0...projects.count).contains(destination) else { return false }
        moveProjects(fromOffsets: IndexSet(integer: source), toOffset: destination)
        return true
    }
}

/// Delay project activation until mouse-up so switching native tab windows
/// cannot destroy a drag source. The List still owns selection and drop gaps.
struct ProjectSidebarRowInteraction: NSViewRepresentable {
    let model: TabSidebarModel
    let projectID: UUID
    let isEditing: Bool

    func makeNSView(context: Context) -> InteractionView { InteractionView() }

    func updateNSView(_ view: InteractionView, context: Context) {
        view.model = model
        view.isEditing = isEditing
        view.onClick = { model.clickProject(projectID, timestamp: $0) }
        view.makeItem = {
            model.cancelProjectClick()
            return model.dragItem(for: projectID)
        }
        view.configureTable()
    }

    final class InteractionView: NSView, NSDraggingSource {
        weak var model: TabSidebarModel?
        var isEditing = false
        var onClick: (TimeInterval) -> Void = { _ in }
        var makeItem: () -> NSPasteboardItem? = { nil }
        private var mouseDownPoint: NSPoint?
        private var isDragging = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            isEditing ? nil : super.hitTest(point)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            setAccessibilityElement(false)
            configureTable()
        }

        func configureTable() {
            guard let model,
                  let table = ancestors.compactMap({ $0 as? NSOutlineView }).first else { return }
            ProjectSidebarDropCoordinator.install(on: table, model: model)
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = event.locationInWindow
            isDragging = false
        }

        override func mouseUp(with event: NSEvent) {
            defer { mouseDownPoint = nil }
            guard mouseDownPoint != nil, !isDragging,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            onClick(event.timestamp)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownPoint, !isDragging,
                  hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4,
                  let item = makeItem() else { return }
            let row = ancestors.compactMap { $0 as? NSTableRowView }.first ?? self
            guard let bitmap = row.bitmapImageRepForCachingDisplay(in: row.bounds) else { return }
            row.cacheDisplay(in: row.bounds, to: bitmap)
            let image = NSImage(size: row.bounds.size)
            image.addRepresentation(bitmap)
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            draggingItem.setDraggingFrame(convert(row.bounds, from: row), contents: image)
            isDragging = true
            let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) {
            mouseDownPoint = nil
            isDragging = false
        }

        private var ancestors: UnfoldSequence<NSView, (NSView?, Bool)> {
            sequence(first: self as NSView, next: { $0.superview })
        }
    }
}

/// SwiftUI's outline drop validator traps on an external insertion at the end
/// of this list on macOS 27. Forward its data-source queries unchanged, and
/// handle only Toastty project drops with the public AppKit APIs.
final class ProjectSidebarDropCoordinator: NSObject, NSOutlineViewDataSource {
    private static var associationKey: UInt8 = 0
    private weak var original: (any NSOutlineViewDataSource)?
    private weak var model: TabSidebarModel?
    private var destination: Int?

    static func install(on table: NSOutlineView, model: TabSidebarModel) {
        let coordinator: ProjectSidebarDropCoordinator
        if let existing = objc_getAssociatedObject(table, &associationKey) as? ProjectSidebarDropCoordinator {
            coordinator = existing
        } else {
            coordinator = ProjectSidebarDropCoordinator()
            objc_setAssociatedObject(table, &associationKey, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        coordinator.model = model
        if table.dataSource !== coordinator {
            coordinator.original = table.dataSource
            table.dataSource = coordinator
        }
        table.registerForDraggedTypes([.init(ProjectSidebarDragPayload.typeIdentifier)])
        table.verticalMotionCanBeginDrag = true
        table.draggingDestinationFeedbackStyle = .gap
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? { original }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        destination = nil
        guard let model, let payload = payload(from: info), payload.groupID == model.dragID,
              model.editingProjectID == nil, model.editingProjectEmojiID == nil,
              model.projects.contains(where: { $0.id == payload.projectID }),
              outlineView.numberOfRows == model.projects.count else { return [] }
        let point = outlineView.convert(info.draggingLocation, from: nil)
        guard outlineView.visibleRect.contains(point) else { return [] }
        let row = outlineView.row(at: point)
        let insertion: Int
        if row < 0 {
            insertion = point.y < outlineView.rect(ofRow: 0).minY ? 0 : model.projects.count
        } else {
            insertion = row + (point.y > outlineView.rect(ofRow: row).midY ? 1 : 0)
        }
        guard let anchor = outlineView.item(atRow: min(insertion, model.projects.count - 1)) else { return [] }
        let parent = outlineView.parent(forItem: anchor)
        let childIndex = outlineView.childIndex(forItem: anchor) + (insertion == model.projects.count ? 1 : 0)
        outlineView.setDropItem(parent, dropChildIndex: childIndex)
        destination = insertion
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let model, let destination, let payload = payload(from: info),
              payload.groupID == model.dragID else { return false }
        self.destination = nil
        // Let AppKit close its insertion gap before SwiftUI rearranges rows.
        DispatchQueue.main.async { [weak model] in
            model?.acceptProjectDrop(payload, at: destination)
        }
        return true
    }

    private func payload(from info: any NSDraggingInfo) -> ProjectSidebarDragPayload? {
        guard let data = info.draggingPasteboard.data(forType: .init(ProjectSidebarDragPayload.typeIdentifier)) else { return nil }
        return try? JSONDecoder().decode(ProjectSidebarDragPayload.self, from: data)
    }
}
