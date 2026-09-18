import AppKit
import Combine
import CoreTransferable
import UniformTypeIdentifiers

/// The only data that crosses an AppKit drag session. Objects are resolved
/// again when a proposal is committed, so a stale drag cannot move a surface
/// that has already been closed or moved.
enum TerminalLayoutDragPayload: Codable, Equatable, Transferable {
    case surface(UUID)
    case tab(UUID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
    }

    private enum Kind: String, Codable {
        case surface
        case tab
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let id = try container.decode(UUID.self, forKey: .id)
        switch kind {
        case .surface: self = .surface(id)
        case .tab: self = .tab(id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .surface(let id):
            try container.encode(Kind.surface, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .tab(let id):
            try container.encode(Kind.tab, forKey: .kind)
            try container.encode(id, forKey: .id)
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .toasttyTerminalLayoutID) { payload in
            try JSONEncoder().encode(payload)
        } importing: { data in
            try JSONDecoder().decode(Self.self, from: data)
        }
    }
}

extension UTType {
    /// A Toastty-internal drag payload containing a surface or tab UUID.
    static let toasttyTerminalLayoutID = UTType(exportedAs: "com.dar7an.toastty.terminal-layout-id")
}

extension NSPasteboard.PasteboardType {
    static let toasttyTerminalLayoutID = NSPasteboard.PasteboardType(UTType.toasttyTerminalLayoutID.identifier)
}

extension TerminalLayoutDragPayload {
    /// A stable label used in accessibility feedback and drag previews.
    var accessibilityLabel: String {
        switch self {
        case .surface: "Terminal pane"
        case .tab: "Terminal tab"
        }
    }

    /// Bridges the Codable payload to the AppKit provider used by SwiftUI's
    /// `.onDrag` and `.onDrop` APIs.
    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.toasttyTerminalLayoutID.identifier,
            visibility: .ownProcess) { completion in
                completion(data, nil)
                return nil
            }
        return provider
    }

    /// Loads either the current layout payload or the legacy surface payload
    /// from one native drag. The fallback keeps pane drags started by the
    /// existing AppKit grab handle compatible while tab drags use the stable
    /// layout identifier above.
    @discardableResult
    static func load(
        from providers: [NSItemProvider],
        completion: @escaping (TerminalLayoutDragPayload) -> Void
    ) -> Bool {
        if let provider = providers.first(where: {
            $0.registeredTypeIdentifiers.contains(UTType.toasttyTerminalLayoutID.identifier)
        }) {
            _ = provider.loadTransferable(type: TerminalLayoutDragPayload.self) { result in
                guard case .success(let payload) = result else { return }
                completion(payload)
            }
            return true
        }

        guard let provider = providers.first else { return false }
        _ = provider.loadTransferable(type: Ghostty.SurfaceView.self) { result in
            guard case .success(let surface) = result else { return }
            completion(.surface(surface.id))
        }
        return true
    }
}

/// A view-free representation of a layout. It is used by the drop preview so
/// preview updates never mutate or duplicate live terminal views.
indirect enum TerminalLayoutShape: Equatable {
    case leaf(UUID)
    case split(
        direction: SplitTree<Ghostty.SurfaceView>.Direction,
        ratio: Double,
        left: TerminalLayoutShape,
        right: TerminalLayoutShape
    )

    init(node: SplitTree<Ghostty.SurfaceView>.Node) {
        switch node {
        case .leaf(let view):
            self = .leaf(view.id)
        case .split(let split):
            self = .split(
                direction: split.direction,
                ratio: split.ratio,
                left: .init(node: split.left),
                right: .init(node: split.right))
        }
    }

    var leafIDs: [UUID] {
        switch self {
        case .leaf(let id): [id]
        case .split(_, _, let left, let right): left.leafIDs + right.leafIDs
        }
    }

    var leafCount: Int { leafIDs.count }
}

enum TerminalLayoutDropIntent: Equatable {
    case split(TerminalSplitDropZone)
    case reorder(before: Bool)
    case newTab
}

/// A target is either a specific pane or the root of a tab. A nil
/// `destinationSurfaceID` means that the drop targets the whole tab.
struct TerminalLayoutDropTarget: Equatable {
    let destinationTabID: UUID
    let destinationSurfaceID: UUID?
    let intent: TerminalLayoutDropIntent
    let insertionIndex: Int?

    init(
        destinationTabID: UUID,
        destinationSurfaceID: UUID? = nil,
        intent: TerminalLayoutDropIntent,
        insertionIndex: Int? = nil
    ) {
        self.destinationTabID = destinationTabID
        self.destinationSurfaceID = destinationSurfaceID
        self.intent = intent
        self.insertionIndex = insertionIndex
    }
}

enum TerminalLayoutDropRejection: Equatable {
    case missingSource
    case missingDestination
    case sameTab
    case sourceContainsDestination
    case unsupportedProject
    case cannotFit
    case invalidTarget
}

/// The result of the same calculation used for both the live preview and the
/// final drop. It intentionally stores IDs and shapes, not live AppKit views.
struct TerminalLayoutDropProposal {
    let payload: TerminalLayoutDragPayload
    let target: TerminalLayoutDropTarget
    let sourceShape: TerminalLayoutShape?
    let destinationShape: TerminalLayoutShape?
    let resultShape: TerminalLayoutShape?
    let isValid: Bool
    let rejection: TerminalLayoutDropRejection?

    static func invalid(
        payload: TerminalLayoutDragPayload,
        target: TerminalLayoutDropTarget,
        sourceShape: TerminalLayoutShape? = nil,
        destinationShape: TerminalLayoutShape? = nil,
        rejection: TerminalLayoutDropRejection
    ) -> Self {
        .init(
            payload: payload,
            target: target,
            sourceShape: sourceShape,
            destinationShape: destinationShape,
            resultShape: nil,
            isValid: false,
            rejection: rejection)
    }
}

extension TerminalSplitDropZone {
    var newDirection: SplitTree<Ghostty.SurfaceView>.NewDirection {
        switch self {
        case .top: .up
        case .bottom: .down
        case .left: .left
        case .right: .right
        }
    }
}

/// Resolves the payload once per destination entry, without blocking the UI.
/// The generation prevents an asynchronous result from reviving an exited drag.
final class TerminalLayoutDragSession: ObservableObject {
    @Published private(set) var payload: TerminalLayoutDragPayload?
    private var generation = UUID()

    func begin(_ providers: [NSItemProvider]) {
        end()
        let current = generation
        TerminalLayoutDragPayload.load(from: providers) { [weak self] payload in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.payload = payload
            }
        }
    }

    /// Commits a drop that landed before `begin`'s asynchronous publish.
    /// `.onDrop` can call `performDrop` before the provider load above
    /// finishes, so the delegate loads the providers directly, commits on
    /// the main queue, and ends the session. Returns false when no provider
    /// carries a layout payload.
    @discardableResult
    func finishDrop(
        _ providers: [NSItemProvider],
        commit: @escaping (TerminalLayoutDragPayload) -> Void
    ) -> Bool {
        TerminalLayoutDragPayload.load(from: providers) { [weak self] payload in
            DispatchQueue.main.async {
                commit(payload)
                self?.end()
            }
        }
    }

    func end() {
        generation = UUID()
        payload = nil
    }
}
