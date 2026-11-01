# syntax=docker/dockerfile:1
#
# Decaynet — SvelteKit app (adapter-node) + a small migration runner.
# SPDX-License-Identifier: AGPL-3.0-or-later
#
#   docker build -t decaynet .                     # app image (default = last stage)
#   docker build -t decaynet-migrate --target migrate .

# Base images are overridable, e.g. to use a mirror when Docker Hub rate-limits:
#   --build-arg NODE_IMAGE=public.ecr.aws/docker/library/node:22-alpine
#   --build-arg PG_IMAGE=public.ecr.aws/docker/library/postgres:17-alpine
ARG NODE_IMAGE=node:22-alpine
ARG PG_IMAGE=postgres:17-alpine

# ---------------------------------------------------------------- dependencies
FROM ${NODE_IMAGE} AS deps
WORKDIR /app
COPY package.json package-lock.json .npmrc ./
# --ignore-scripts: skips the Supabase CLI binary download (not needed in the image).
# Behind a TLS-intercepting proxy, pass its CA:  --secret id=ca,src=/path/to/ca.pem
RUN --mount=type=secret,id=ca,required=false \
    if [ -f /run/secrets/ca ]; then export NODE_EXTRA_CA_CERTS=/run/secrets/ca; fi; \
    npm ci --ignore-scripts --no-audit --no-fund

# ---------------------------------------------------------------- build
FROM deps AS build
COPY . .
RUN npx svelte-kit sync && npm run build && npm prune --omit=dev --ignore-scripts

# ---------------------------------------------------------------- migrations
# Applies supabase/migrations/*.sql to a Supabase Postgres (and optionally the
# seed), recording versions in supabase_migrations.schema_migrations so it
# interoperates with `supabase db push`.
FROM ${PG_IMAGE} AS migrate
WORKDIR /migrations
COPY supabase/migrations ./migrations
COPY supabase/seed.sql ./seed.sql
COPY docker/migrate.sh /usr/local/bin/decaynet-migrate
RUN chmod +x /usr/local/bin/decaynet-migrate
ENTRYPOINT ["decaynet-migrate"]

# ---------------------------------------------------------------- runtime
FROM ${NODE_IMAGE} AS runtime
LABEL org.opencontainers.image.title="Decaynet" \
      org.opencontainers.image.description="Time-machine map and regional history wiki" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.source="https://github.com/CthulhuOnIce/Decaynet"
ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=3000 \
    BODY_SIZE_LIMIT=25M
WORKDIR /app
COPY --from=build --chown=node:node /app/build ./build
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node package.json LICENSE ./
# `docker run --rm <image> generate-secrets` prints fresh stack secrets (.env lines)
COPY docker/generate-secrets.mjs /usr/local/lib/decaynet/generate-secrets.mjs
RUN printf '#!/bin/sh\nexec node /usr/local/lib/decaynet/generate-secrets.mjs "$@"\n' > /usr/local/bin/generate-secrets \
 && chmod +x /usr/local/bin/generate-secrets
USER node
EXPOSE 3000
# 127.0.0.1 (not localhost, which may resolve to ::1 where nothing listens)
HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=5 \
  CMD wget -qO- "http://127.0.0.1:${PORT}/healthz" >/dev/null || exit 1
CMD ["node", "build"]
