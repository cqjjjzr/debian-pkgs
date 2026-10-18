#!/usr/bin/env -S nu --no-config-file
# Build Caddy with acmedns using the checksum-verified Go compiler and pinned modules.

use std/assert
use versions.nu read-versions

# Verify or download the pinned Go toolchain archive.
def ensure-toolchain [pins: record, work: path, toolchain: path] {
    let installed = ^test -x ($toolchain | path join bin go) | complete
    if $installed.exit_code != 0 {
        let download = ^mktemp -d ($work | path join tools download.XXXXXX) | str trim
        try {
            let archive = $download | path join go.tar.gz
            (^curl --fail --location --retry 3
                $"https://go.dev/dl/go($pins.GO_VERSION).linux-amd64.tar.gz" -o $archive)
            $"($pins.GO_SHA256)  ($archive)\n" | ^sha256sum -c -
            ^tar -xzf $archive -C $download
            mv ($download | path join go) $toolchain
        } finally {
            rm --recursive --force $download
        }
    }
}

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
    assert equal (^uname -s | str trim) 'Linux' 'The bootstrap compiler requires Linux amd64'
    assert equal (^uname -m | str trim) 'x86_64' 'The bootstrap compiler requires Linux amd64'
    let root = $root | path expand
    let pins = read-versions ($root | path join versions.env)
    let work = $root | path join caddy-build
    let toolchain = $work | path join tools $"go($pins.GO_VERSION)"

    # Keep downloaded toolchains, caches, and temporary build files private.
    umask rwx------ | ignore
    mkdir ($work | path join tools) ($work | path join bin) ($work | path join out) ($work | path join tmp)
    ensure-toolchain $pins $work $toolchain

    load-env {
        PATH: ($env.PATH | prepend [($toolchain | path join bin) ($work | path join bin)])
        GOTOOLCHAIN: local, CGO_ENABLED: '0', GOOS: linux, GOARCH: amd64
        GOMAXPROCS: '2', GOFLAGS: '-p=2'
        # Proxy-only downloads avoid requiring git on the build host.
        GOPROXY: 'https://proxy.golang.org', GOSUMDB: sum.golang.org
        GOBIN: ($work | path join bin), GOPATH: ($work | path join gopath)
        GOMODCACHE: ($env.GOMODCACHE? | default ($work | path join mod-cache))
        GOCACHE: ($env.GOCACHE? | default ($work | path join build-cache))
        TMPDIR: ($work | path join tmp)
    }

    compile-caddy $pins $work
    verify-build $pins $work
}
