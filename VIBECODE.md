
## Deploying on Bauxite (VibeCode Compute)

This section captures operational learnings from deploying OpenClaw as a "zero-setup" Docker workload on Bauxite-style infrastructure (provision VM + run a single container). Use placeholders; do not paste real IPs/passwords/tokens into repo docs.

### Architecture (Typical)

```
Internet -> Caddy (80/443) -> OpenClaw Gateway (18789)
                          -> Provider proxy (injects real keys)
                          -> Real model API
```

- Caddy handles HTTPS (LetsEncrypt) and optional Basic Auth at the edge.
- OpenClaw serves the chat UI and calls a provider `baseUrl` that can point at a proxy layer.
- Provider proxy injects real API keys server-side (so end users never provide keys).

### Acquire vs Ready

If your deploy system separates "start container" from "deployment reachable":

- `Acquire`: creates/updates the deployment and starts/restarts the container.
- `Ready`: should be polled separately until DNS + HTTPS are live.

Do not assume "Acquire returned" implies the URL is usable.

### Browser Sandbox Image

OpenClaw's browser tool expects a separate Docker image to exist:

- `openclaw-sandbox-browser:bookworm-slim`
- built by `scripts/sandbox-browser-setup.sh` from `Dockerfile.sandbox-browser`

Common failure mode on Bauxite:

- OpenClaw runs inside Docker on the host VM.
- Browser support requires starting a second container (sidecar).
- If the browser image is missing, OpenClaw logs an instruction to build it.

Operational options:

1. Recommended: build the browser image on the host VM once (so the image exists for the runner).
2. Alternative: mount the host Docker socket into the OpenClaw container (`-v /var/run/docker.sock:/var/run/docker.sock`).
   - This effectively grants host-level control to processes in the container.
   - Only do this on single-purpose hosts where the blast radius is acceptable.

### Provider baseUrl Gotcha (Node fetch)

Node's `fetch()` rejects URLs with embedded credentials (`https://user:pass@host/...`).

- Put Basic Auth on Caddy (edge), not in provider `baseUrl`.
- Keep provider `baseUrl` credential-free and authenticate via allowlists/headers/project identity.

### Readiness Gate Gotcha (`pgrep runsv`)

Some orchestrators gate "container is up" on a check like:

`docker exec runner pgrep runsv`

Nuance: `pgrep` matches the process comm/binary name, not `argv[0]`, so `exec -a` won't satisfy it. Workaround:

```bash
cp "$(command -v sleep)" /tmp/runsv
/tmp/runsv infinity &
```

### Provisioning Lock Gotcha

If Acquire holds a per-project provisioning lock, a stuck Acquire can block retries for the entire timeout window (example: 15 minutes). Fix the stuck condition (often the readiness gate) before retrying.
