# claude-workspace

Dockerized Claude Code sandbox with a security-first design.

## Security model

- **Read-only rootfs** — the container filesystem is immutable at runtime; only `/tmp` (tmpfs) and the mounted volumes are writable.
- **npm `--ignore-scripts`** — third-party install scripts are blocked; only the official Anthropic binary is downloaded via a manual `node install.cjs` step.
- **Autoupdater disabled** — `DISABLE_UPDATES` and `DISABLE_AUTOUPDATER` are set by `launch-claude-code`. `DISABLE_TELEMETRY` is currently commented out in `launch_container` (turned off for remote control).
- **Pinned claude-code version** — the image locks `@anthropic-ai/claude-code` to an explicit version (`CLAUDE_CODE_VERSION` build arg in the Dockerfile).
- **Image as source of truth** — settings, skills, and plugins are baked into the image at build time. To change configuration, edit the source files and rebuild.
- **Centralized claude-code launch** — `launch-claude-code` is the single place that owns how `claude` is invoked: it sets the claude-code behavior env vars and appends `system-prompt-suffix.txt` (baked into the image at `/opt/config/system-prompt-suffix.txt`) to the system prompt via `--append-system-prompt`. `launch_container` and `claude-cborg` both go through it. Changing the suffix text requires `./build`.
- **Persistent `.claude_home`** — host-mounted at `/root` inside the container. Holds the live Pro OAuth credential and session state. Gitignored — never committed.
- **conda-forge environment** — Python and [ROOT](https://root.cern) (CERN's data-analysis framework) come from conda-forge, pinned in `environment.yml`. The base image is `condaforge/miniforge3` (pinned tag), which is multi-arch, so the image builds and runs natively on both Apple Silicon and x86 — no emulation, no `--platform` pin. `/workspace/venv` is gone; the conda `base` env is now the environment (delete any old venv left over from a previous build). To add or bump a package, edit `environment.yml` and rebuild — the read-only rootfs means a runtime `conda install` won't persist, consistent with "image as source of truth" above.

## Usage

### Build

```
./build
```

Builds the `claude-workspace:latest` image, plus a version-tagged variant derived from `git describe`. The previous `:latest` is preserved as `:previous` for rollback (`docker tag claude-workspace:previous claude-workspace:latest`).

### Run (Claude Pro)

```
./run
```

Launches an interactive Claude session using your Pro OAuth login. No API key required — authenticate in the browser on first use. Credentials persist in `.claude_home/`.

### Run (CBORG fallback)

```
export CBORG_API_KEY=<your-key>
./run claude-cborg
```

Routes through the CBORG API at `api.cborg.lbl.gov` using versioned `google/` model ids. Only needed when the Pro subscription is over capacity.

## Logbook (org-roam on the host)

Claude can write to an org-roam logbook kept by the Emacs server on the host, through the `logbook` MCP tools `create_entry(title)` and `append_entry(id, title, text)`. Each Claude session gets its own file in `org-roam-directory`, named `YYMMDD_CLAUDE_<title>.org`. If that name is taken, a `-1`, `-2`, … suffix is added, so an existing file is never overwritten.

```
claude ─stdio─> logbook_mcp.py (container) ─HTTP+token─> logbook-bridge (host)
       ─> emacsclient --eval "(claude-logbook-dispatch)" ─> claude-logbook.el
```

### One-time host setup

Add to your Emacs init file:

```elisp
(server-start)
(load "/path/to/claude-workspace/logbook/claude-logbook.el")
```

Then rebuild with `./build`. `./run` creates `.logbook_token` on first use, and starts `logbook/logbook-bridge` in the background if it isn't already answering on `127.0.0.1:8765`. The bridge needs `python3` on the host and keeps running after the container exits. Set `LOGBOOK_PORT` to change the port.

On a Linux host, `host.docker.internal` resolves to the docker bridge address. In that case start the bridge yourself with `--bind 172.17.0.1` (or your docker0 address).

### Session semantics

The entry is keyed to Claude Code's session id, which a `SessionStart` hook records:

| Event | Logbook entry |
|---|---|
| `/clear`, or quitting and running `./run` again | new entry (on the next `create_entry`) |
| `claude --resume` / `--continue`, compaction | same entry, continued |

Calling `create_entry` again in the same session returns the existing id. `append_entry` only accepts the current session's id.

### Security model

- **No injection into elisp.** The bridge always runs exactly `emacsclient --eval "(claude-logbook-dispatch)"`. The request goes through a private spool file (`~/.cache/claude-logbook/`, mode 700), which Emacs parses as JSON *data*. Nothing Claude supplies reaches `read`, `eval`, `intern` or org-capture template expansion. There is no shell anywhere.
- **Narrow writes.**
  - Only two operations exist.
  - Appends go only to files under `org-roam-directory` whose name contains `_CLAUDE_` and whose file-level `:ID:` matches.
  - Appends write to the file on disk without visiting it, so no mode hooks or file-local variables run. An append is refused if the file has unsaved edits in Emacs.
  - `Local Variables:` blocks in Claude's text are defanged.
- **Authenticated.** The bridge listens on loopback only and requires the bearer token in `.logbook_token`, which is gitignored and mode 600.
- Leave `org-confirm-babel-evaluate` and `org-link-elisp-confirm-function` at their defaults. Logbook text is org markup written by Claude, and those confirmations are what stop a src block or an `elisp:` link from running on a stray `C-c C-c` or click.

### Troubleshooting

- Bridge log: `.logbook_bridge.log`. Health check: `curl http://127.0.0.1:8765/health`.
- If you see "claude-logbook.el is not loaded in Emacs", the `load` line hasn't run in the server Emacs.
- Tests (in the container): `python -m unittest discover -s logbook/tests` and `emacs --batch -Q -l logbook/tests/test-claude-logbook.el -f ert-run-tests-batch-and-exit`.
