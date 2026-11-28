"""Cloud first, the Mac only for its own jobs: the rules of .gitlab-ci.yml (docs/desktop/release.md "Cloud and Mac").

- Only the Mac jobs (desktop:macos-dmg, apple:testflight-mac) run on the Mac runner (tag $MAC_RUNNER_TAG = macos).
- No cloud job needs a Mac job, directly or through another job: a release never waits for the Mac.
- desktop:macos-dmg starts with the tag, needs nothing, may fail alone, and gets no release keys (no environment).
- desktop:macos-dmg-attach (cloud) waits for the DMG and for the published release, then starts the attach pipeline on
  main with the DMG's name and sha256; that pipeline runs desktop:macos-attach (keys in environment rsshd-release) and
  never pages:refresh.
- The signing jobs keep their protected environments.

Run (repo root): python3 -m unittest discover -s desktop/packaging/tests -p 'ci_*_test.py'
"""
import os
import unittest

import yaml

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
MAC_JOBS = {"desktop:macos-dmg", "apple:testflight-mac"}


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

    def test_mac_runner_tag(self):
        self.assertEqual(self.ci["variables"]["MAC_RUNNER_TAG"], "macos")

    def test_only_mac_jobs_use_the_mac_runner(self):
        on_mac = {n for n, j in self.jobs.items()
                  if "$MAC_RUNNER_TAG" in (j.get("tags") or []) or "macos" in (j.get("tags") or [])}
        self.assertEqual(on_mac, MAC_JOBS)

    def test_no_cloud_job_waits_for_the_mac(self):
        def closure(name, seen):
            for n in needs_of(self.jobs[name]):
                if n not in seen:
                    seen.add(n)
                    closure(n, seen)
            return seen
        allowed = {"desktop:macos-dmg-attach"}  # the one cloud job that exists to wait for the DMG
        for name in self.jobs:
            if name in MAC_JOBS or name in allowed:
                continue
            self.assertFalse(closure(name, set()) & MAC_JOBS, f"{name} waits for a Mac job")

    def test_dmg_job(self):
        j = self.jobs["desktop:macos-dmg"]
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
        j = self.jobs["desktop:macos-dmg-attach"]
        self.assertNotIn("tags", j)
        self.assertEqual(j["trigger"], {"project": "$CI_PROJECT_PATH", "branch": "$CI_DEFAULT_BRANCH"})
        self.assertTrue({"desktop:macos-dmg", "desktop:gitlab-release", "github:release", "github:links"}
                        <= set(needs_of(j)))
        for v in ("MACOS_DMG_VERSION", "MACOS_DMG_NAME", "MACOS_DMG_SHA256"):
            self.assertEqual(j["variables"][v], "$" + v)
        self.assertEqual(resolve(self.ci, j["rules"]), resolve(self.ci, self.jobs["desktop:macos-dmg"]["rules"]))
        # github:links must finish its main pipeline (pages:refresh) before the attach one starts, or that
        # pipeline's Pages deploy could replace the site with the DMG.
        self.assertEqual(self.jobs["github:links"]["trigger"].get("strategy"), "depend")

    def test_attach_pipeline_on_main(self):
        rules = resolve(self.ci, self.ci[".desktop-macos-attach"]["rules"])
        self.assertIn({"if": '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH && $CI_PIPELINE_SOURCE == "pipeline" '
                             '&& $MACOS_DMG_SHA256'}, rules)
        refresh = resolve(self.ci, self.ci[".pages-refresh"]["rules"])
        self.assertEqual(refresh[0], {"if": "$MACOS_DMG_SHA256", "when": "never"})
        script = " ".join(self.jobs["desktop:macos-attach"]["script"])
        self.assertIn("MACOS_DMG_PIN", script)
        self.assertEqual(self.jobs["desktop:macos-attach"]["environment"]["name"], "rsshd-release")

    def test_release_keys_stay_in_their_environments(self):
        for name in ("rsshd:release", "desktop:release", "pages:refresh", "desktop:macos-attach"):
            self.assertEqual(self.jobs[name]["environment"]["name"], "rsshd-release", name)
        for name in ("github:release", "github:macos-attach", "github:pages"):
            self.assertEqual(self.jobs[name]["environment"]["name"], "github-release", name)

    def test_release_does_not_need_the_dmg(self):
        self.assertNotIn("desktop:macos-dmg", needs_of(self.jobs["desktop:release"]))

    def test_mac_app_store_job_is_separate(self):
        j = self.jobs["apple:testflight-mac"]
        self.assertEqual(j.get("needs"), [])
        rules = resolve(self.ci, j["rules"])
        self.assertEqual(rules[0], {"if": '$MAC_APPSTORE_UPLOAD != "on"', "when": "never"})
        self.assertTrue(all(r.get("allow_failure") for r in rules[1:]), "the Mac App Store job never blocks")


if __name__ == "__main__":
    unittest.main()
