import Foundation
import RSSHDesktopCore
import Testing
@testable import RSSHTermLinux

@Suite struct UpdatePresenterTests {
    let update = AvailableUpdate(version: SemanticVersion("1.2.0")!, notes: "Faster splits.",
                                 assetKey: "linux-amd64",
                                 asset: UpdateAsset(url: "https://example.com/a.tar.gz", sha256: String(repeating: "0", count: 64)))

    @Test func upToDateIsQuietUnlessAsked() {
        let latest = SemanticVersion("1.0.0")!
        #expect(UpdatePresenter.message(for: .upToDate(latest: latest), manual: false) == nil)
        #expect(UpdatePresenter.message(for: .notDue, manual: false) == nil)
        let m = UpdatePresenter.message(for: .upToDate(latest: latest), manual: true)
        #expect(m?.title == "rSshTerm is up to date")
        #expect(m?.action == nil)
    }

    @Test func availableShowsNotesAndOffersInstall() {
        let m = UpdatePresenter.message(for: .available(update), manual: false)
        #expect(m?.title == "rSshTerm 1.2.0 is available")
        #expect(m?.body.contains("Faster splits.") == true)
        #expect(m?.action == .install)
    }

    @Test func installedOutcomes() {
        #expect(UpdatePresenter.message(for: .installed(update, .relaunching(executable: "/x")), manual: false)?.action == .quit)
        let cmd = UpdatePresenter.message(for: .installed(update, .showCommand("sudo apt-get install -y rsshterm")), manual: true)
        #expect(cmd?.body.contains("sudo apt-get install -y rsshterm") == true)
        #expect(cmd?.action == .copy("sudo apt-get install -y rsshterm"))
        #expect(UpdatePresenter.message(for: .installed(update, .cancelled), manual: true)?.title == "Update cancelled")
        let manual = UpdatePresenter.message(for: .installed(update, .manual(reason: "dev build")), manual: true)
        #expect(manual?.body.contains("dev build") == true)
        #expect(manual?.action == .openDownloads)
    }

    @Test func errorsOnlyWhenAsked() {
        #expect(UpdatePresenter.message(for: UpdateError.badSignature, manual: false) == nil)
        #expect(UpdatePresenter.message(for: UpdateError.badSignature, manual: true)?.title == "Could not check for updates")
    }
}
