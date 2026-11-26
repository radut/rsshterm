import Foundation
import RSSHKit
import Testing
@testable import RSSHTermLinux

@Suite struct ConnectIconsTests {
    @Test func everyServiceHasASymbolicSVG() {
        for service in ConnectService.allCases {
            let svg = ConnectIcons.svg(for: service)
            #expect(svg.hasPrefix("<svg ") && svg.contains("viewBox=\"0 0 16 16\"") && svg.hasSuffix("</svg>\n"))
            #expect(service.iconName.hasSuffix("-symbolic"))
        }
        #expect(Set(ConnectService.allCases.map { ConnectIcons.svg(for: $0) }).count == ConnectService.allCases.count)
    }

    @Test func installsIntoAnIconThemeFolderOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("icons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try ConnectIcons.install(into: root)
        let file = root.appendingPathComponent("hicolor/scalable/actions/rssh-connect-screenSharing-symbolic.svg")
        #expect(try String(contentsOf: file, encoding: .utf8) == ConnectIcons.svg(for: .screenSharing))
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        try ConnectIcons.install(into: root)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        #expect(before == after)
    }

    @Test func defaultRootFollowsXDGCache() {
        #expect(ConnectIcons.defaultRoot(environment: ["XDG_CACHE_HOME": "/tmp/c"]).path == "/tmp/c/rsshterm/icons")
    }
}
