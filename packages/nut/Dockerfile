ARG NU_VERSION
FROM ghcr.io/nushell/nushell:${NU_VERSION}-alpine AS nushell
FROM docker.io/library/debian:trixie
ARG DSC_URL
ARG DSC_SHA256
COPY --from=nushell /usr/bin/nu /usr/local/bin/nu
WORKDIR /build
# Build dependencies come from the pinned source package; libmodbus is built from source instead.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential debhelper fakeroot dpkg-dev git curl ca-certificates \
    lintian passwd autoconf automake libtool \
    && dsc="./${DSC_URL##*/}" \
    && curl -fsSL -o "$dsc" "$DSC_URL" \
    && echo "$DSC_SHA256  $dsc" | sha256sum -c - \
    && apt-get build-dep -y --arch-only "$dsc" \
    && apt-get purge -y libmodbus-dev \
    && useradd --create-home builder \
    && rm -rf /var/lib/apt/lists/*
