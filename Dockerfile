FROM caddy:2 AS caddy

FROM node:22-bookworm@sha256:cd7bcd2e7a1e6f72052feb023c7f6b722205d3fcab7bbcbd2d1bfdab10b1e935

# Copy Caddy binary from official image for TLS termination and basic auth
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy

# Install gosu (for privilege de-escalation, same as agent-template) and
# allow Caddy to bind to privileged ports (80/443) when dropped to non-root.
RUN apt-get update && \
    apt-get install -y --no-install-recommends gosu libcap2-bin && \
    setcap 'cap_net_bind_service=+ep' /usr/local/bin/caddy && \
    apt-get purge -y libcap2-bin && apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

# Match Bauxite /data volume ownership (uid/gid 10000).
# Most deployed images run as this user, so /data is writable without needing root at runtime.
RUN groupadd --gid 10000 vibecode && \
    useradd --uid 10000 --gid vibecode --home-dir /home/user --create-home --shell /bin/bash vibecode

# Install Bun (required for build scripts)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /app

ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY ui/package.json ./ui/package.json
COPY patches ./patches
COPY scripts ./scripts

RUN pnpm install --frozen-lockfile

# Optionally install Chromium and Xvfb for browser automation.
# Build with: docker build --build-arg OPENCLAW_INSTALL_BROWSER=1 ...
# Adds ~300MB but eliminates the 60-90s Playwright install on every container start.
# Must run after pnpm install so playwright-core is available in node_modules.
ARG OPENCLAW_INSTALL_BROWSER=""
RUN if [ -n "$OPENCLAW_INSTALL_BROWSER" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xvfb && \
      node /app/node_modules/playwright-core/cli.js install --with-deps chromium && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

COPY . .
RUN pnpm build
# Force pnpm for UI build (Bun may fail on ARM/Synology architectures)
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

ENV NODE_ENV=production

# Allow non-root user to write temp files during runtime/tests.
RUN chown -R vibecode:vibecode /app

# Copy entrypoint script (runs as root, drops to 'node' for the gateway process)
COPY --chmod=0755 docker-entrypoint.sh /app/docker-entrypoint.sh

# Start gateway server via entrypoint (resolves state dir, gateway token, binds to LAN)
ENTRYPOINT ["/app/docker-entrypoint.sh"]
