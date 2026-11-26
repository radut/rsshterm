import Testing
@testable import RSSHKit

@Suite struct SSHBannerTests {
    @Test func splitsVersionSoftwareAndComment() throws {
        let banner = try #require(SSHBanner(line: "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13\r\n"))
        #expect(banner.protocolVersion == "2.0")
        #expect(banner.software == "OpenSSH_9.6p1")
        #expect(banner.comment == "Ubuntu-3ubuntu13")
        #expect(banner.softwareName == "OpenSSH 9.6p1")
        #expect(banner.osHint == "Ubuntu")
        #expect(banner.summary == "OpenSSH 9.6p1 · Ubuntu")
    }

    @Test func hintsFromSoftwareOrComment() {
        #expect(SSHBanner(line: "SSH-2.0-OpenSSH_9.2p1 Debian-2+deb12u3")?.osHint == "Debian")
        #expect(SSHBanner(line: "SSH-2.0-OpenSSH_for_Windows_9.5")?.osHint == "Windows")
        #expect(SSHBanner(line: "SSH-2.0-dropbear_2022.83")?.summary == "dropbear 2022.83 · embedded (Dropbear)")
        #expect(SSHBanner(line: "SSH-2.0-ROSSSH")?.osHint == "MikroTik")
        #expect(SSHBanner(line: "SSH-2.0-OpenSSH_9.8 FreeBSD-20240806")?.osHint == "FreeBSD")
        #expect(SSHBanner(line: "SSH-1.99-Cisco-1.25")?.osHint == "Cisco")
        let plain = SSHBanner(line: "SSH-2.0-OpenSSH_9.7")
        #expect(plain?.osHint == nil)
        #expect(plain?.comment == "")
        #expect(plain?.summary == "OpenSSH 9.7")
    }

    @Test func refusesNonSSHLines() {
        for line in ["", "HTTP/1.1 400 Bad Request", "SSH-", "SSH-2.0", "SSH--OpenSSH", "SSH-2.0-", "ssh-2.0-x"] {
            #expect(SSHBanner(line: line) == nil, "\(line)")
        }
    }
}
