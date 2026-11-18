#!/usr/bin/env python3
"""Tests for scripts/ci-pick-runners.py, which decides where each macOS CI job runs.

    python3 scripts/test-ci-pick-runners.py

The rules they pin: a pull request from a fork never reaches the project's Macs; a Mac that has gone quiet gets nothing;
with nothing readable the answer is GitHub's runners, as before; and a burst of work spills over to GitHub's runners instead of piling up.
CI runs this on every change (Linux).
"""
import importlib.util, json, os, subprocess, sys, tempfile, time, unittest

sys.dont_write_bytecode = True  # importing the script must not leave a __pycache__ beside it
HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "ci-pick-runners.py")
spec = importlib.util.spec_from_file_location("ci_pick", SCRIPT)
pick = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pick)

ALL = list(pick.JOBS)
gate_spec = importlib.util.spec_from_file_location("ci_gate", os.path.join(HERE, "ci-runner-job-gate.py"))
gate = importlib.util.module_from_spec(gate_spec)
gate_spec.loader.exec_module(gate)


def run(event, **env):
    """The script's outputs for an event, with no API to read (GITHUB_TOKEN unset)."""
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as file:
        json.dump(event, file)
    clean = {k: v for k, v in os.environ.items() if not k.startswith(("GITHUB_", "CI_", "NEED_"))}
    out = subprocess.run([sys.executable, SCRIPT], env={**clean, "GITHUB_EVENT_PATH": file.name, **env},
                         capture_output=True, text=True, check=True).stdout
    os.unlink(file.name)
    return {line.split("=", 1)[0]: json.loads(line.split("=", 1)[1]) for line in out.splitlines()}


def pull_request(head, base="szeremeta1/Vespertine"):
    return {"pull_request": {"head": {"repo": {"full_name": head}}}, "repository": {"full_name": base}}


class Online(unittest.TestCase):
    def test_fresh_stale_zero_and_junk(self):
        now = 1_000_000
        self.assertEqual(pick.online({"fast": str(now - 30), "shared": str(now - 170)}, now), {"fast", "shared"})
        self.assertEqual(pick.online({"fast": str(now - 181), "shared": "0"}, now), set())
        self.assertEqual(pick.online({"fast": "", "shared": None}, now), set())
        self.assertEqual(pick.online({"fast": "soon", "shared": str(now + 400)}, now), set())


class Plan(unittest.TestCase):
    def test_no_macs_means_hosted(self):
        self.assertEqual(pick.plan(ALL, set()), {job: "hosted" for job in ALL})

    def test_one_pull_request_lands_on_the_projects_macs(self):
        # A short job placed last may be quicker on an idle GitHub runner; not once GitHub has a queue.
        for macs in ({"fast"}, {"fast", "shared"}):
            self.assertEqual(pick.plan(ALL, macs)["app"], "own")
        self.assertEqual(pick.plan(ALL, {"fast"}, hosted_busy=10), {job: "own" for job in ALL})
        self.assertEqual(pick.plan(ALL, {"fast", "shared"}, hosted_busy=10), {job: "own" for job in ALL})

    def test_only_needed_jobs_are_placed(self):
        self.assertEqual(pick.plan(["verification"], {"fast"}), {"verification": "own"})

    def test_a_long_queue_overflows_to_github(self):
        self.assertEqual(set(pick.plan(ALL, {"fast", "shared"}, waiting=120).values()), {"hosted"})

    def test_a_full_hosted_queue_keeps_work_on_the_macs(self):
        self.assertEqual(set(pick.plan(ALL, {"fast"}, waiting=60, hosted_busy=40).values()), {"own"})

    def test_the_slow_mac_alone_takes_only_what_it_finishes_sooner(self):
        chosen = pick.plan(ALL, {"shared"})
        self.assertEqual(chosen["app"], "own")
        self.assertEqual(pick.plan(ALL, {"shared"}, waiting=30)["verification"], "hosted")

    def test_a_burst_uses_both_places(self):
        waiting, hosted_busy, used = 0.0, 0, set()
        for _ in range(8):
            for job, place in pick.plan(ALL, {"fast", "shared"}, waiting, hosted_busy).items():
                used.add(place)
                if place == "hosted":
                    hosted_busy += 1
                else:
                    waiting += pick.OWN_MINUTES[job]
        self.assertEqual(used, {"own", "hosted"})


class Load(unittest.TestCase):
    def test_counts_unfinished_jobs_by_where_they_run(self):
        now = time.time()
        started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - 240))
        jobs = [
            {"name": pick.JOB_NAMES["app"], "status": "queued", "labels": ["self-hosted", "macOS", "vespertine"]},
            {"name": pick.JOB_NAMES["packages"], "status": "in_progress", "started_at": started,
             "labels": ["self-hosted", "macOS", "vespertine-fast"]},
            {"name": pick.JOB_NAMES["verification"], "status": "queued", "labels": ["self-hosted", "macOS", "vespertine-shared"]},
            {"name": pick.JOB_NAMES["app"], "status": "queued", "labels": ["macos-26"]},
            {"name": pick.JOB_NAMES["app"], "status": "completed", "labels": ["macos-26"]},
            {"name": "Analysis core (Linux)", "status": "in_progress", "labels": ["ubuntu-latest"]},
        ]
        waiting, hosted_busy = pick.load(jobs, now)
        own = pick.OWN_MINUTES
        self.assertAlmostEqual(waiting, own["app"] + own["packages"] - 4 + own["verification"], delta=0.2)
        self.assertEqual(hosted_busy, 1)


class Script(unittest.TestCase):
    fresh = {"CI_MAC_FAST_SEEN": str(int(time.time())), "CI_MAC_SHARED_SEEN": str(int(time.time()))}
    hosted = {f"{job}_runner": pick.HOSTED for job in ALL}

    def test_a_fork_never_reaches_the_projects_macs(self):
        self.assertEqual(run(pull_request("someone/Vespertine"), **self.fresh), self.hosted)
        self.assertEqual(run({"pull_request": {"head": {"repo": None}}, "repository": {"full_name": "szeremeta1/Vespertine"}},
                             **self.fresh), self.hosted)

    def test_a_bots_pull_request_never_reaches_the_projects_macs(self):
        # Dependabot's branch is in the repository itself, so it is not a fork: it is told apart by who opened it.
        for author in ({"login": "dependabot[bot]", "type": "Bot"}, {"login": "some-app[bot]"}, {"login": "renovate", "type": "Bot"}):
            event = {"pull_request": {"head": {"repo": {"full_name": "a/b"}}, "user": author}, "repository": {"full_name": "a/b"}}
            self.assertTrue(pick.from_a_bot(event))
            out = run(event, CI_MAC_FAST_SEEN=str(int(time.time())), CI_MAC_SHARED_SEEN=str(int(time.time())))
            self.assertEqual(set(map(json.dumps, out.values())), {json.dumps(pick.HOSTED)})
        person = {"pull_request": {"head": {"repo": {"full_name": "a/b"}}, "user": {"login": "szeremeta1", "type": "User"}}, "repository": {"full_name": "a/b"}}
        self.assertFalse(pick.from_a_bot(person))
        self.assertFalse(pick.from_a_bot({"ref": "refs/heads/main"}))

    def test_a_pull_request_from_the_repository_uses_them(self):
        out = run(pull_request("szeremeta1/Vespertine"), **self.fresh)
        self.assertEqual(out["app_runner"], ["self-hosted", "macOS", "vespertine"])

    def test_nothing_readable_is_hosted(self):
        self.assertEqual(run({}), self.hosted)
        self.assertEqual(run(pull_request("szeremeta1/Vespertine")), self.hosted)

    def test_the_switch_and_the_manual_choice(self):
        self.assertEqual(run({}, CI_OWN_MACS="off", **self.fresh), self.hosted)
        self.assertEqual(run({}, CI_MACS_INPUT="github", **self.fresh), self.hosted)

    def test_a_manual_run_can_ask_for_the_macs_while_they_are_switched_off(self):
        own = {f"{job}_runner": pick.OWN for job in ALL}
        self.assertEqual(run({}, CI_OWN_MACS="off", CI_MACS_INPUT="own", **self.fresh), own)
        self.assertEqual(run({}, CI_OWN_MACS="off", CI_MACS_INPUT="own"), self.hosted)  # no Mac is taking jobs
        self.assertEqual(run(pull_request("someone/Vespertine"), CI_MACS_INPUT="own", **self.fresh), self.hosted)

    def test_a_job_that_is_not_needed_still_gets_a_valid_runner(self):
        out = run({}, NEED_VERIFICATION="false", **self.fresh)
        self.assertEqual(out["verification_runner"], pick.HOSTED)
        self.assertNotEqual(out["app_runner"], pick.HOSTED)


class Gate(unittest.TestCase):
    """scripts/ci-runner-job-gate.py: what a Mac itself refuses, whatever the pull request's own workflow asked for."""
    repo = "szeremeta1/Vespertine"

    def pull(self, head, login="szeremeta1", kind="User"):
        return {"pull_request": {"head": {"repo": {"full_name": head} if head else None}, "user": {"login": login, "type": kind}}}

    def test_a_fork_is_refused(self):
        self.assertIn("another repository", gate.refusal("pull_request", self.pull("someone/Vespertine"), self.repo))
        self.assertIn("another repository", gate.refusal("pull_request", self.pull(None), self.repo))
        self.assertIsNotNone(gate.refusal("pull_request", self.pull(self.repo), ""))

    def test_a_bot_is_refused(self):
        self.assertIn("bot", gate.refusal("pull_request", self.pull(self.repo, "dependabot[bot]", "Bot"), self.repo))

    def test_what_cannot_be_read_is_refused(self):
        self.assertIsNotNone(gate.refusal("pull_request", None, self.repo))
        self.assertIsNotNone(gate.refusal("pull_request", {}, self.repo))
        self.assertIsNotNone(gate.refusal("push", None, self.repo))
        self.assertIsNotNone(gate.refusal("pull_request_target", self.pull(self.repo), self.repo))

    def test_the_repositorys_own_work_runs(self):
        self.assertIsNone(gate.refusal("pull_request", self.pull(self.repo), self.repo))
        self.assertIsNone(gate.refusal("pull_request", self.pull("Szeremeta1/vespertine"), self.repo))
        self.assertIsNone(gate.refusal("push", {"ref": "refs/heads/main"}, self.repo))
        self.assertIsNone(gate.refusal("workflow_dispatch", {"inputs": {"macs": "own"}}, self.repo))

    def test_the_script_fails_the_job(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as file:
            json.dump(self.pull("someone/Vespertine"), file)
        env = {"PATH": os.environ.get("PATH", ""), "GITHUB_EVENT_PATH": file.name, "GITHUB_EVENT_NAME": "pull_request", "GITHUB_REPOSITORY": self.repo}
        refused = subprocess.run([sys.executable, os.path.join(HERE, "ci-runner-job-gate.py")], env=env, capture_output=True, text=True)
        os.unlink(file.name)
        self.assertEqual(refused.returncode, 1)
        self.assertIn("::error::", refused.stdout)


if __name__ == "__main__":
    unittest.main()
