#!/usr/bin/env python3
"""Prints where each macOS CI job should run, as GitHub Actions outputs (app_runner=..., one JSON value per job).

    scripts/ci-pick-runners.py        (in the "changes" job of .github/workflows/ci.yml)

There are two places a macOS job can run:
  hosted   GitHub's own runners (macos-26). Always there, but an account runs only a few at a time and the rest wait.
  own      the project's own Macs (label vespertine), each running one job at a time. "fast" works at full speed when
           it is plugged in; "shared" is always on but works at low priority, compiling on half its cores, because
           it has other work to do. A job sent to the project's Macs is taken by whichever is free first, so neither
           sits idle while the other has a queue.

Each of the project's Macs writes the time into a repository variable once a minute while it is taking jobs
(CI_MAC_FAST_SEEN, CI_MAC_SHARED_SEEN; 0 when it stops). A Mac not heard from for three minutes is treated as away, so
a Mac that is asleep, unplugged or switched off costs nothing: its jobs go to GitHub's runners as before.

For each job this run needs, the script estimates when it would finish in each place (the work already waiting there,
read from the repository's queued and running jobs, plus how long the job takes there) and takes the earlier. So a
single pull request lands on the project's Macs, and a burst of them spills over to GitHub's runners.

Always GitHub's runners:
  - a pull request from a fork. The project's Macs never run code from outside the repository. This script is only
    the courtesy half of that rule: a pull request brings its own copy of this script and of the workflow, so one from a
    fork could ask for the Macs anyway. What holds is the repository's setting that no workflow from an outside
    contributor runs until the maintainer approves it, and a check on the Macs themselves (a runner job-started hook
    that refuses a fork's job: scripts/ci-runner-job-gate.sh). Read a fork's changes to .github/ and scripts/ci-* before approving;
  - a pull request opened by a bot (Dependabot's updates to the pinned actions): it runs without anybody having read
    it, and a job on the project's Macs runs as the person who uses that Mac;
  - when the repository variable CI_OWN_MACS is "off", or a manual run asks for GitHub's runners (a manual run that
    asks for the project's Macs gets them whenever one is taking jobs, even with the variable off: that is how a change
    to the Macs is tried before they are switched back on for everyone);
  - when nothing can be read (no variables, no API): the answer is the one the workflow had before.
"""
import calendar, json, os, sys, time, urllib.request

HOSTED = "macos-26"
OWN = ["self-hosted", "macOS", "vespertine"]
# The label every one of the project's Macs carries, and the ones that name a single Mac (older runs asked for those).
OWN_LABELS = ("vespertine", "vespertine-fast", "vespertine-shared")
JOBS = ("app", "packages", "verification")  # the order they are placed in: the longest first
JOB_NAMES = {"app": "App (macOS)", "packages": "Engine, library and real-time C (macOS)",
             "verification": "Spec-traced checks against Vespertine (macOS)"}
# Minutes a job takes once it has started: on GitHub's runner, and on the fast Mac. Measured on the first runs.
HOSTED_MINUTES = {"app": 34, "packages": 25, "verification": 8}
OWN_MINUTES = {"app": 6, "packages": 9, "verification": 2}
# How much of the fast Mac's work each Mac does in the same time.
SPEED = {"fast": 1.0, "shared": 0.3}
HOSTED_AT_ONCE = 5   # macOS jobs GitHub runs at the same time for one account
HOSTED_START = 1     # minutes for a free hosted runner to pick a job up
FRESH_SECONDS = 180  # a Mac heard from within this long is taking jobs


def online(seen, now):
    """The Macs heard from lately. `seen` maps a Mac to its variable's text."""
    result = set()
    for mac in SPEED:
        try:
            stamp = int(str(seen.get(mac) or "0").strip())
        except ValueError:
            stamp = 0
        if 0 <= now - stamp < FRESH_SECONDS:
            result.add(mac)
    return result


def plan(needed, macs, waiting=0.0, hosted_busy=0):
    """Where each needed job goes: "own" or "hosted". `macs` are the project's Macs taking jobs, `waiting` the minutes
    of work (at the fast Mac's speed) already queued or running on them, `hosted_busy` the macOS jobs already queued or
    running on GitHub's runners."""
    rate = sum(SPEED[mac] for mac in macs)
    result = {}
    for job in JOBS:
        if job not in needed:
            continue
        over = hosted_busy - HOSTED_AT_ONCE + 1
        hosted_wait = HOSTED_START if over <= 0 else over * sum(HOSTED_MINUTES.values()) / 3 / HOSTED_AT_ONCE
        hosted_finish = hosted_wait + HOSTED_MINUTES[job]
        # The Macs work through what is waiting together; the job itself may land on the slowest of them.
        own_finish = waiting / rate + OWN_MINUTES[job] / min(SPEED[mac] for mac in macs) if macs else None
        if own_finish is not None and own_finish <= hosted_finish:
            result[job] = "own"
            waiting += OWN_MINUTES[job]
        else:
            result[job] = "hosted"
            hosted_busy += 1
    return result


def load(jobs, now):
    """From the repository's unfinished jobs: the minutes of work waiting on the project's Macs (at the fast Mac's
    speed), and the count on GitHub's macOS runners."""
    waiting, hosted_busy = 0.0, 0
    for job in jobs:
        if job.get("status") == "completed":
            continue
        labels = job.get("labels") or []
        kind = next((k for k, name in JOB_NAMES.items() if job.get("name") == name), "app")
        if any(label in OWN_LABELS for label in labels):
            left = OWN_MINUTES[kind]
            started = job.get("started_at")
            if job.get("status") == "in_progress" and started:
                ran = (now - calendar.timegm(time.strptime(started, "%Y-%m-%dT%H:%M:%SZ"))) / 60
                left = max(1.0, left - ran)
            waiting += left
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


def from_a_bot(event):
    """A pull request opened by a bot (Dependabot's updates to the pinned actions): what it proposes is code nobody has
    read yet, and the jobs on the project's Macs would run it as the person who uses that Mac."""
    author = (event.get("pull_request") or {}).get("user") or {}
    return "pull_request" in event and (author.get("type") == "Bot" or str(author.get("login") or "").endswith("[bot]"))


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
    forced = env.get("CI_MACS_INPUT") == "own"  # a manual run that asks for the project's Macs
    if from_fork(event):
        why = "a pull request from a fork runs on GitHub's runners only"
    elif from_a_bot(event):
        why = "a pull request opened by a bot runs on GitHub's runners only"
    elif env.get("CI_MACS_INPUT") == "github" or (env.get("CI_OWN_MACS", "").strip().lower() == "off" and not forced):
        why = "the project's Macs are switched off for CI"
    macs = set() if why else online({"fast": env.get("CI_MAC_FAST_SEEN"), "shared": env.get("CI_MAC_SHARED_SEEN")}, now)
    waiting, hosted_busy = 0.0, 0
    if macs:
        try:
            waiting, hosted_busy = load(unfinished_jobs(env["GITHUB_REPOSITORY"], env["GITHUB_TOKEN"], env.get("GITHUB_RUN_ID")), now)
        except Exception as error:  # the queue is only a refinement: without it the Macs count as free
            print(f"could not read the queue ({error}): counting every runner as free", file=sys.stderr)
    chosen = {job: "own" for job in needed} if forced and macs else plan(needed, macs, waiting, hosted_busy)
    summary = [f"Macs taking jobs: {', '.join(sorted(macs)) or 'none'}" + (f" ({why})" if why else ""),
               f"Already waiting: {waiting:.0f} min of work on the project's Macs, {hosted_busy} macOS jobs on GitHub's runners"]
    for job in JOBS:
        place = chosen.get(job, "hosted")
        print(f"{job}_runner={json.dumps(OWN if place == 'own' else HOSTED)}")
        if job in chosen:
            summary.append(f"{JOB_NAMES[job]}: {'the project\'s Macs' if place == 'own' else 'GitHub'}")
    print("\n".join(summary), file=sys.stderr)
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a") as file:
            file.write("\n".join(f"- {line}" for line in summary) + "\n")


if __name__ == "__main__":
    main()
