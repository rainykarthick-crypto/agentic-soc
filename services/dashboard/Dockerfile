# =============================================================================
# SOC dashboard image
# =============================================================================
# Replaces the upstream Agentic-SOC dashboard, which loaded React, ReactDOM and
# Babel from cdnjs and compiled JSX in the browser. For a local-first stack that
# is the wrong trade twice over: it fetches its UI framework from the internet,
# and it renders nothing at all if cdnjs is unreachable.
#
# This image is a static file plus an nginx config. No CDN, no build step, no
# runtime compiler.
# =============================================================================
FROM nginx:alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD wget -qO- http://127.0.0.1/healthz >/dev/null 2>&1 || exit 1
