#!/usr/bin/env python3
"""Refuses a CI job on one of the project's own Macs when it comes from a pull request the Mac should not run.

    Set on each Mac that runs a self-hosted runner for this repository: copy this file and ci-runner-job-gate.sh into
    one folder outside the runner's own folder and its work folder (so no checkout replaces them), and in the
    runner's .env file put
        ACTIONS_RUNNER_HOOK_JOB_STARTED=/absolute/path/to/that/folder/ci-runner-job-gate.sh
    then restart the runner. (The runner starts only .sh hooks, hence the two files.)

The runner starts this before every job, with the job's event at GITHUB_EVENT_PATH; a non-zero exit fails the job before
any of its steps run. scripts/ci-pick-runners.py already sends these jobs to GitHub's runners, but a pull request brings
its own copy of that script and of the workflow, so it can ask for the Macs anyway. This check is on the Mac, where the
pull request can't reach it. A job on these Macs runs as the person who uses the Mac, with everything they can read.

Refused: a pull request from another repository (a fork), a pull request opened by a bot, an event with no readable
description, and pull_request_target (which this repository never uses). Everything else runs.
"""
import json, os, sys


def refusal(event_name, event, repository):
    """Why this job must not run here, or None when it may."""
    if event_name == "pull_request_target":
        return "pull_request_target is not used in this repository"
    if not isinstance(event, dict):
        return "the job's event could not be read"
    pull = event.get("pull_request")
    if event_name.startswith("pull_request") or pull is not None:
        if not isinstance(pull, dict):
            return "the pull request could not be read"
        head = ((pull.get("head") or {}).get("repo") or {}).get("full_name")
        if not repository or not head or head.lower() != repository.lower():
            return f"a pull request from another repository ({head or 'unknown'})"
        author = pull.get("user") or {}
        if author.get("type") == "Bot" or str(author.get("login") or "").endswith("[bot]"):
            return f"a pull request opened by a bot ({author.get('login') or 'unknown'})"
    return None


def main():
    try:
        with open(os.environ["GITHUB_EVENT_PATH"]) as file:
            event = json.load(file)
    except (KeyError, OSError, ValueError):
        event = None
    why = refusal(os.environ.get("GITHUB_EVENT_NAME", ""), event, os.environ.get("GITHUB_REPOSITORY", ""))
    if why:
        print(f"::error::This Mac does not run this job: {why}. It belongs on GitHub's runners.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
