#!/usr/bin/env python3
"""Prints where each macOS CI job should run, as GitHub Actions outputs (app_runner=..., one JSON value per job).

    scripts/ci-pick-runners.py        (in the "changes" job of .github/workflows/ci.yml)

There are three places a macOS job can run:
  hosted   GitHub's own runners (macos-26). Always there, but an account runs only a few at a time and the rest wait.
  fast     the project's fast Mac (label vespertine-fast). Runs one job at a time at full speed, when it is plugged in.
  shared   the project's always-on Mac (label vespertine-shared). Runs one job at a time at low priority, compiling on
           half its cores, because it has other work to do.

Each of the project's Macs writes the time into a repository variable once a minute while it is taking jobs
(CI_MAC_FAST_SEEN, CI_MAC_SHARED_SEEN; 0 when it stops). A Mac not heard from for three minutes is treated as away, so
a Mac that is asleep, unplugged or switched off costs nothing: its jobs go to GitHub's runners as before.

For each job this run needs, the script estimates when it would finish in each place (the work already waiting there,
read from the repository's queued and running jobs, plus how long the job takes there) and takes the earliest. So a
single pull request lands on the project's Macs, and a burst of them spreads over all three.

Always GitHub's runners:
  - a pull request from a fork. The project's Macs never run code from outside the repository;
  - when the repository variable CI_OWN_MACS is "off", or a manual run asks for GitHub's runners;
  - when nothing can be read (no variables, no API): the answer is the one the workflow had before.
"""
import calendar, json, os, sys, time, urllib.request

HOSTED = "macos-26"
LABELS = {"fast": "vespertine-fast", "shared": "vespertine-shared"}
RUNS_ON = {"hosted": HOSTED, **{pool: ["self-hosted", "macOS", label] for pool, label in LABELS.items()}}
JOBS = ("app", "packages", "verification")  # the order they are placed in: the longest first
JOB_NAMES = {"app": "App (macOS)", "packages": "Engine, library and real-time C (macOS)",
             "verification": "Spec-traced checks against Vespertine (macOS)"}
# Minutes a job takes once it has started. Rough, from the runs so far; only their order of size matters.
MINUTES = {
    "hosted": {"app": 30, "packages": 25, "verification": 30},
    "fast": {"app": 10, "packages": 8, "verification": 8},
    "shared": {"app": 35, "packages": 30, "verification": 25},
}
HOSTED_AT_ONCE = 5   # macOS jobs GitHub runs at the same time for one account
HOSTED_START = 1     # minutes for a free hosted runner to pick a job up
FRESH_SECONDS = 180  # a Mac heard from within this long is taking jobs


def online(seen, now):
    """The pools whose Mac was heard from lately. `seen` maps a pool to its variable's text."""
    result = set()
    for pool in LABELS:
        try:
            stamp = int(str(seen.get(pool) or "0").strip())
        except ValueError:
            stamp = 0
        if 0 <= now - stamp < FRESH_SECONDS:
            result.add(pool)
    return result


def plan(needed, pools, waiting=None, hosted_busy=0):
    """Where each needed job goes. `pools` are the project's Macs taking jobs, `waiting` the minutes of work already
    queued or running on each, `hosted_busy` the macOS jobs already queued or running on GitHub's runners."""
    waiting = dict(waiting or {})
    result = {}
    for job in JOBS:
        if job not in needed:
            continue
        over = hosted_busy - HOSTED_AT_ONCE + 1
        hosted_wait = HOSTED_START if over <= 0 else over * sum(MINUTES["hosted"].values()) / 3 / HOSTED_AT_ONCE
        finish = {"hosted": hosted_wait + MINUTES["hosted"][job]}
        for pool in pools:
            finish[pool] = waiting.get(pool, 0) + MINUTES[pool][job]
        best = min(finish, key=lambda pool: (finish[pool], pool != "fast", pool != "shared"))
        result[job] = best
        if best == "hosted":
            hosted_busy += 1
        else:
            waiting[best] = finish[best]
    return result


def load(jobs, now):
    """From the repository's unfinished jobs: the minutes waiting on each of the project's Macs, and the count on
    GitHub's macOS runners."""
    waiting, hosted_busy = {pool: 0.0 for pool in LABELS}, 0
    for job in jobs:
        if job.get("status") == "completed":
            continue
        labels = job.get("labels") or []
        kind = next((k for k, name in JOB_NAMES.items() if job.get("name") == name), "app")
        pool = next((p for p, label in LABELS.items() if label in labels), None)
        if pool:
            left = MINUTES[pool][kind]
            started = job.get("started_at")
            if job.get("status") == "in_progress" and started:
                ran = (now - calendar.timegm(time.strptime(started, "%Y-%m-%dT%H:%M:%SZ"))) / 60
                left = max(2.0, left - ran)
            waiting[pool] += left
        elif any(str(label).startswith("macos") for label in labels):
            hosted_busy += 1
    return waiting, hosted_busy


def unfinished_jobs(repository, token, own_run):
    def get(path):
        request = urllib.request.Request(f"https://api.github.com/repos/{repository}/{path}", headers={
            "Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"})
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)
    jobs = []
    for status in ("in_progress", "queued"):
        for run in get(f"actions/runs?status={status}&per_page=50").get("workflow_runs", []):
            if str(run["id"]) != str(own_run):
                jobs += get(f"actions/runs/{run['id']}/jobs?per_page=100").get("jobs", [])
    return jobs


def from_fork(event):
    head = (event.get("pull_request") or {}).get("head") or {}
    return "pull_request" in event and (head.get("repo") or {}).get("full_name") != (event.get("repository") or {}).get("full_name")


def main():
    env = os.environ
    needed = [job for job in JOBS if env.get(f"NEED_{job.upper()}", "true") != "false"]
    try:
        with open(env["GITHUB_EVENT_PATH"]) as file:
            event = json.load(file)
    except (KeyError, OSError, ValueError):
        event = {}
    now = time.time()
    why = None
    if from_fork(event):
        why = "a pull request from a fork runs on GitHub's runners only"
    elif env.get("CI_OWN_MACS", "").strip().lower() == "off" or env.get("CI_MACS_INPUT") == "github":
        why = "the project's Macs are switched off for CI"
    pools = set() if why else online({"fast": env.get("CI_MAC_FAST_SEEN"), "shared": env.get("CI_MAC_SHARED_SEEN")}, now)
    waiting, hosted_busy = {}, 0
    if pools:
        try:
            waiting, hosted_busy = load(unfinished_jobs(env["GITHUB_REPOSITORY"], env["GITHUB_TOKEN"], env.get("GITHUB_RUN_ID")), now)
        except Exception as error:  # the queue is only a refinement: without it the Macs count as free
            print(f"could not read the queue ({error}): counting every runner as free", file=sys.stderr)
    chosen = plan(needed, pools, waiting, hosted_busy)
    summary = [f"Macs taking jobs: {', '.join(sorted(pools)) or 'none'}" + (f" ({why})" if why else ""),
               f"Already waiting: fast {waiting.get('fast', 0):.0f} min, shared {waiting.get('shared', 0):.0f} min, "
               f"GitHub macOS jobs {hosted_busy}"]
    for job in JOBS:
        pool = chosen.get(job, "hosted")
        print(f"{job}_runner={json.dumps(RUNS_ON[pool])}")
        if job in chosen:
            summary.append(f"{JOB_NAMES[job]}: {pool}")
    print("\n".join(summary), file=sys.stderr)
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a") as file:
            file.write("\n".join(f"- {line}" for line in summary) + "\n")


if __name__ == "__main__":
    main()
