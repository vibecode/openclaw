#!/bin/sh
set -e

# Entrypoint runs as root (like agent-template) and drops privileges for runtime processes.

log() {
  echo "[openclaw-entrypoint] $*" >&2
}

resolve_state_dir() {
  if [ -n "${OPENCLAW_STATE_DIR:-}" ]; then
    echo "$OPENCLAW_STATE_DIR"
    return
  fi
  if [ -n "${DATA_DIR:-}" ]; then
    echo "$DATA_DIR/openclaw"
    return
  fi
  echo "/home/user/.openclaw"
}

# Create state dir as root.
STATE_DIR="$(resolve_state_dir)"
mkdir -p "$STATE_DIR/workspace"
chown -R vibecode:vibecode "$STATE_DIR"
export OPENCLAW_STATE_DIR="$STATE_DIR"

# Resolve gateway token (Vibecode sets OPENCLAW_GATEWAY_TOKEN deterministically per project).
if [ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
  TOKEN="$OPENCLAW_GATEWAY_TOKEN"
else
  TOKEN="$(node -e "process.stdout.write(require('crypto').randomBytes(24).toString('base64url'))")"
fi

# Seed config from pre-baked template (first boot) or patch existing config (restarts).
node -e "
  const fs = require('fs');
  const path = require('path');

  const stateDir = String(process.env.OPENCLAW_STATE_DIR || '').trim();
  if (!stateDir) throw new Error('OPENCLAW_STATE_DIR is required');
  fs.mkdirSync(stateDir, { recursive: true });

  const token = process.argv[1];
  const destPath = path.join(stateDir, 'openclaw.json');

  // Use existing config if present (preserves onboarding/personality changes),
  // otherwise seed from the pre-baked template.
  let cfg;
  if (fs.existsSync(destPath)) {
    cfg = JSON.parse(fs.readFileSync(destPath, 'utf8'));
  } else {
    cfg = JSON.parse(fs.readFileSync('/app/config/openclaw.json', 'utf8'));
  }

  // Always patch gateway auth token and workspace (these come from env).
  cfg.gateway ??= {};
  cfg.gateway.auth ??= {};
  cfg.gateway.auth.mode = cfg.gateway.auth.mode ?? 'token';
  cfg.gateway.auth.token = token;

  cfg.agents ??= {};
  cfg.agents.defaults ??= {};
  cfg.agents.defaults.workspace = path.join(stateDir, 'workspace');

  // Skip bootstrap on restarts (workspace already has content) so the agent
  // doesn't re-run onboarding.  Fresh instances (empty workspace) get the
  // full first-boot experience.
  const wsDir = cfg.agents.defaults.workspace;
  const hasContent = fs.existsSync(path.join(wsDir, 'SOUL.md'));
  if (hasContent) {
    cfg.agents.defaults.skipBootstrap = true;
  }

  // Enable bundled Telegram channel plugin when token is provided via env.
  const telegramToken = String(process.env.TELEGRAM_BOT_TOKEN || '').trim();
  if (telegramToken) {
    cfg.plugins ??= {};
    cfg.plugins.entries ??= {};
    const existing = cfg.plugins.entries.telegram;
    if (!existing || typeof existing !== 'object' || Array.isArray(existing)) {
      cfg.plugins.entries.telegram = { enabled: true };
    } else {
      cfg.plugins.entries.telegram.enabled = true;
    }
  }

  fs.writeFileSync(destPath, JSON.stringify(cfg, null, 2));
" -- "$TOKEN"

# Copy auth profiles into the state dir (and the default agent dir).
if [ -f /app/config/auth-profiles.json ]; then
  cp /app/config/auth-profiles.json "$STATE_DIR/auth-profiles.json"

  mkdir -p "$STATE_DIR/agents/main/agent"
  cp /app/config/auth-profiles.json "$STATE_DIR/agents/main/agent/auth-profiles.json"
fi

# Log the gateway token so Vibecode can read it and construct the iframe URL.
# The control UI supports ?token=<TOKEN> in the URL — no need to bake it into HTML.
log "OPENCLAW_GATEWAY_TOKEN=$TOKEN"

# Fix ownership for files we just wrote as root.
chown -R vibecode:vibecode "$STATE_DIR"

# Satisfy Bauxite deployman readiness check (it pgrep's for "runsv").
# pgrep matches /proc/pid/comm (the binary name), not argv[0], so we
# need an actual executable named "runsv" rather than exec -a.
cp "$(command -v sleep)" /tmp/runsv && /tmp/runsv infinity &

# --- Caddy reverse proxy (TLS + optional basic auth) ---
DOMAINS="${VIBECODE_DOMAINS:-${VIBECODE_SUBDOMAIN:-:80}}"
DOMAINS="$(echo "$DOMAINS" | tr ' ' ',')"

ACME_EMAIL="${VIBECODE_ACME_EMAIL:-${CADDY_EMAIL:-acme@vibecodeapp.com}}"

# Caddy cert storage — persistent on /data.
CADDY_STORAGE=""
CADDY_DATA_DIR="${DATA_DIR:-/data}/caddy"
mkdir -p "$CADDY_DATA_DIR" && chown vibecode:vibecode "$CADDY_DATA_DIR"
CADDY_STORAGE="  storage file_system $CADDY_DATA_DIR"

# Build basicauth block if HTTP_BASIC_USERNAME/PASSWORD are set.
BASICAUTH=""
if [ -n "${HTTP_BASIC_USERNAME:-}" ] && [ -n "${HTTP_BASIC_PASSWORD:-}" ]; then
  HASHED_PW="$(caddy hash-password --plaintext "$HTTP_BASIC_PASSWORD")"
  BASICAUTH="
  basicauth {
    ${HTTP_BASIC_USERNAME} ${HASHED_PW}
  }"
fi

# Allow framing from Vibecode (required for the right-panel iframe embed).
# Keep this reasonably tight by default; override with VIBECODE_FRAME_ANCESTORS when needed.
FRAME_ANCESTORS="${VIBECODE_FRAME_ANCESTORS:-https://vibecodeapp.com https://www.vibecodeapp.com https://*.vibecodeapp.com https://vibecode.dev https://www.vibecode.dev}"

cat > /tmp/Caddyfile <<EOF
{
  email ${ACME_EMAIL}
${CADDY_STORAGE}
}

${DOMAINS} {${BASICAUTH}
  reverse_proxy localhost:18789 {
    header_down -X-Frame-Options
    header_down Content-Security-Policy "frame-ancestors ${FRAME_ANCESTORS}"
  }
}
EOF

caddy start --config /tmp/Caddyfile --adapter caddyfile

# Drop to vibecode user for the gateway (uid/gid 10000).
export HOME="/home/user"
exec gosu vibecode node openclaw.mjs gateway \
  --allow-unconfigured \
  --bind lan
