import Testing
@testable import RSSHKit

@Suite struct TabTitleTemplateTests {
    let vim = TabTitleFacts(user: "root", host: "sv1", server: "Web 1", process: "vim",
                            args: ["/etc/nginx/nginx.conf"], cwd: "/etc/nginx", home: "/root")
    let idle = TabTitleFacts(user: "root", host: "sv1", cwd: "/root/projects", home: "/root")

    private func render(_ source: String, _ facts: TabTitleFacts) throws -> String {
        try TabTitleTemplate(source).render(facts)
    }

    @Test func plainPlaceholders() throws {
        #expect(try render("{user}@{host}", vim) == "root@sv1")
        #expect(try render("{server}: {process} {args}", vim) == "Web 1: vim /etc/nginx/nginx.conf")
    }

    @Test func conditionalSections() throws {
        let source = "{user}@{host}{process? - {process} {args}}{!process? {cwdShort}}"
        #expect(try render(source, vim) == "root@sv1 - vim /etc/nginx/nginx.conf")
        #expect(try render(source, idle) == "root@sv1 ~/projects")
    }

    @Test func alternativesTakeTheFirstWhoseFactsAreAllThere() throws {
        let source = "{custom|server|user@host}"
        #expect(try render(source, vim) == "Web 1")
        #expect(try render(source, idle) == "root@sv1")
        var named = vim
        named.custom = "prod db"
        #expect(try render(source, named) == "prod db")
        #expect(try render("{custom|\"Shell\"}", TabTitleFacts()) == "Shell")
        #expect(try render("{custom|server}", TabTitleFacts()) == "")
    }

    @Test func whitespaceAndDanglingSeparatorsAreCleaned() throws {
        #expect(try render("{custom? {custom} · }{user}@{host}", idle) == "root@sv1")
        #expect(try render("{host} · {process}", TabTitleFacts(host: "sv1")) == "sv1")
        #expect(try render("  {host}   {user}  ", TabTitleFacts(user: "u", host: "h")) == "h u")
    }

    @Test func bracesEscape() throws {
        #expect(try render("{{{host}}}", idle) == "{sv1}")
    }

    @Test func indexAndTitle() throws {
        let facts = TabTitleFacts(title: "htop - load 0.5", index: 3)
        #expect(try render("{index}: {title}", facts) == "3: htop - load 0.5")
    }

    @Test func widthModifierCapsWithMiddleEllipsis() throws {
        let facts = TabTitleFacts(process: "tail", args: ["-f", "/var/log/nginx/access.log.2026-11-26"])
        let out = try render("{args:20}", facts)
        #expect(out.count == 20)
        #expect(out.hasPrefix("-f /var/l"))
        #expect(out.contains("…"))
        #expect(out.hasSuffix("1-26"))
    }

    @Test func defaultArgsAndPathCaps() throws {
        let long = String(repeating: "a", count: 200)
        let facts = TabTitleFacts(process: "cat", args: [long], cwd: "/" + long)
        #expect(try render("{args}", facts).count == TabTitleTemplate.defaultCaps.args)
        #expect(try render("{cwd}", facts).count == TabTitleTemplate.defaultCaps.path)
    }

    @Test(arguments: ["{host", "{host}}", "{nosuch}", "{process? x", "{?x}", "{host:0}", "{host:x}", "{}"])
    func rejectsBadTemplates(_ source: String) {
        #expect(throws: TabTitleTemplateError.self) { try TabTitleTemplate(source) }
    }

    @Test func errorsSayWhere() {
        do {
            _ = try TabTitleTemplate("{user}@{hots}")
            Issue.record("expected an error")
        } catch {
            #expect(error.description.contains("hots"))
        }
    }

    @Test func secretsInArgsNeverRender() throws {
        let facts = TabTitleFacts(process: "mysql", args: ["-u", "root", "-psecret", "--password=hunter2", "db"])
        let out = try render("{process} {args:200}", facts)
        #expect(!out.contains("secret"))
        #expect(!out.contains("hunter2"))
        #expect(out.contains("db"))
    }

    @Test func lenientFallsBackToDefault() {
        let facts = idle
        #expect(TabTitleTemplate.render("{oops", facts, fallback: "{user}@{host}") == "root@sv1")
    }
}
