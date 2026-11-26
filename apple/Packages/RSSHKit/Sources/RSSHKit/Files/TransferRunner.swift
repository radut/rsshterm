import Foundation

/// Runs one transfer: walks the source tree for the totals, then copies file by file in chunks through the phone
/// (never a whole file in memory), resuming half-written files on a retry where both ends take offsets. A move
/// deletes each source file only after its copy has the same size, and a folder only when all of it moved; within
/// one source that can rename, a move is a rename.
struct TransferRunner {
    let job: TransferJob
    let request: TransferRequest
    let chunkSize: Int
    let resolver: ConflictResolver?

    private var source: any FileSource { request.source }
    private var destination: any FileSource { request.destination }
    private var sameSource: Bool { source.id == destination.id }

    /// The source tree, read once: children per folder and bytes below each path.
    struct Plan {
        var children: [FilePath: [FileItem]] = [:]
        var bytes: [FilePath: Int64] = [:]
        var files = 0

        func fileCount(below item: FileItem) -> Int {
            guard item.isDirectory else { return 1 }
            return (children[item.path] ?? []).reduce(0) { $0 + fileCount(below: $1) }
        }
    }

    func run() async throws {
        var roots: [FileItem] = []
        for path in request.items {
            let item = try await listed(path)
            if sameSource, item.isDirectory, item.path.contains(request.destinationDirectory) {
                throw TransferError.intoItself(item.path)
            }
            roots.append(item)
        }
        var plan = Plan()
        for root in roots { _ = try await walk(root, into: &plan) }
        await job.setTotals(bytes: roots.reduce(0) { $0 + (plan.bytes[$1.path] ?? 0) }, files: plan.files)
        for root in roots {
            try Task.checkCancellation()
            _ = try await transfer(root, into: request.destinationDirectory, plan: plan, topLevel: true)
        }
    }

    /// The item as its folder lists it: a symlink stays a symlink (`stat` follows links on SFTP), so a moved link
    /// to a folder is never walked and emptied.
    private func listed(_ path: FilePath) async throws -> FileItem {
        if !path.isRoot, let item = try await source.list(path.parent).first(where: { $0.path == path }) { return item }
        return try await source.stat(path)
    }

    private func walk(_ item: FileItem, into plan: inout Plan) async throws -> Int64 {
        guard item.isDirectory else {
            plan.files += 1
            plan.bytes[item.path] = item.size ?? 0
            return item.size ?? 0
        }
        let children = try await source.list(item.path)
        plan.children[item.path] = children
        var total: Int64 = 0
        for child in children {
            try Task.checkCancellation()
            total += try await walk(child, into: &plan)
        }
        plan.bytes[item.path] = total
        return total
    }

    // MARK: one item

    /// Returns true when the item is completely at the target (so a move may delete the source).
    private func transfer(_ item: FileItem, into directory: FilePath, plan: Plan, topLevel: Bool) async throws -> Bool {
        let wanted = directory.appending(item.name)
        if await job.completed.contains(wanted) {
            await job.countDone(bytes: plan.bytes[item.path] ?? 0, files: plan.fileCount(below: item))
            return true
        }
        guard let target = try await resolveTarget(for: item, at: wanted) else {
            await countSkipped(item, plan: plan)
            return false
        }
        if topLevel, request.operation == .move, sameSource, source.capabilities.contains(.rename),
           try await destination.statIfExists(target) == nil {
            try await source.rename(item.path, to: target)
            await job.countDone(bytes: plan.bytes[item.path] ?? 0, files: plan.fileCount(below: item))
            return true
        }
        if item.isDirectory { return try await transferDirectory(item, to: target, plan: plan) }
        try await copyFile(item, to: target)
        if request.operation == .move { try await source.delete(item.path) }
        return true
    }

    private func transferDirectory(_ item: FileItem, to target: FilePath, plan: Plan) async throws -> Bool {
        if try await destination.statIfExists(target) == nil { try await destination.makeDirectory(target) }
        var all = true
        for child in plan.children[item.path] ?? [] {
            try Task.checkCancellation()
            let done = try await transfer(child, into: target, plan: plan, topLevel: false)
            all = all && done
        }
        if request.operation == .move, all { try await source.delete(item.path) }
        return all
    }

    private func countSkipped(_ item: FileItem, plan: Plan) async {
        await job.fileSkipped(bytes: plan.bytes[item.path] ?? 0, files: plan.fileCount(below: item))
    }

    // MARK: conflicts

    /// The target path to use, or nil to skip. Folders onto folders merge; a retry continues a partial file.
    private func resolveTarget(for item: FileItem, at target: FilePath) async throws -> FilePath? {
        guard let existing = try await destination.statIfExists(target) else { return target }
        if sameSource, existing.path == item.path {
            // Onto itself: a copy becomes "name (1)", a move has nothing to do.
            return request.operation == .copy ? try await freeTarget(target) : nil
        }
        if item.isDirectory, existing.isDirectory { return target }
        if await job.partial[target] != nil, !item.isDirectory { return target }
        var policy = await job.policy
        if policy == .ask {
            let answer = await resolver?(TransferConflict(source: item, existing: existing, destinationName: target.name))
                ?? ConflictAnswer(.skip)
            if answer.action == .cancel { throw TransferError.cancelledByUser }
            policy = ConflictPolicy(rawValue: answer.action.rawValue) ?? .skip
            if answer.applyToAll { await job.setPolicy(policy) }
        }
        switch policy {
        case .skip, .ask: return nil
        case .rename: return try await freeTarget(target)
        case .overwrite:
            guard existing.isDirectory == item.isDirectory else { throw FileSourceError.alreadyExists(target) }
            return target
        }
    }

    private func freeTarget(_ target: FilePath) async throws -> FilePath {
        let destination = self.destination
        let name = try await FileNaming.freeName(for: target.name) { candidate in
            try await destination.statIfExists(target.parent.appending(candidate)) != nil
        }
        return target.parent.appending(name)
    }

    // MARK: bytes

    private func copyFile(_ item: FileItem, to target: FilePath) async throws {
        await job.starting(item.name)
        let offset = try await resumeOffset(for: target)
        let reader = try await source.reader(for: item.path, from: offset)
        let writer: any FileWriter
        do { writer = try await destination.writer(for: target, appendingAt: offset) } catch {
            await reader.close()
            throw error
        }
        await job.advance(by: offset)
        var written = offset
        do {
            while true {
                try Task.checkCancellation()
                let chunk = try await reader.read(maxLength: chunkSize)
                if chunk.isEmpty { break }
                try await writer.write(chunk)
                written += Int64(chunk.count)
                await job.advance(by: Int64(chunk.count))
            }
            await reader.close()
            try await writer.finish()
        } catch {
            await reader.close()
            await writer.abort()
            if error is CancellationError || Task.isCancelled {
                try? await destination.delete(target)
                await job.clearPartial(target)
            } else {
                await job.recordPartial(target, bytes: written)
            }
            throw error
        }
        try await verify(item, at: target)
        await job.fileDone(target)
    }

    /// Bytes already at the target from an earlier failed attempt, when both ends can continue there.
    private func resumeOffset(for target: FilePath) async throws -> Int64 {
        guard let recorded = await job.partial[target], recorded > 0,
              source.capabilities.contains(.readAtOffset), destination.capabilities.contains(.writeAtOffset),
              let existing = try await destination.statIfExists(target), let size = existing.size
        else { return 0 }
        // Less on disk than recorded: continue from what is there. More: a write landed without being
        // acknowledged; the writer truncates back to the recorded offset.
        return min(size, recorded)
    }

    private func verify(_ item: FileItem, at target: FilePath) async throws {
        guard let expected = item.size else { return }
        let actual = try await destination.stat(target).size
        if let actual, actual != expected {
            await job.clearPartial(target)
            throw FileSourceError.sizeMismatch(expected: expected, actual: actual)
        }
    }
}
