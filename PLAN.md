# Review of REVIEW-REMAINING.md

## Context
`REVIEW-REMAINING.md` is a carry-over checklist from an earlier review session of this
Dockerized Claude Code sandbox (`build` → image, `run` → container, `claude-cborg` → CBORG
API fallback wrapper, `settings.json` → baked-in config). This file captures the review
verdict plus an execution plan for the items to act on.

## Review verdict
The list is **accurate and well-prioritized**. All five remaining items were verified
against the source files:

- 🟠 **README** — no `README` exists in `/workspace`. Real gap, biggest usability item.
- 🟡 **Sonnet pin** — `claude-cborg:7` `=anthropic/claude-sonnet` is unversioned while
  haiku (`claude-haiku-4-5`) / opus (`claude-opus-4-8`) are pinned (`claude-cborg:6,8`).
- 🟡 **emacs → emacs-nox** — `Dockerfile:16` installs full `emacs` (pulls X11) into a
  headless image.
- 🟡 **Dead build block** — `build:8-13` is a commented-out `git describe` / version-tag block.
- 🟡 **Max output tokens** — `claude-cborg:16` `CLAUDE_CODE_MAX_OUTPUT_TOKENS=8192` is
  conservative for Opus/Sonnet.

### Material omission found during this review (added to scope)
**`run` breaks the default Pro path when `CBORG_API_KEY` is unset.**
`run:2` sets `set -u`; `run:24` expands `-e CBORG_API_KEY=$CBORG_API_KEY`. With `set -u`,
an unset variable aborts the script *before* `docker run` ever executes. So `./run` (no
args = the primary Claude Pro login path) fails with `CBORG_API_KEY: unbound variable`
unless the key is exported — contradicting the documented design that the key is
"only needed for the fallback path." (Verified `set -u` abort behavior.)
**Fix:** `-e CBORG_API_KEY="${CBORG_API_KEY:-}"` (one line, `run:24`).

## CBORG model-id scheme (resolved with user)
CBORG moved to a new aliasing scheme. Unversioned names (`anthropic/claude-sonnet`,
`anthropic/claude-haiku`, `anthropic/claude-opus`) are **aliases** that always point at the
current recommended version → convenient but a moving target. The **versioned, reproducible**
ids now live under the `google/` (Vertex AI) namespace. The existing config is therefore
inconsistent under the new scheme (Sonnet is an unversioned alias; haiku/opus are versioned
but in the now-superseded `anthropic/` namespace). **Decision: pin all three to the versioned
standard-tier `google/` ids.** A `-high` tier exists but is not used.

## Execution plan (final scope)

1. **`run:24` — guard `CBORG_API_KEY` (bug fix, do first).**
   Change `-e CBORG_API_KEY=$CBORG_API_KEY` → `-e CBORG_API_KEY="${CBORG_API_KEY:-}"`.
   Under `set -u` the bare expansion aborts `./run` (the default Pro path) when the key is
   unset; the `:-` default makes the var optional, matching the documented design.

2. **`claude-cborg:6-8` — pin all three model ids to versioned `google/` standard ids:**
   - `ANTHROPIC_DEFAULT_HAIKU_MODEL=google/claude-haiku-4-5`
   - `ANTHROPIC_DEFAULT_SONNET_MODEL=google/claude-sonnet-4-6`
   - `ANTHROPIC_DEFAULT_OPUS_MODEL=google/claude-opus-4-8`
   The two consumers (`ANTHROPIC_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL` at `claude-cborg:10-11`)
   reference these `DEFAULT_*` vars, so the change cascades — no other edits needed.

3. **`Dockerfile:16` — `emacs` → `emacs-nox`** in the apt-get install list (drops X11 deps).

4. **`build` — wire up version tagging + create initial tag.**
   - Create the first git tag: `git tag v0.0.1` (one-time, during implementation).
   - Replace the dead commented block (`build:8-13`) with active code: derive
     `VERSION=$(git -C "$SCRIPT_DIR" describe --tags --always --dirty --long)` and add
     `-t claude-workspace:"$VERSION"` alongside `-t claude-workspace:latest` in the
     `docker build` (`build:24-26`). Keep the existing `:previous` rollback logic
     (`build:15-22`) untouched. Use `git -C "$SCRIPT_DIR"` so it works regardless of CWD.

5. **README.md (new file at repo root) — minimal, security-model-focused.**
   Lead with the security/sandbox model: read-only rootfs, tmpfs `/tmp`, `npm --ignore-scripts`
   + manual official-binary download, telemetry/autoupdater disabled, pinned claude-code
   version, image-as-source-of-truth for settings (rebuild to change), persistent host-mounted
   `.claude_home` (holds the live Pro OAuth credential — gitignored). Brief usage footer:
   `./build` then `./run` (Claude Pro), `./run claude-cborg` (CBORG over-cap fallback,
   needs `CBORG_API_KEY`). Keep it short.

6. **No change:** `CLAUDE_CODE_MAX_OUTPUT_TOKENS=8192` (`claude-cborg:16`) — left as-is.

## Execution methodology (per CLAUDE.md)
- Each item is dispatched to a **subagent of appropriate complexity** (e.g. the one-line
  `run` fix and the `claude-cborg` id edits are light; the README and `build` version-tagging
  are medium). Trivial edits may be done inline.
- **Commit after each piece of work is done AND verified** — not one bulk commit.
- Commits are **authored as Claude**, with the **user added as `Co-Authored-By`**
  (`gagnonlg@stanford.edu`). Claude is the author, so no Claude co-author trailer is added.
- The carry-over `REVIEW-REMAINING.md` items get checked off / removed as each is completed.

## Verification
- **Pro path no longer aborts:** with `CBORG_API_KEY` unset in the host shell, `./run`
  (no args) launches `claude` instead of erroring `CBORG_API_KEY: unbound variable`.
- **CBORG fallback intact:** `./run claude-cborg` still sets
  `ANTHROPIC_BASE_URL=https://api.cborg.lbl.gov`, and a session responds on the pinned
  `google/claude-sonnet-4-6` id (CBORG accepts the versioned id).
- **Image builds, smaller, and version-tagged:** `./build` succeeds; `docker image ls
  claude-workspace` shows both `:latest` and a `v0.0.1-...` tag; image size drops vs the
  full-emacs build.
- **README accuracy:** instructions match actual `build`/`run` behavior.
- **Conventions honored:** `git log` shows one verified commit per item, authored as Claude
  with the `Co-Authored-By: ... <gagnonlg@stanford.edu>` trailer; `CLAUDE.md` and this plan
  are present.
