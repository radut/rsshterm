import RSSHKit
import Testing
@testable import RSSHTermLinux

@Suite struct LegalSectionsTests {
    @Test func everyLinuxComponentHasASection() {
        let titles = LegalSections.sections().map(\.title)
        #expect(titles.count == ThirdPartyNotices.components(for: .linux).count)
        #expect(titles.contains { $0.hasPrefix("SwiftNIO SSH") })
        #expect(titles.contains { $0.hasPrefix("stb_image") })
        #expect(!titles.contains { $0.hasPrefix("SwiftTerm") }, "SwiftTerm is not in the Linux app")
        #expect(!titles.contains { $0.hasPrefix("JetBrains Mono") }, "the Linux app bundles no fonts")
    }

    @Test func textsAreEscapedForPangoMarkup() {
        #expect(LegalSections.escape(#"a <b> & "c" 'd'"#) == "a &lt;b&gt; &amp; &quot;c&quot; &#39;d&#39;")
        for section in LegalSections.sections() {
            #expect(!section.license.contains("<"), "\(section.title)")
            #expect(!section.copyright.contains("<"), "\(section.title)")
            #expect(!section.license.isEmpty || section.copyright.contains("Licence:"), "\(section.title)")
        }
    }

    @Test func cryptoSwiftAcknowledgementIsShown() {
        let crypto = LegalSections.sections().first { $0.title.hasPrefix("CryptoSwift") }
        #expect(crypto?.copyright.contains("Marcin Krzyzanowski") == true)
    }

    @Test func appImageMentionsBundledLibrariesAndSourceOffer() {
        #expect(LegalSections.appLicense(isAppImage: true).contains("bundled-libraries"))
        #expect(!LegalSections.appLicense(isAppImage: false).contains("bundled-libraries"))
        #expect(LegalSections.appLicense(isAppImage: false).contains("THIRD_PARTY_NOTICES"))
    }
}
