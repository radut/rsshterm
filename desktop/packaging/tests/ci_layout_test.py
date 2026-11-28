"""Cloud first, the Mac only for its own jobs: the rules of .gitlab-ci.yml (docs/desktop/release.md "Cloud and Mac").

- Only the Mac jobs (build:desktop-mac-dmg, deliver:testflight-mac) run on the shared macos runner (tag $MAC_RUNNER_TAG),
  one at a time (resource_group rssh-macos).
- No cloud job needs a Mac job, directly or through another job: a release never waits for the Mac.
- build:desktop-mac-dmg starts with the tag, needs nothing, may fail alone, and gets no release keys (no environment).
- release:desktop-mac-dmg-start (cloud) waits for the DMG and for the published release, then starts the attach pipeline on
  main with the DMG's name and sha256; that pipeline runs release:desktop-mac-dmg (keys in environment rsshd-release) and
  never release:pages-refresh.
- The signing jobs keep their protected environments.

Run (repo root): python3 -m unittest discover -s desktop/packaging/tests -p 'ci_*_test.py'
"""
import os
import unittest

import yaml

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
MAC_JOBS = {"build:desktop-mac-dmg", "deliver:testflight-mac"}
# Every job, named <stage>:<component>-<platform>[-<what>] (devops/coord standards/app-pipelines.md).
STANDARD_JOBS = {
    "build:desktop-linux",
    "build:desktop-linux-appimage",
    "build:desktop-linux-appimage-arm64",
    "build:desktop-linux-arm64",
    "build:desktop-linux-deb",
    "build:desktop-mac-cloud",
    "build:desktop-mac-dmg",
    "build:desktop-ppa-source",
    "build:ios-freerdp-xcframework",
    "build:rsshd",
    "build:rsshd-ppa-source",
    "deliver:github-pages",
    "release:pages",
    "release:pages-refresh",
    "deliver:ppa-desktop",
    "deliver:ppa-rsshd",
    "deliver:ppa-swift-toolchain",
    "deliver:testflight-ios",
    "deliver:testflight-mac",
    "deliver:testflight-mac-cloud",
    "release:desktop",
    "release:desktop-gitlab",
    "release:desktop-mac-dmg",
    "release:desktop-mac-dmg-github",
    "release:desktop-mac-dmg-gitlab",
    "release:desktop-mac-dmg-start",
    "release:github",
    "release:links",
    "release:rsshd",
    "release:rsshd-gitlab",
    "test:desktop-checks",
    "test:desktop-core",
    "test:desktop-linux-app",
    "build:desktop-linux-appimage-check",
    "test:desktop-mac-cloud",
    "test:desktop-site",
    "test:ios-preflight",
    "test:ios-remote-desktop",
    "test:ios-swift",
    "test:legal-notices",
    "test:ppa-desktop",
    "test:ppa-rsshd",
    "test:release-github",
    "test:rsshd",
    "test:rsshd-apt-repo",
    "test:rsshd-checks",
    "test:rsshd-lintian",
    "test:rsshd-linux-install",
    "test:rsshd-package",
}


class _Loader(yaml.SafeLoader):
    pass


_Loader.add_constructor("!reference", lambda loader, node: {"!reference": loader.construct_sequence(node)})


def load():
    with open(os.path.join(ROOT, ".gitlab-ci.yml")) as f:
        return yaml.load(f, Loader=_Loader)


def resolve(ci, value):
    """Expands !reference [job, key] (one level is all this file uses) inside a list of rules."""
    if isinstance(value, dict) and "!reference" in value:
        job, key = value["!reference"]
        return resolve(ci, ci[job][key])
    if isinstance(value, list):
        out = []
        for item in value:
            r = resolve(ci, item)
            out.extend(r if isinstance(item, dict) and "!reference" in item and isinstance(r, list) else [r])
        return out
    return value


def merged(ci, name):
    """A job with its `extends` applied (shallow, like GitLab for these keys)."""
    job = ci[name]
    parents = job.get("extends", [])
    out = {}
    for p in [parents] if isinstance(parents, str) else parents:
        out.update(merged(ci, p))
    out.update(job)
    return out


def jobs(ci):
    reserved = {"workflow", "variables", "stages", "default", "include"}
    return {k: merged(ci, k) for k in ci if not k.startswith(".") and k not in reserved}


def needs_of(job):
    return [n if isinstance(n, str) else n["job"] for n in job.get("needs", []) or []]


class CloudFirst(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ci = load()
        cls.jobs = jobs(cls.ci)

    def test_stages_and_names_follow_the_standard(self):
        self.assertEqual(self.ci["stages"], ["test", "build", "release", "deliver"])
        self.assertEqual(set(self.jobs), STANDARD_JOBS)
        for name, job in self.jobs.items():
            self.assertEqual(job.get("stage"), name.split(":", 1)[0], name)

    def test_pages_deploys_from_its_job(self):
        self.assertIs(self.jobs["release:pages"].get("pages"), True)

    def test_mac_runner_tag(self):
        self.assertEqual(self.ci["variables"]["MAC_RUNNER_TAG"], "macos")

    def test_only_mac_jobs_use_the_mac_runner(self):
        on_mac = {n for n, j in self.jobs.items()
                  if "$MAC_RUNNER_TAG" in (j.get("tags") or []) or "macos" in (j.get("tags") or [])}
        self.assertEqual(on_mac, MAC_JOBS)

    def test_mac_jobs_run_one_at_a_time(self):
        # The Mac runner is shared by every app (concurrent=2): rSSH's own Mac jobs serialise on one resource group,
        # nothing relies on the runner's concurrency.
        groups = {self.jobs[n].get("resource_group") for n in MAC_JOBS}
        self.assertEqual(groups, {"rssh-macos"})
        for n in MAC_JOBS:
            self.assertEqual(self.jobs[n]["tags"], ["$MAC_RUNNER_TAG"], n)

    def test_no_cloud_job_waits_for_the_mac(self):
        def closure(name, seen):
            for n in needs_of(self.jobs[name]):
                if n not in seen:
                    seen.add(n)
                    closure(n, seen)
            return seen
        allowed = {"release:desktop-mac-dmg-start"}  # the one cloud job that exists to wait for the DMG
        for name in self.jobs:
            if name in MAC_JOBS or name in allowed:
                continue
            self.assertFalse(closure(name, set()) & MAC_JOBS, f"{name} waits for a Mac job")

    def test_dmg_job(self):
        j = self.jobs["build:desktop-mac-dmg"]
        self.assertEqual(j.get("needs"), [])
        self.assertIs(j.get("allow_failure"), True)
        self.assertNotIn("environment", j, "the Mac job must not get the release keys")
        self.assertIn("desktop/packaging/scripts/ci-macos-dmg.sh", " ".join(j["script"]))
        self.assertIn("dotenv", j["artifacts"]["reports"])
        rules = resolve(self.ci, j["rules"])
        self.assertEqual(rules[0], {"if": '$DESKTOP_DMG != "on"', "when": "never"})
        self.assertIn({"if": "$CI_COMMIT_TAG =~ /^desktop-v[0-9]+\\.[0-9]+\\.[0-9]+$/"}, rules)
        self.assertEqual(self.ci["variables"]["DESKTOP_DMG"], "on")

    def test_attach_trigger(self):
        j = self.jobs["release:desktop-mac-dmg-start"]
        self.assertNotIn("tags", j)
        self.assertEqual(j["trigger"], {"project": "$CI_PROJECT_PATH", "branch": "$CI_DEFAULT_BRANCH"})
        self.assertTrue({"build:desktop-mac-dmg", "release:desktop-gitlab", "release:github", "release:links"}
                        <= set(needs_of(j)))
        for v in ("MACOS_DMG_VERSION", "MACOS_DMG_NAME", "MACOS_DMG_SHA256"):
            self.assertEqual(j["variables"][v], "$" + v)
        self.assertEqual(resolve(self.ci, j["rules"]), resolve(self.ci, self.jobs["build:desktop-mac-dmg"]["rules"]))
        # release:links must finish its main pipeline (release:pages-refresh) before the attach one starts, or that
        # pipeline's Pages deploy could replace the site with the DMG.
        self.assertEqual(self.jobs["release:links"]["trigger"].get("strategy"), "depend")

    def test_attach_pipeline_on_main(self):
        rules = resolve(self.ci, self.ci[".desktop-macos-attach"]["rules"])
        self.assertIn({"if": '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH && $CI_PIPELINE_SOURCE == "pipeline" '
                             '&& $MACOS_DMG_SHA256'}, rules)
        refresh = resolve(self.ci, self.ci[".pages-refresh"]["rules"])
        self.assertEqual(refresh[0], {"if": "$MACOS_DMG_SHA256", "when": "never"})
        script = " ".join(self.jobs["release:desktop-mac-dmg"]["script"])
        self.assertIn("MACOS_DMG_PIN", script)
        self.assertEqual(self.jobs["release:desktop-mac-dmg"]["environment"]["name"], "rsshd-release")

    def test_release_keys_stay_in_their_environments(self):
        for name in ("release:rsshd", "release:desktop", "release:pages-refresh", "release:desktop-mac-dmg"):
            self.assertEqual(self.jobs[name]["environment"]["name"], "rsshd-release", name)
        for name in ("release:github", "release:desktop-mac-dmg-github", "deliver:github-pages"):
            self.assertEqual(self.jobs[name]["environment"]["name"], "github-release", name)

    def test_release_does_not_need_the_dmg(self):
        self.assertNotIn("build:desktop-mac-dmg", needs_of(self.jobs["release:desktop"]))

    def test_mac_app_store_job_is_separate(self):
        j = self.jobs["deliver:testflight-mac"]
        self.assertEqual(j.get("needs"), [])
        rules = resolve(self.ci, j["rules"])
        self.assertEqual(rules[0], {"if": '$MAC_APPSTORE_UPLOAD != "on"', "when": "never"})
        self.assertTrue(all(r.get("allow_failure") for r in rules[1:]), "the Mac App Store job never blocks")


if __name__ == "__main__":
    unittest.main()
