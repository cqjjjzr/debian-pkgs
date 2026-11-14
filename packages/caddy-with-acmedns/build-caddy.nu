#!/usr/bin/env -S nu --no-config-file
# Build Caddy with acmedns using the pinned Go toolchain and modules.

use std/assert
use versions.nu read-versions

# Compile Caddy using xcaddy with the pinned acmedns plugin.
def compile-caddy [pins: record, work: path] {
    ^go install $"github.com/caddyserver/xcaddy/cmd/xcaddy@($pins.XCADDY_VERSION)"
    (^xcaddy build $pins.CADDY_VERSION
        --with $"github.com/caddy-dns/acmedns@($pins.ACMEDNS_REVISION)"
        --output ($work | path join out caddy))
}

# Verify binary version, compiled module list, and Go buildinfo metadata.
def verify-build [pins: record, work: path] {
    let binary = $work | path join out caddy
    let version = ^$binary version
    $version | save --force ($work | path join out version.txt)
    assert ($version | str starts-with $"($pins.CADDY_VERSION) ") 'Unexpected Caddy version'

    let modules = ^$binary list-modules
    $modules | save --force ($work | path join out modules.txt)
    assert ('dns.providers.acmedns' in ($modules | lines)) 'Missing acmedns provider'
    ^go version -m $binary | save --force ($work | path join out buildinfo.txt)
    print $"Build verified; artifacts: ($work)/out"
}

def main [root: path = '.'] {
    let root = $root | path expand
    let pins = read-versions ($root | path join versions.env)
    let work = $root | path join caddy-build
    # Keep caches and temporary build files private.
    umask rwx------ | ignore
    mkdir ($work | path join bin) ($work | path join out) ($work | path join tmp)

    load-env {
        PATH: ($env.PATH | prepend ($work | path join bin))
        GOTOOLCHAIN: $"go($pins.GO_VERSION)", CGO_ENABLED: '0', GOOS: linux
        GOMAXPROCS: '2', GOFLAGS: '-p=2'
        # Proxy-only downloads avoid requiring git on the build host.
        GOPROXY: 'https://proxy.golang.org', GOSUMDB: sum.golang.org
        GOBIN: ($work | path join bin), GOPATH: ($work | path join gopath)
        GOMODCACHE: ($env.GOMODCACHE? | default ($work | path join mod-cache))
        GOCACHE: ($env.GOCACHE? | default ($work | path join build-cache))
        TMPDIR: ($work | path join tmp)
    }

    $env.GOARCH = ^go env GOHOSTARCH | str trim
    compile-caddy $pins $work
    verify-build $pins $work
}
