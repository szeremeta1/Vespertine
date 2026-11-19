#!/bin/bash
# The job-started hook of a self-hosted runner on one of the project's own Macs (the runner only starts .sh hooks):
# runs ci-runner-job-gate.py, which sits beside it, and fails the job when that refuses it. See that file.
set -euo pipefail
exec /usr/bin/python3 -I "$(cd "$(dirname "$0")" && pwd)/ci-runner-job-gate.py"
