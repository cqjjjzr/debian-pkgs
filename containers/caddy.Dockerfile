ARG NU_VERSION
FROM ghcr.io/nushell/nushell:${NU_VERSION}-alpine AS nushell
FROM docker.io/library/debian:trixie-slim
COPY --from=nushell /usr/bin/nu /usr/local/bin/nu
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential debhelper fakeroot curl ca-certificates lintian passwd \
    && useradd --create-home builder \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
