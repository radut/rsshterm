import Testing
@testable import RSSHKit

@Suite struct TitleTextTests {
    @Test func middleEllipsis() {
        #expect(TitleText.middleEllipsis("abcdefghij", max: 20) == "abcdefghij")
        #expect(TitleText.middleEllipsis("abcdefghij", max: 5) == "ab…ij")
        #expect(TitleText.middleEllipsis("abcdefghij", max: 6) == "abc…ij")
        #expect(TitleText.middleEllipsis("abcdefghij", max: 1) == "…")
        #expect(TitleText.middleEllipsis("abc", max: 0) == "")
    }

    @Test func homeBecomesTilde() {
        #expect(TitleText.abbreviateHome("/home/u/src", home: "/home/u") == "~/src")
        #expect(TitleText.abbreviateHome("/home/u", home: "/home/u") == "~")
        #expect(TitleText.abbreviateHome("/home/user2", home: "/home/u") == "/home/user2")
        #expect(TitleText.abbreviateHome("/etc", home: nil) == "/etc")
    }

    @Test func shortPathKeepsTheLastTwoParts() {
        #expect(TitleText.shortPath("/root/projects", home: "/root") == "~/projects")
        #expect(TitleText.shortPath("/var/log", home: nil) == "/var/log")
        #expect(TitleText.shortPath("/etc/nginx/sites-enabled", home: nil) == "…/nginx/sites-enabled")
        #expect(TitleText.shortPath("/home/u/a/b/c", home: "/home/u") == "…/b/c")
        #expect(TitleText.shortPath("/", home: nil) == "/")
        #expect(TitleText.shortPath("/home/u", home: "/home/u") == "~")
        #expect(TitleText.shortPath("/home/u/", home: "/home/u") == "~")
    }

    @Test func clean() {
        #expect(TitleText.clean("  a  ·  ") == "a")
        #expect(TitleText.clean(" — b - ") == "b")
        #expect(TitleText.clean("x\ty\nz") == "x y z")
        #expect(TitleText.clean("a\u{1B}[31mb") == "a[31mb")
    }

    @Test func endEllipsis() {
        #expect(TitleText.endEllipsis("abcdef", max: 4) == "abc…")
        #expect(TitleText.endEllipsis("abc", max: 4) == "abc")
    }
}
