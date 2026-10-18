FROM docker.io/library/debian:trixie-slim
ARG NU_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg autopkgtest piuparts debootstrap \
    && curl -fsSL https://apt.fury.io/nushell/gpg.key -o /tmp/nushell.asc \
    && gpg --dearmor -o /usr/share/keyrings/nushell.gpg /tmp/nushell.asc \
    && echo 'deb [signed-by=/usr/share/keyrings/nushell.gpg] https://apt.fury.io/nushell/ /' \
        > /etc/apt/sources.list.d/nushell.list \
    && apt-get update && apt-get install -y --no-install-recommends "nushell=${NU_VERSION}-*" \
    && apt-mark hold nushell \
    && rm /tmp/nushell.asc

# Tests start their own daemons; package installation must not start another copy.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod 0755 /usr/sbin/policy-rc.d

WORKDIR /tmp
