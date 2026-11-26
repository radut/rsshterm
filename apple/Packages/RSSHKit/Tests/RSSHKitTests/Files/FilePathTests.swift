import Foundation
import Testing
@testable import RSSHKit

@Suite struct FilePathTests {
    @Test func normalises() {
        #expect(FilePath("a//b/./c/").string == "/a/b/c")
        #expect(FilePath("/a/b/../c").string == "/a/c")
        #expect(FilePath("").isRoot)
    }

    @Test func dotDotNeverClimbsAboveRoot() {
        #expect(FilePath("/../../etc/passwd").string == "/etc/passwd")
        #expect(FilePath("/docs").appending("../../x").string == "/x")
    }

    @Test func nameParentExtension() {
        let path = FilePath("/srv/www/index.html")
        #expect(path.name == "index.html")
        #expect(path.parent == FilePath("/srv/www"))
        #expect(path.pathExtension == "html")
        #expect(FilePath("/.profile").pathExtension == "")
        #expect(FilePath.root.parent == .root)
        #expect(FilePath.root.name == "/")
    }

    @Test func containsAndRebase() {
        let base = FilePath("/a")
        #expect(base.contains(FilePath("/a/b/c")))
        #expect(base.contains(base))
        #expect(!base.contains(FilePath("/ab")))
        #expect(FilePath("/a/b/c").rebased(from: base, onto: FilePath("/z")) == FilePath("/z/b/c"))
    }

    @Test func ancestryForBreadcrumbs() {
        #expect(FilePath("/a/b").ancestry == [.root, FilePath("/a"), FilePath("/a/b")])
    }

    @Test(arguments: [("a.txt", 1, "a (1).txt"), ("a (1).txt", 2, "a (2).txt"), ("folder", 3, "folder (3)"),
                      ("archive.tar.gz", 1, "archive.tar (1).gz")])
    func variants(name: String, number: Int, expected: String) {
        #expect(FileNaming.variant(of: name, number: number) == expected)
    }

    @Test func freeNameSkipsTakenOnes() async {
        let taken: Set = ["a (1).txt", "a (2).txt"]
        let name = await FileNaming.freeName(for: "a.txt") { taken.contains($0) }
        #expect(name == "a (3).txt")
    }
}
