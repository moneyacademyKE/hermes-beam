# syntax=docker/dockerfile:1

# Minimal Hermes BEAM container. This mirrors the root Dockerfile so callers can
# use either `docker build .` or an explicit `-f docker/hermes-beam.Dockerfile`.

FROM ghcr.io/gleam-lang/gleam:v1.12.0-erlang-alpine AS build
WORKDIR /app/hermes_beam

COPY hermes_beam/gleam.toml hermes_beam/manifest.toml ./
RUN gleam deps download

COPY hermes_beam/ ./
RUN gleam build

FROM ghcr.io/gleam-lang/gleam:v1.12.0-erlang-alpine
RUN apk add --no-cache babashka ca-certificates sqlite-libs

WORKDIR /app/hermes_beam
COPY --from=build /app/hermes_beam ./

ENV HOME=/data
RUN mkdir -p /data
VOLUME ["/data"]

ENTRYPOINT ["gleam", "run"]
