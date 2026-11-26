import Foundation

/// Copy keeps the source; move deletes it after the copy is verified (same size), or renames within one source.
public enum TransferOperation: String, Sendable, Hashable {
    case copy, move
}

/// What to do when the target name is taken.
public enum ConflictPolicy: String, Sendable, Hashable, CaseIterable {
    case ask, overwrite, skip, rename
}

/// One collision, put to the user when the policy is `.ask`.
public struct TransferConflict: Sendable, Hashable {
    public let source: FileItem
    /// What is already at the target.
    public let existing: FileItem
    public let destinationName: String
}

/// The user's answer to a conflict; `applyToAll` keeps it for the rest of the transfer.
public struct ConflictAnswer: Sendable, Hashable {
    public enum Action: String, Sendable, Hashable { case overwrite, skip, rename, cancel }
    public let action: Action
    public let applyToAll: Bool

    public init(_ action: Action, applyToAll: Bool = false) {
        self.action = action
        self.applyToAll = applyToAll
    }
}

public typealias ConflictResolver = @Sendable (TransferConflict) async -> ConflictAnswer

/// Copy or move `items` of `source` into the folder `destinationDirectory` of `destination`.
public struct TransferRequest: Sendable {
    public let source: any FileSource
    public let items: [FilePath]
    public let destination: any FileSource
    public let destinationDirectory: FilePath
    public let operation: TransferOperation
    public let policy: ConflictPolicy

    public init(source: any FileSource, items: [FilePath], destination: any FileSource, destinationDirectory: FilePath,
                operation: TransferOperation, policy: ConflictPolicy = .ask) {
        self.source = source
        self.items = items
        self.destination = destination
        self.destinationDirectory = destinationDirectory
        self.operation = operation
        self.policy = policy
    }

    var title: String {
        let what = items.count == 1 ? (items.first?.name ?? "") : "\(items.count) items"
        let verb = operation == .copy ? "Copy" : "Move"
        return "\(verb) \(what) to \(destination.displayName)"
    }
}

/// What the transfers screen shows for one transfer.
public struct TransferSnapshot: Sendable, Identifiable, Hashable {
    public enum State: Sendable, Hashable {
        case queued, running, completed, cancelled
        case failed(String)

        public var isFinished: Bool {
            switch self {
            case .queued, .running: false
            case .completed, .cancelled, .failed: true
            }
        }
    }

    public let id: UUID
    public let title: String
    public let operation: TransferOperation
    public var state: State = .queued
    public var bytesDone: Int64 = 0
    /// Known after the source tree was walked.
    public var bytesTotal: Int64?
    public var filesDone = 0
    public var filesTotal = 0
    public var skipped = 0
    /// The file being copied now.
    public var currentName: String?

    public init(id: UUID, title: String, operation: TransferOperation) {
        self.id = id
        self.title = title
        self.operation = operation
    }

    /// 0...1 once the total is known.
    public var fraction: Double? {
        guard let bytesTotal else { return nil }
        guard bytesTotal > 0 else { return state == .completed ? 1 : 0 }
        return min(1, Double(bytesDone) / Double(bytesTotal))
    }
}

public enum TransferError: Error, Equatable, LocalizedError {
    /// A folder cannot go inside itself.
    case intoItself(FilePath)
    case cancelledByUser

    public var errorDescription: String? {
        switch self {
        case .intoItself(let path): "\(path.name) cannot be copied or moved into itself."
        case .cancelledByUser: "Cancelled."
        }
    }
}
