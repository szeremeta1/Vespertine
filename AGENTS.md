# AGENTS.md — Vespertine Remote (operating manual)

Every Claude Code session reads this file first and follows it for the life of the project. It is a living document: update it when architecture or workflow changes. Never remove project-specific information unless Gavin asks.

## 1. Project

Personal fork of [Vespertine](https://github.com/szeremeta1/Vespertine) (free, open-source, bit-perfect macOS music player; Swift/SwiftUI, GPL-3.0-or-later) that adds a **local-network web remote**: a small web server inside the Mac app, and a phone-friendly page (used from an iPhone) to control playback.

Owner: Gavin Ross. He does not consider himself a developer. For anything he must do himself (terminal, Xcode, git, GitHub), give **step-by-step "baby steps"** saying where things are and what to click. Shell commands: **one command per copyable block**.

Goals
- Control playback and the queue from an iPhone browser over the home network.
- Stay easy to update from upstream Vespertine.

Non-goals (unless Gavin says otherwise)
- No cloud services, accounts, tunnels or Tailscale. Offline / local network only.
- No change to audio behaviour, and no weakening of the bit-perfect check.

## 2. Standards

- Follow existing project style: naming, comment density, plain user-facing text that says what happened (see CONTRIBUTING.md).
- Minimise dependencies. The web page is zero-dependency vanilla JavaScript and native CSS; the server uses Apple frameworks only (e.g. Network.framework).
- Avoid unnecessary complexity. Production quality. Document non-obvious decisions.
- Preserve backwards compatibility unless told otherwise.
- `project.yml` is the source of truth for the Xcode project; edit it, never the generated `.xcodeproj`.
- Nothing on the audio thread may allocate, lock or call into Objective-C.
- Never weaken the bit-perfect check. Anything that changes samples must show in the signal path and turn BIT-PERFECT off. The remote must not change volume in bit-perfect mode.
- Accuracy over helpfulness: admit uncertainty rather than guess. Say so when something is untested (nothing can be built or run on the Linux workspace; Gavin builds on his Mac).
- No orange accents in any UI (Gavin's colour preference).

## 3. Upstream-friendly architecture

- All new code lives in **new files** under `App/Sources/Remote/` (server, API, web page resources). Nothing else is added elsewhere.
- Edits to existing upstream files are limited to a few small hook-ins (start the server, switch Sparkle off, add the settings switch). List every such edit in the Decision Log so upstream merges stay easy.
- The remote calls existing `PlayerController` methods (`togglePlayPause`, `next`, `previous`, `seek`, `play`, `playNext`, `addToQueue`, etc.), the same path as the media keys. It never touches the engine directly.
- Git: `origin` is Gavin's fork; add `upstream` = `https://github.com/szeremeta1/Vespertine` to pull new versions. Work on branches; keep `main` working.
- Updates: Sparkle must not point at upstream's feed in this fork (it would overwrite the remote). Turn it off for this build. Upstream changes are merged by hand, then rebuilt and re-signed (free Personal Team: 7-day re-signing).

## 4. Security

- Listen on the local network only. Require a PIN. Read-only data by default; no file access via the web API.
- No analytics, no outside requests.

## 5. Agents and models

| Role | Model | Use for | Never for |
|---|---|---|---|
| Architect | Claude Opus 5.5 (High effort) | Planning, architecture, hard debugging, performance, security, reviewing all completed work, major refactors, subtask breakdown, final technical decisions | Simple searches or straightforward coding |
| Development | Claude Sonnet 5.5 | Features, API, frontend, backend, testing, refactoring, bug fixes, production code | — |
| Utility | Claude Haiku 5.5 (Medium or High effort) | Repo search, file summaries, references, documentation, README, comments, changelogs, commit messages, release notes, simple scripts, code navigation | — |

Delegation rules
- Think before coding; plan first. Delegate whenever possible.
- Use the smallest model capable of each task.
- Run independent subtasks in parallel, then merge.

## 6. Review and workflow

1. Session start: read this file, load conventions, review the Decision Log, plan, select models, delegate.
2. **Before any change, present Gavin a plan with the proposed outcome and how to undo it, then wait for approval.**
3. The Architect reviews all completed work before it is presented.
4. Final check before reporting: re-read changes, run what can be run (`swift test` where possible), and say plainly what was not tested.
5. Commits: small, one change each; commit messages by the Utility agent.

## 7. Decision log

Format: date — decision. Rationale. Alternatives. Consequences.

- **2026-11-11 — Fork Vespertine rather than patch or rewrite.** Rationale: keeps the full app, lets upstream updates be pulled with git. Alternatives: patch file re-applied each update (fragile); building a separate player (large). Consequences: updates are manual merge + rebuild + re-sign.
- **2026-11-11 — Remote runs as a small web server inside the app, on the local network only.** Rationale: Gavin's offline/local-network preference; iPhone needs no app. Alternatives: cloud relay, Tailscale (rejected by preference). Consequences: Mac must be on and awake; macOS may show a Local Network prompt.
- **2026-11-11 — New code in new files; hook into `PlayerController`'s public methods only.** Rationale: minimal merge conflicts; same path as media keys (`setupRemoteCommands`). Consequences: remote can only do what `PlayerController` exposes.
- **2026-11-11 — Disable Sparkle in this fork.** Rationale: `SUFeedURL` points to upstream releases and would replace the modified app. Alternatives: own appcast with own EdDSA key (more work). Consequences: no automatic updates; manual merges.
- **2026-11-11 — Volume is not controlled in bit-perfect mode.** Rationale: upstream rule that bit-perfect output is never altered. Consequences: volume control may be omitted or limited in v1.
