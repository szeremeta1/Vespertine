# Isolation audit

Every tool call each clean-room agent made, checked against its brief's rules (see `tools/audit_runs.py`). The full call logs are in `tool-calls/`, the agents' final reports in `reports/`.

| Agent | Model(s) | Tool calls | By tool | Isolation |
|---|---|---|---|---|
| dop-pack-A | claude-opus-5-5 | 33 | Bash 12, Edit 12, Read 5, SubagentHandback 1, Write 3 | **1 problem(s)** |
| dop-pack-B | claude-opus-5-5 | 9 | Bash 3, Read 2, SubagentHandback 1, Write 3 | clean |
| dop-pack-C | claude-opus-5-5 | 14 | Bash 6, Edit 1, Read 2, SubagentHandback 1, Write 4 | clean |
| dop-stream-A | claude-opus-5-5 | 70 | Bash 34, Edit 20, Grep 1, Read 9, SubagentHandback 2, Write 4 | **1 problem(s)** |
| dop-stream-B | claude-opus-5-5 | 24 | Bash 9, Edit 7, Read 3, SubagentHandback 1, Write 4 | clean |
| dop-stream-C | claude-opus-5-5 | 54 | Bash 19, Edit 26, Read 5, SubagentHandback 1, Write 3 | clean |
| pcm-stream-A | claude-opus-5-5 | 113 | Bash 34, Edit 60, Read 14, SubagentHandback 1, Write 4 | **2 problem(s)** |
| pcm-stream-B | claude-opus-5-5 | 20 | Bash 9, Edit 4, Read 2, SubagentHandback 1, Write 4 | clean |
| pcm-stream-C | claude-opus-5-5 | 37 | Bash 17, Edit 11, Read 4, SubagentHandback 1, Write 4 | clean |
| rate-A | claude-opus-5-5 | 23 | Bash 10, Edit 4, Read 4, SubagentHandback 1, Write 4 | clean |
| rate-B | claude-opus-5-5 | 17 | Bash 7, Edit 3, Read 2, SubagentHandback 1, Write 4 | clean |
| rate-B2 | claude-sonnet-5-5 | 15 | Bash 5, Edit 4, Read 2, SubagentHandback 1, Write 3 | clean |
| rate-C | claude-opus-5-5 | 25 | Bash 13, Edit 4, Read 4, SubagentHandback 1, Write 3 | clean |
| verdict-A | claude-opus-5-5 | 37 | Bash 12, Edit 12, Read 4, SubagentHandback 2, Write 7 | clean |
| verdict-B | claude-opus-5-5 | 13 | Bash 6, Edit 1, Read 2, SubagentHandback 1, Write 3 | clean |
| verdict-B2 | claude-sonnet-5-5 | 9 | Bash 3, Edit 1, Read 2, SubagentHandback 1, Write 2 | clean |
| verdict-C | claude-opus-5-5 | 23 | Bash 13, Edit 3, Read 3, SubagentHandback 1, Write 3 | clean |
| dst-A | claude-opus-5-5 | 46 | Bash 22, Edit 12, Read 5, SubagentHandback 1, Write 6 | **1 problem(s)** |
| dst-C | claude-opus-5-5 | 18 | Bash 8, Edit 3, Read 2, SubagentHandback 1, Write 4 | clean |
| carrier-scan | claude-opus-5-5 | 77 | Bash 54, Edit 12, Read 4, SubagentHandback 1, Write 6 | **1 problem(s)** |

### dop-pack-A

- Bash outside the sandbox (paths outside the workspace: /dev/null):

  ```
  cd /srv/cleanroom/dop-pack-A/harness/Sources/SpecChecks && python3 - <<'EOF' 2>/dev/null || echo "no python on host side; will edit with Edit tool"
  EOF
  true
  ```

  What came back: `(Bash completed with no output)`

### dop-stream-A

- tool Grep used: {"pattern": "static func check\\(|static func sameFrame|frameBase \\+= frames", "path": "/srv/cleanroom/dop-stream-A/harness/Sources/SpecChecks/DoPStreamChecks.swift", "output_mode": "content"}

  What came back: `1168: static func sameFrame(_ r: [UInt32], _ g: [UInt32], _ base: Int, _ channels: Int) -> Bool { 1185: static func check(_ maker: DSMaker, _ checker: Checker, name: String, channels: Int, firstMarker: UInt8, salt: Int, ops: [DSOp]) { 1213: frameBase += frames`

### pcm-stream-A

- Bash outside the sandbox (paths outside the workspace: none):

  ```
  cd /srv/cleanroom/pcm-stream-A && python3 - <<'EOF' 2>&1 || echo "no python on host side"
  EOF
  echo done
  ```

  What came back: `error: Permission for this action was denied by the Claude Code auto mode classifier. Reason: [Containment Escape]. If you have other tasks that don't depend on this action, continue working on those. IMPORTANT: You *may* attempt to accomplish this action using other tools that might naturally be used to a`
- Bash outside the sandbox (paths outside the workspace: /dev/null, /work/bench.swift.txt):

  ```
  mkdir -p /dev/null 2>/dev/null; swiftbox /srv/cleanroom/pcm-stream-A "mkdir -p harness/Sources/Scratch && cat > /work/bench.swift.txt <<'EOF'
  placeholder
  EOF
  rm /work/bench.swift.txt; echo ok"
  ```

  What came back: `ok`

### dst-A

- Bash outside the sandbox (paths outside the workspace: /dev/null):

  ```
  cd /srv/cleanroom/dst-A/harness/Sources/Scratch && python3 - <<'EOF' 2>/dev/null || echo "no python on host; will edit via Edit tool"
  EOF
  ```

  What came back: `error: Permission for this action was denied by the Claude Code auto mode classifier. Reason: [Auto-Mode Bypass]. If you have other tasks that don't depend on this action, continue working on those. IMPORTANT: You *may* attempt to accomplish this action using other tools that might naturally be used to acc`

### carrier-scan

- Bash outside the sandbox (paths outside the workspace: /dev/null):

  ```
  mkdir -p /srv/cleanroom/carrier-scan/dev 2>/dev/null; echo ok
  ```

  What came back: `error: Permission for this action was denied by the Claude Code auto mode classifier. Reason: [Auto-Mode Bypass]. If you have other tasks that don't depend on this action, continue working on those. IMPORTANT: You *may* attempt to accomplish this action using other tools that might naturally be used to acc`
