# claude-workspace

Dockerized Claude Code sandbox with a security-first design.

## Security model

- **Read-only rootfs** — the container filesystem is immutable at runtime; only `/tmp` (tmpfs) and the mounted volumes are writable.
- **npm `--ignore-scripts`** — third-party install scripts are blocked; only the official Anthropic binary is downloaded via a manual `node install.cjs` step.
- **Telemetry and autoupdater disabled** — `DISABLE_TELEMETRY`, `DISABLE_UPDATES`, and `DISABLE_AUTOUPDATER` are set in the container environment.
- **Pinned claude-code version** — the image locks `@anthropic-ai/claude-code` to an explicit version (`CLAUDE_CODE_VERSION` build arg in the Dockerfile).
- **Image as source of truth** — settings, skills, and plugins are baked into the image at build time. To change configuration, edit the source files and rebuild.
- **Persistent `.claude_home`** — host-mounted at `/root` inside the container. Holds the live Pro OAuth credential and session state. Gitignored — never committed.

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
