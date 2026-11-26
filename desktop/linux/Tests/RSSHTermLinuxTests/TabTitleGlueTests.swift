import Foundation
import RSSHKit
import Testing
@testable import RSSHTermLinux

@Suite struct TabTitleGlueTests {
    @Test func settingsKeepTheTemplates() throws {
        var s = AppSettings()
        #expect(s.tabTitles == TabTitleSettings())
        s.tabTitles = TabTitleSettings(title: "{server|host}", subtitle: "{cwdShort}", singleLine: true)
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).tabTitles == s.tabTitles)
        // an older file without the key keeps the defaults
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontName":"Hack 10"}"#.utf8)).tabTitles == TabTitleSettings())
    }

    @Test func markupIsBoldTitleSmallSubtitleEscaped() {
        let m = TabLabelMarkup.markup(TabTitleLabel(title: "Web <Prod> & 1", subtitle: "deploy@web1 · vim a&b"), singleLine: false)
        #expect(m == "<b>Web &lt;Prod&gt; &amp; 1</b>\n<small>deploy@web1 · vim a&amp;b</small>")
        #expect(TabLabelMarkup.markup(TabTitleLabel(title: "t", subtitle: ""), singleLine: false) == "<b>t</b>")
        #expect(TabLabelMarkup.markup(TabTitleLabel(title: "t", subtitle: "s"), singleLine: true) == "t — s")
    }
}
