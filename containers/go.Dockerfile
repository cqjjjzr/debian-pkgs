ARG GO_VERSION
ARG NU_VERSION
FROM ghcr.io/nushell/nushell:${NU_VERSION}-alpine AS nushell
FROM docker.io/library/golang:${GO_VERSION}-trixie
COPY --from=nushell /usr/bin/nu /usr/local/bin/nu
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential debhelper fakeroot golang-any git curl ca-certificates \
    lintian passwd \
    && useradd --create-home builder \
    && rm -rf /var/lib/apt/lists/*
ENV GOTOOLCHAIN=local
WORKDIR /build
