#!/usr/bin/env python3
"""Tests for scripts/ci-pick-runners.py, which decides where each macOS CI job runs.

    python3 scripts/test-ci-pick-runners.py

The rules they pin: a pull request from a fork never reaches the project's Macs; a Mac that has gone quiet gets nothing;
with nothing readable the answer is GitHub's runners, as before; and a burst of work spreads instead of piling up.
CI runs this on every change (Linux).
"""
import importlib.util, json, os, subprocess, sys, tempfile, time, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "ci-pick-runners.py")
spec = importlib.util.spec_from_file_location("ci_pick", SCRIPT)
pick = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pick)

ALL = list(pick.JOBS)


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
        chosen = pick.plan(ALL, {"fast", "shared"})
        self.assertEqual(chosen["app"], "fast")
        self.assertNotIn("hosted", chosen.values())

    def test_only_needed_jobs_are_placed(self):
        self.assertEqual(pick.plan(["verification"], {"fast"}), {"verification": "fast"})

    def test_a_busy_mac_overflows_to_the_others(self):
        chosen = pick.plan(ALL, {"fast", "shared"}, {"fast": 60, "shared": 0})
        self.assertNotIn("fast", chosen.values())
        self.assertIn("hosted", chosen.values())

    def test_a_full_hosted_queue_keeps_work_on_the_macs(self):
        chosen = pick.plan(ALL, {"fast"}, {"fast": 30}, hosted_busy=40)
        self.assertEqual(set(chosen.values()), {"fast"})

    def test_a_burst_uses_all_three(self):
        waiting, hosted_busy, used = {}, 0, set()
        for _ in range(6):
            for job, pool in pick.plan(ALL, {"fast", "shared"}, waiting, hosted_busy).items():
                used.add(pool)
                if pool == "hosted":
                    hosted_busy += 1
                else:
                    waiting[pool] = waiting.get(pool, 0) + pick.MINUTES[pool][job]
        self.assertEqual(used, {"fast", "shared", "hosted"})


class Load(unittest.TestCase):
    def test_counts_unfinished_jobs_by_where_they_run(self):
        now = time.time()
        started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - 240))
        jobs = [
            {"name": pick.JOB_NAMES["app"], "status": "queued", "labels": ["self-hosted", "macOS", "vespertine-fast"]},
            {"name": pick.JOB_NAMES["packages"], "status": "in_progress", "started_at": started,
             "labels": ["self-hosted", "macOS", "vespertine-fast"]},
            {"name": pick.JOB_NAMES["verification"], "status": "queued", "labels": ["self-hosted", "macOS", "vespertine-shared"]},
            {"name": pick.JOB_NAMES["app"], "status": "queued", "labels": ["macos-26"]},
            {"name": pick.JOB_NAMES["app"], "status": "completed", "labels": ["macos-26"]},
            {"name": "Analysis core (Linux)", "status": "in_progress", "labels": ["ubuntu-latest"]},
        ]
        waiting, hosted_busy = pick.load(jobs, now)
        self.assertAlmostEqual(waiting["fast"], pick.MINUTES["fast"]["app"] + pick.MINUTES["fast"]["packages"] - 4, delta=0.2)
        self.assertEqual(waiting["shared"], pick.MINUTES["shared"]["verification"])
        self.assertEqual(hosted_busy, 1)


class Script(unittest.TestCase):
    fresh = {"CI_MAC_FAST_SEEN": str(int(time.time())), "CI_MAC_SHARED_SEEN": str(int(time.time()))}
    hosted = {f"{job}_runner": pick.HOSTED for job in ALL}

    def test_a_fork_never_reaches_the_projects_macs(self):
        self.assertEqual(run(pull_request("someone/Vespertine"), **self.fresh), self.hosted)
        self.assertEqual(run({"pull_request": {"head": {"repo": None}}, "repository": {"full_name": "szeremeta1/Vespertine"}},
                             **self.fresh), self.hosted)

    def test_a_pull_request_from_the_repository_uses_them(self):
        out = run(pull_request("szeremeta1/Vespertine"), **self.fresh)
        self.assertEqual(out["app_runner"], ["self-hosted", "macOS", "vespertine-fast"])

    def test_nothing_readable_is_hosted(self):
        self.assertEqual(run({}), self.hosted)
        self.assertEqual(run(pull_request("szeremeta1/Vespertine")), self.hosted)

    def test_the_switch_and_the_manual_choice(self):
        self.assertEqual(run({}, CI_OWN_MACS="off", **self.fresh), self.hosted)
        self.assertEqual(run({}, CI_MACS_INPUT="github", **self.fresh), self.hosted)

    def test_a_job_that_is_not_needed_still_gets_a_valid_runner(self):
        out = run({}, NEED_VERIFICATION="false", **self.fresh)
        self.assertEqual(out["verification_runner"], pick.HOSTED)
        self.assertNotEqual(out["app_runner"], pick.HOSTED)


if __name__ == "__main__":
    unittest.main()
