import Foundation
import Testing
@testable import RSSHKit

@Suite struct ThirdPartyNoticesTests {
    @Test("every component but a colour theme carries at least one licence text")
    func everyComponentHasText() {
        for component in ThirdPartyNotices.all where component.kind != .theme {
            let texts = ThirdPartyNotices.texts(of: component)
            #expect(!texts.isEmpty, "\(component.id) has no licence text")
            #expect(texts.allSatisfy { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }
    }

    @Test("every text key resolves")
    func keysResolve() {
        for component in ThirdPartyNotices.all {
            #expect(ThirdPartyNotices.texts(of: component).count == component.texts.count, "\(component.id)")
        }
    }

    @Test("CryptoSwift's required acknowledgement is shown on every platform")
    func cryptoSwiftAcknowledgement() {
        for platform in ThirdPartyPlatform.allCases {
            #expect(ThirdPartyNotices.requiredAcknowledgements(for: platform)
                .contains { $0.contains("Marcin Krzyzanowski") }, "\(platform)")
        }
    }

    @Test("platform lists: SwiftTerm and fonts on Apple only, stb_image on Linux only")
    func platformFiltering() {
        let ios = Set(ThirdPartyNotices.components(for: .ios).map(\.id))
        let mac = Set(ThirdPartyNotices.components(for: .macos).map(\.id))
        let linux = Set(ThirdPartyNotices.components(for: .linux).map(\.id))
        #expect(ios.contains("swiftpm:swiftterm") && mac.contains("swiftpm:swiftterm") && !linux.contains("swiftpm:swiftterm"))
        #expect(linux.contains("swiftpm:cstb") && !ios.contains("swiftpm:cstb"))
        #expect(ios.contains("swiftpm:googlesignin-ios") && !mac.contains("swiftpm:googlesignin-ios"))
        #expect(!ThirdPartyNotices.components(.font, for: .ios).isEmpty)
        #expect(ThirdPartyNotices.components(.font, for: .linux).isEmpty)
        for platform in ThirdPartyPlatform.allCases {
            #expect(ThirdPartyNotices.components(for: platform).contains { $0.id == "swiftpm:swift-nio" })
        }
    }

    @Test("patched vendored copies say they were changed (Apache-2.0 §4(b))")
    func modifiedCopiesMarked() {
        let nioSSH = ThirdPartyNotices.all.first { $0.id == "vendored:swift-nio-ssh" }
        #expect(nioSSH?.changes.contains("PATCHES.md") == true)
        #expect(ThirdPartyNotices.fullNotice(of: nioSSH!).contains("Apache License"))
    }

    @Test("Apache NOTICE files are included")
    func noticeFiles() {
        let nio = ThirdPartyNotices.all.first { $0.id == "swiftpm:swift-nio" }!
        #expect(ThirdPartyNotices.texts(of: nio).contains { $0.title.hasPrefix("NOTICE") })
    }

    @Test("every bundled font of the catalog is credited")
    func fontsCovered() {
        let credited = ThirdPartyNotices.components(.font, for: .ios).map { $0.name.lowercased() }
        for family in TerminalFontCatalog.families.filter(\.isBundled) {
            let name = family.name.lowercased()
            #expect(credited.contains { $0.hasPrefix(name) || name.hasPrefix($0) }, "\(family.name) not credited")
        }
    }
}
