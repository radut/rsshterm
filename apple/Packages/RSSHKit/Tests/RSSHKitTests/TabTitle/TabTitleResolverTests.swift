import Testing
import Foundation
@testable import RSSHKit

@Suite struct TabTitleResolverTests {
    let settings = TabTitleSettings()

    @Test func vaultSSHTabBeforeAnythingIsReported() {
        let sources = TabTitleSources(vault: VaultHostFacts(name: "Web 1", host: "sv1", user: "root", port: 22))
        let facts = sources.facts()
        #expect(facts.server == "Web 1")
        #expect(facts.user == "root")
        #expect(facts.host == "sv1")
        let label = settings.label(for: facts)
        #expect(label.title == "Web 1")
        #expect(label.subtitle == "root@sv1")
    }

    @Test func localTabRunningSSHShowsTheTarget() {
        let local = LocalProcessFacts(foreground: ["ssh", "-p", "2222", "root@web1.example.com"], cwd: "/home/me",
                                      user: "me", host: "laptop", home: "/home/me")
        let facts = TabTitleSources(local: local).facts()
        #expect(facts.user == "root")
        #expect(facts.host == "web1.example.com")
        #expect(facts.process == nil)
        #expect(facts.cwd == nil)
        #expect(settings.label(for: facts) == TabTitleLabel(title: "root@web1.example.com",
                                                            subtitle: "root@web1.example.com"))
    }

    @Test func localTabSSHAliasResolvesThroughTheVault() {
        let local = LocalProcessFacts(foreground: ["ssh", "sv1"], cwd: "/home/me", user: "me", host: "laptop")
        let context = SSHResolveContext(config: SSHConfigHosts(text: ""),
                                        vault: ["sv1": VaultHostFacts(name: "Prod", host: "10.0.0.5", user: "admin")])
        let facts = TabTitleSources(local: local, sshContext: context).facts()
        #expect(facts.server == "Prod")
        #expect(facts.alias == "sv1")
        #expect(facts.user == "admin")
    }

    @Test func localTabRunningAProgram() {
        let local = LocalProcessFacts(foreground: ["vim", "notes.md"], cwd: "/home/me/src", user: "me",
                                      host: "laptop", home: "/home/me")
        let label = settings.label(for: TabTitleSources(local: local).facts())
        #expect(label.title == "me@laptop")
        #expect(label.subtitle == "me@laptop · vim notes.md")
    }

    @Test func localTabIdleShowsTheFolder() {
        let local = LocalProcessFacts(foreground: nil, cwd: "/home/me/projects", user: "me", host: "laptop",
                                      home: "/home/me")
        #expect(settings.label(for: TabTitleSources(local: local).facts()).subtitle == "me@laptop · ~/projects")
    }

    @Test func promptTitleGivesTheRemoteFolder() {
        var sources = TabTitleSources(vault: VaultHostFacts(name: "Web 1", host: "sv1", user: "root"))
        sources.terminalTitle = "root@sv1: /var/log"
        let facts = sources.facts()
        #expect(facts.cwd == "/var/log")
        #expect(facts.process == nil)
        #expect(settings.label(for: facts).subtitle == "root@sv1 · /var/log")
    }

    @Test func shellIntegrationCommandTitle() {
        var sources = TabTitleSources(vault: VaultHostFacts(name: "Web 1", host: "sv1", user: "root"))
        sources.terminalTitle = "root@sv1 › vim /etc/nginx/nginx.conf"
        sources.directory = DirectoryReport(host: "sv1", path: "/etc/nginx")
        let facts = sources.facts()
        #expect(facts.process == "vim")
        #expect(facts.args == ["/etc/nginx/nginx.conf"])
        #expect(facts.cwd == "/etc/nginx")
        #expect(settings.label(for: facts).subtitle == "root@sv1 · vim /etc/nginx/nginx.conf")
    }

    @Test func daemonPaneWins() {
        var sources = TabTitleSources(vault: VaultHostFacts(name: "Web 1", host: "sv1", user: "root"))
        sources.terminalTitle = "root@sv1: ~"
        sources.daemon = PaneReport(command: "htop", args: ["-d", "5"], cwd: "/root")
        let facts = sources.facts()
        #expect(facts.process == "htop")
        #expect(facts.cwd == "/root")
        sources.daemon = PaneReport(command: "", args: [], cwd: "/var/log")
        #expect(sources.facts().process == nil)
        #expect(sources.facts().cwd == "/var/log")
    }

    @Test func nestedSSHPromptOverridesTheVaultTarget() {
        var sources = TabTitleSources(vault: VaultHostFacts(name: "Bastion", host: "bastion", user: "ops"))
        sources.terminalTitle = "app@inner: ~"
        let facts = sources.facts()
        #expect(facts.user == "app")
        #expect(facts.host == "inner")
        #expect(facts.server == "Bastion")
    }

    @Test func customNameIsLineOneAndStaysAsPrefixInSingleLine() {
        var sources = TabTitleSources(vault: VaultHostFacts(name: "Web 1", host: "sv1", user: "root"))
        sources.custom = "deploy"
        sources.daemon = PaneReport(command: "vim", args: ["x"], cwd: "/root")
        let label = settings.label(for: sources.facts())
        #expect(label.title == "deploy")
        #expect(label.subtitle == "root@sv1 · vim x")
        #expect(label.singleLine == "deploy — root@sv1 · vim x")
        sources.custom = "  "
        #expect(settings.label(for: sources.facts()).title == "Web 1")
    }

    @Test func singleLineDropsARepeatedTitle() {
        let label = TabTitleLabel(title: "root@sv1", subtitle: "root@sv1 · vim x")
        #expect(label.singleLine == "root@sv1 · vim x")
        #expect(TabTitleLabel(title: "a", subtitle: "").singleLine == "a")
        #expect(TabTitleLabel(title: "", subtitle: "b").singleLine == "b")
    }

    @Test func emptyEverythingStillHasATitle() {
        let label = settings.label(for: TabTitleFacts())
        #expect(label.title == TabTitleSettings.fallbackTitle)
    }

    @Test func homeIsGuessedForRemoteUsers() {
        var sources = TabTitleSources(vault: VaultHostFacts(name: "W", host: "sv1", user: "deploy"))
        sources.terminalTitle = "deploy@sv1: /home/deploy/app/current"
        #expect(sources.facts().home == "/home/deploy")
        #expect(settings.label(for: sources.facts()).subtitle == "deploy@sv1 · ~/app/current")
    }
}

@Suite struct TabTitleSettingsTests {
    @Test func defaultsAndCodable() throws {
        let s = TabTitleSettings()
        #expect(s.title == TabTitleSettings.defaultTitle)
        #expect(s.subtitle == TabTitleSettings.defaultSubtitle)
        #expect(!s.singleLine)
        #expect(throws: Never.self) { try TabTitleTemplate(s.title) }
        #expect(throws: Never.self) { try TabTitleTemplate(s.subtitle) }
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(TabTitleSettings.self, from: data) == s)
        // an older or partial file decodes with defaults
        let partial = try JSONDecoder().decode(TabTitleSettings.self, from: Data(#"{"singleLine":true}"#.utf8))
        #expect(partial.singleLine)
        #expect(partial.title == TabTitleSettings.defaultTitle)
    }

    @Test func brokenTemplateFallsBackToTheDefault() {
        var s = TabTitleSettings()
        s.subtitle = "{user"
        let facts = TabTitleFacts(user: "u", host: "h")
        #expect(s.label(for: facts).subtitle == "u@h")
        #expect(s.problems.subtitle != nil)
        #expect(s.problems.title == nil)
    }

    @Test func windowTitleJoinsBoth() {
        let s = TabTitleSettings()
        let facts = TabTitleFacts(user: "u", host: "h", server: "Web", process: "top")
        #expect(s.label(for: facts).windowTitle == "Web — u@h · top")
    }

    @Test func presetsAreValidAndDistinct() {
        for preset in TabTitleCatalog.titlePresets + TabTitleCatalog.subtitlePresets {
            #expect(throws: Never.self) { try TabTitleTemplate(preset.template) }
        }
        #expect(Set(TabTitleCatalog.subtitlePresets.map(\.template)).count == TabTitleCatalog.subtitlePresets.count)
        #expect(TabTitleCatalog.subtitlePresets.contains { $0.template == "{host}" })
        #expect(TabTitleCatalog.subtitlePresets.contains { $0.template == TabTitleSettings.defaultSubtitle })
    }

    @Test func placeholderReferenceCoversEveryPlaceholder() {
        let documented = Set(TabTitleCatalog.placeholders.map(\.name))
        #expect(documented == Set(TabTitlePlaceholder.allCases.map(\.rawValue)))
        for entry in TabTitleCatalog.placeholders {
            #expect(!entry.summary.isEmpty)
            #expect(entry.token == "{\(entry.name)}")
        }
    }

    @Test func previewSamplesRender() {
        let samples = TabTitleCatalog.samples
        #expect(samples.count >= 4)
        let rendered = samples.map { TabTitleSettings().label(for: $0.facts) }
        #expect(rendered.contains { $0.subtitle == "root@web1.example.com · vim /etc/nginx/nginx.conf" })
        #expect(rendered.contains { $0.title == "deploy" })
        #expect(rendered.contains { $0.subtitle.hasSuffix("/var/log") })
    }

    @Test func insertingAPlaceholderAtTheCursor() {
        let (text, cursor) = TabTitleCatalog.insert("{host}", into: "{user}@", at: 7)
        #expect(text == "{user}@{host}")
        #expect(cursor == 13)
        let (clamped, _) = TabTitleCatalog.insert("{cwd}", into: "ab", at: 99)
        #expect(clamped == "ab{cwd}")
    }

    @Test func helpExplainsSources() {
        #expect(TabTitleCatalog.sourcesHelp.count >= 4)
        #expect(TabTitleCatalog.sourcesHelp.contains { $0.title.contains("rSshD") })
    }
}
