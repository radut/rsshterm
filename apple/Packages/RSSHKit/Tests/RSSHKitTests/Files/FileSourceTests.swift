import Foundation
import Testing
@testable import RSSHKit

/// The same contract checks against the in-memory fake and the device folder source.
@Suite struct FileSourceTests {
    static func makeLocal() -> (LocalFileSource, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rssh-files-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (LocalFileSource(rootURL: dir, displayName: "Test"), dir)
    }

    static func exercise(_ source: any FileSource) async throws {
        try await source.makeDirectory(FilePath("/docs"))
        await #expect(throws: FileSourceError.alreadyExists(FilePath("/docs"))) {
            try await source.makeDirectory(FilePath("/docs"))
        }
        try await source.writeAll(Data("hello".utf8), to: FilePath("/docs/a.txt"))
        let item = try await source.stat(FilePath("/docs/a.txt"))
        #expect(item.kind == .file && item.size == 5)

        // Append at an offset (resume).
        let writer = try await source.writer(for: FilePath("/docs/a.txt"), appendingAt: 3)
        try await writer.write(Data("p!".utf8))
        try await writer.finish()
        #expect(try await source.readAll(FilePath("/docs/a.txt")) == Data("help!".utf8))

        // Read from an offset.
        let reader = try await source.reader(for: FilePath("/docs/a.txt"), from: 2)
        #expect(try await reader.read(maxLength: 2) == Data("lp".utf8))
        #expect(try await reader.read(maxLength: 10) == Data("!".utf8))
        #expect(try await reader.read(maxLength: 10).isEmpty)
        await reader.close()

        let listing = try await source.list(FilePath("/"))
        #expect(listing.map(\.name) == ["docs"] && listing[0].isDirectory)

        await #expect(throws: FileSourceError.directoryNotEmpty(FilePath("/docs"))) {
            try await source.delete(FilePath("/docs"))
        }
        try await source.rename(FilePath("/docs/a.txt"), to: FilePath("/docs/b.txt"))
        #expect(try await source.statIfExists(FilePath("/docs/a.txt")) == nil)
        try await source.rename(FilePath("/docs"), to: FilePath("/papers"))
        #expect(try await source.readAll(FilePath("/papers/b.txt")) == Data("help!".utf8))
        try await source.deleteRecursively(try await source.stat(FilePath("/papers")))
        #expect(try await source.list(.root).isEmpty)
        await #expect(throws: FileSourceError.notFound(FilePath("/nope"))) { try await source.stat(FilePath("/nope")) }
    }

    @Test func memorySourceContract() async throws {
        try await Self.exercise(MemoryFileSource())
    }

    @Test func localSourceContract() async throws {
        let (source, dir) = Self.makeLocal()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await Self.exercise(source)
    }

    @Test func localSourceStaysInsideItsRoot() async throws {
        let (source, dir) = Self.makeLocal()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(source.url(for: FilePath("/../../etc/passwd")).path == dir.standardizedFileURL.appendingPathComponent("etc/passwd").path)
    }

    @Test func recursiveDeleteRemovesALinkButNotItsTarget() async throws {
        let (source, dir) = Self.makeLocal()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await source.makeDirectory(FilePath("/keep"))
        try await source.writeAll(Data("x".utf8), to: FilePath("/keep/precious.txt"))
        try await source.makeDirectory(FilePath("/trash"))
        try FileManager.default.createSymbolicLink(at: source.url(for: FilePath("/trash/link")),
                                                   withDestinationURL: source.url(for: FilePath("/keep")))
        let trash = try await source.list(.root).first { $0.name == "trash" }!
        #expect(try await source.list(FilePath("/trash")).first?.kind == .symlink)
        try await source.deleteRecursively(trash)
        #expect(try await source.statIfExists(FilePath("/trash")) == nil)
        #expect(try await source.readAll(FilePath("/keep/precious.txt")) == Data("x".utf8))
    }

    @Test func readAllRefusesLargeFiles() async throws {
        let source = MemoryFileSource()
        await source.seed(FilePath("/big"), Data(count: 100))
        await #expect(throws: FileSourceError.self) { try await source.readAll(FilePath("/big"), limit: 10) }
    }

    @Test func objectStoreLikeSourceRefusesOffsets() async throws {
        let source = MemoryFileSource(capabilities: [.writable])
        await source.seed(FilePath("/a"), Data("abc".utf8))
        await #expect(throws: FileSourceError.unsupported("resume a read")) {
            try await source.reader(for: FilePath("/a"), from: 1)
        }
        await #expect(throws: FileSourceError.unsupported("rename")) {
            try await source.rename(FilePath("/a"), to: FilePath("/b"))
        }
    }
}
