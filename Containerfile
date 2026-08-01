# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the builder image
#     E.g.: docker.io/hexpm/elixir:1.20.2-erlang-29.0.3-debian-trixie-20260713-slim
#   - https://hub.docker.com/_/debian/tags?name=trixie-20260713-slim - for the runner image
#     E.g.: docker.io/debian:trixie-20260713-slim
#
# Find builder and runner images on Docker Hub or on Hex's Build Server (Bob).
# We recommend using Bob's Web UI to find recent tags:
#
#   - https://bob.hex.pm/docker
#
# We suggest using the same Debian version for both the builder and runner images.
#
# We suggest Debian/Ubuntu instead of Alpine to avoid production compatibility issues
# (such as DNS resolution failures, and dynamically linked NIFs/precompiled binaries).
#
# For finding packages in Debian, search on https://packages.debian.org/.
#
# Build and run with Podman:
#
#   podman build -t afterlife .
#   podman volume create afterlife-data
#   podman run -d --name afterlife --init -p 4000:4000 \
#     -v afterlife-data:/data \
#     --env-file /etc/afterlife/env \
#     afterlife
#
# Required env vars — the release raises at boot without them, rather
# than failing at the first send or write (see config/runtime.exs):
# SECRET_KEY_BASE, CLOAK_KEY, DATABASE_PATH, SMTP_RELAY.
# Optional: SMTP_PORT (587), SMTP_USER, SMTP_PASS, PHX_HOST, PORT,
# POOL_SIZE, EMAIL_FROM, HEARTBEAT_URL, DNS_CLUSTER_QUERY.
#
# Keep secrets in an --env-file with mode 0600, not in the run command
# where they'd land in shell history and `podman inspect`.
#
# CLOAK_KEY decrypts every stored message. Back it up somewhere other
# than the host running this container: lose it and the messages are
# unrecoverable ciphertext, whatever happens to the database.
#
# The database is SQLite, so /data MUST be a real volume — without the
# -v above it lands in the container's writable layer and is destroyed
# along with the container. Migrations run automatically at boot
# (Afterlife.Application starts Ecto.Migrator when RELEASE_NAME is set).

ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=29.0.3
ARG DEBIAN_VERSION=trixie-20260713-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force \
  && mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv

COPY lib lib

# Compile the release
RUN mix compile

COPY assets assets

# compile assets
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE} AS final

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# C.UTF-8 is built into glibc, so we skip the `locales` package and the
# locale-gen step the Phoenix generator emits — together about 18MB for
# a UTF-8 locale we already have. The app formats dates itself via
# Calendar.strftime (pure Elixir), so nothing here reads system locale
# data; UTF-8 is all the BEAM needs for filename/IO encoding.
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# Mount point for the SQLite database. Created here (rather than left to
# the volume driver) so it exists and is writable by `nobody` even on the
# first boot, before any migration has run.
RUN mkdir -p /data && chown nobody:root /data

# set runner ENV
ENV MIX_ENV="prod"
ENV DATABASE_PATH="/data/afterlife.db"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/afterlife ./

USER nobody

# If using an environment that doesn't automatically reap zombie processes, it is
# advised to add an init process such as tini via `apt-get install`
# above and adding an entrypoint. See https://github.com/krallin/tini for details
# ENTRYPOINT ["/tini", "--"]

CMD ["/app/bin/server"]
