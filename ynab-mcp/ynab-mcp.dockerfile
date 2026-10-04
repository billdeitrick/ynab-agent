# syntax=docker/dockerfile:1
# ynab-mcp-server publishes GitHub releases as tags with no binary assets,
# so the release's source is the artifact: fetched by the commit the
# release tag pointed at (a tag can be moved; a commit cannot), built,
# pruned to production dependencies, and shipped under /opt with its own
# Node so the overlay does not depend on the base image's Node version
# (the server requires >= 22).
FROM node:24-bookworm-slim AS build
ARG YNAB_MCP_VERSION
ARG YNAB_MCP_COMMIT
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN set -eux; \
    curl -fsSL "https://codeload.github.com/calebl/ynab-mcp-server/tar.gz/${YNAB_MCP_COMMIT}" \
      | tar -xz --strip-components=1; \
    test "$(node -p 'require("./package.json").version')" = "${YNAB_MCP_VERSION}"

# Built exactly as published at that commit. Read-only access is the
# network policy's job (GET-only at the proxy), not a change to this code.
# --ignore-scripts skips `prepare`, so the build runs once, explicitly.
RUN npm ci --ignore-scripts \
 && npm run build \
 && npm prune --omit=dev

RUN set -eux; \
    mkdir -p /out/opt/ynab-mcp-server/app /out/opt/ynab-mcp-server/bin /out/usr/local/bin; \
    cp -a package.json dist node_modules /out/opt/ynab-mcp-server/app/; \
    cp /usr/local/bin/node /out/opt/ynab-mcp-server/bin/node

# The wrapper pins the bundled Node. The token default covers an MCP client
# that spawns the server without the sandbox environment: the proxy sets
# the real Authorization header on api.ynab.com either way, but the server
# refuses to start its tools when the variable is empty.
COPY --chmod=755 <<'EOF' /out/usr/local/bin/ynab-mcp-server
#!/bin/sh
: "${YNAB_API_TOKEN:=proxy-managed}"
export YNAB_API_TOKEN
exec /opt/ynab-mcp-server/bin/node /opt/ynab-mcp-server/app/dist/index.js "$@"
EOF

RUN chown -R 0:0 /out

# The overlay: the server and its runtime, touching nothing under /home.
FROM scratch
COPY --from=build /out /
