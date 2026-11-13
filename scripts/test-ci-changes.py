#!/usr/bin/env python3
"""Tests for scripts/ci-changes.py, the gate that decides which macOS CI jobs a change runs.

    python3 scripts/test-ci-changes.py

The rule they pin: a change to app code always runs "App (macOS)" and "Engine (macOS)" (outputs app and packages), and a
job is skipped only when every changed file is provably one it doesn't read. CI runs this on every change (Linux).
"""
import importlib.util, os, subprocess, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ci_changes", os.path.join(HERE, "ci-changes.py"))
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)

APP_CODE = [
    "App/Sources/Models/PlayerController.swift", "App/Tests/QueueMoveTests.swift", "App/Resources/Localizable.xcstrings",
    "App/Info.plist", "App/Licenses/README.txt", "App/Package.resolved", "project.yml",
    "Packages/VespertineKit/Package.swift", "Packages/VespertineKit/Package.resolved",
    "Packages/VespertineKit/Sources/VespertineAudio/PlaybackEngine.swift",
    "Packages/VespertineKit/Sources/CVespertineRT/vespertine_rt.c", "Packages/VespertineKit/Tests/VespertineAudioTests/X.swift",
    "Packages/VespertineAnalysis/Sources/x.swift", "Packages/VespertineRemoteKit/Sources/x.swift",
    "Driver/VespertineSound/VespertineSound.c", "Helper/Sources/main.swift", "Helper/LaunchAgents/x.plist",
    "RemoteApp/project.yml", "RemoteApp/Sources/x.swift",
    "scripts/generate-project.sh", "scripts/check-lockfiles.py", "scripts/ci-changes.py",
    ".github/workflows/ci.yml", "LICENSE", "THIRD-PARTY-NOTICES.md",
    # a directory that doesn't exist yet, by extension
    "NewModule/Sources/Thing.swift", "Shared/thing.h", "Extras/Info.plist", "Extras/Strings.xcstrings",
]
DOCS_ONLY = [
    "README.md", "CONTRIBUTING.md", "SECURITY.md", "docs/guide.md", "docs/images/a.png", "site/index.html",
    "site/assets/a.css", ".github/ISSUE_TEMPLATE/bug.yml", ".github/workflows/pages.yml", "scripts/brand/logo.svg",
]


def run(*files):
    return ci.needed(list(files))


class AppCodeAlwaysRunsBothMacJobs(unittest.TestCase):
    def test_every_app_code_path(self):
        for f in APP_CODE:
            with self.subTest(file=f):
                r = run(f)
                self.assertTrue(r["app"], f"{f}: App (macOS) skipped")
                self.assertTrue(r["packages"], f"{f}: Engine (macOS) skipped")

    def test_app_code_among_docs(self):
        for f in APP_CODE:
            with self.subTest(file=f):
                r = run(*DOCS_ONLY, f, "verification/README.md")
                self.assertTrue(r["app"] and r["packages"])

    def test_pr_218_shape(self):
        r = run("App/Sources/Views/TrackViews.swift", "App/Tests/GoneFileTests.swift", "App/Resources/Localizable.xcstrings",
                "Packages/VespertineKit/Sources/VespertineAudio/PlaybackEngine.swift",
                "Packages/VespertineKit/Tests/VespertineAudioTests/BuiltInHogTests.swift")
        self.assertTrue(r["app"] and r["packages"])

    def test_app_only_change_still_runs_engine(self):
        # The old rule skipped the Engine job for App/ and project.yml changes.
        for f in ("App/Sources/Views/TrackViews.swift", "project.yml"):
            self.assertTrue(run(f)["packages"], f)

    def test_unknown_paths_run_everything(self):
        r = run("some-new-top-level-file.xyz")
        self.assertTrue(r["app"] and r["packages"] and r["verification"])

    def test_empty_diff_runs_everything(self):
        self.assertEqual(ci.needed([]), {"packages": True, "app": True, "verification": True})


class SkipsOnlyWhenNothingRelevantChanged(unittest.TestCase):
    def test_docs_only_skips_everything(self):
        for f in DOCS_ONLY:
            with self.subTest(file=f):
                self.assertEqual(run(f), {"packages": False, "app": False, "verification": False})

    def test_verification_only_skips_app_and_engine(self):
        for f in ("verification/tools/check_registry.py", "verification/harness/Package.swift",
                  "verification/harness/Tests/x.swift", "verification/studio/test_evidence.py"):
            with self.subTest(file=f):
                r = run(f)
                self.assertFalse(r["app"] or r["packages"], f)

    def test_harness_swift_still_runs_verification(self):
        self.assertTrue(run("verification/harness/Tests/x.swift")["verification"])

    def test_c_audit_runs_engine_not_app(self):
        r = run("tests/rt-audit.c")
        self.assertTrue(r["packages"])
        self.assertFalse(r["app"])

    def test_scripts_tooling_runs_engine_only_when_not_named(self):
        r = run("scripts/make-icon.swift")
        self.assertTrue(r["packages"])


class CommandLine(unittest.TestCase):
    def test_outputs(self):
        out = subprocess.run([sys.executable, os.path.join(HERE, "ci-changes.py"), "App/Sources/App/X.swift"],
                             capture_output=True, text=True, check=True).stdout.split()
        self.assertEqual(out, ["packages=true", "app=true", "verification=false"])


if __name__ == "__main__":
    unittest.main()
