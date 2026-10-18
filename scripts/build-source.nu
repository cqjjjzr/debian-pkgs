#!/usr/bin/env -S nu --no-config-file
# Build a package and run upstream tests and lintian.

use std/assert
use versions.nu read-versions

# Prepare source tree: clone upstream repository or configure Caddy build directory.
def prepare-source [package: string, pins: record, packaging: path, work: path] {
    let source = $work | path join $package
    if $package == 'caddy-with-acmedns' {
        # xcaddy assembles the source; Debian rules invoke the pinned compiler script.
        mkdir $source
        (^cp -a ($packaging | path join versions.env)
            ($env.FILE_PWD | path join build-caddy.nu)
            ($env.FILE_PWD | path join versions.nu) $source)
        {
            version: ($pins.CADDY_VERSION | str replace --regex '^v' '')
            change: $"Package upstream Caddy ($pins.CADDY_VERSION) with dns.providers.acmedns \(($pins.ACMEDNS_REVISION)\)."
        }
    } else {
        assert ($pins.UPSTREAM_VERSION =~ '^[0-9.]+$') 'Unsupported UPSTREAM_VERSION in versions.env'
        (^git clone --quiet --depth 1 --branch $"v($pins.UPSTREAM_VERSION)"
            $"https://github.com/($pins.UPSTREAM_REPO).git" $source)
        # Tag integrity check: ensure the cloned commit matches the pinned hash.
        assert equal (^git -C $source rev-parse HEAD | str trim) $pins.SOURCE_REVISION
        {
            version: $pins.UPSTREAM_VERSION
            change: $"Package upstream ($package) ($pins.UPSTREAM_VERSION) \(($pins.SOURCE_REVISION)\)."
        }
    }
}

# Generate debian/changelog entry with pinned version and maintainer identity.
def write-changelog [package: string, version: string, change: string] {
    let maintainer = open --raw debian/control | lines
        | where {|line| $line | str starts-with 'Maintainer: ' }
        | first | str replace 'Maintainer: ' ''
    let date = with-env {LC_ALL: C} { ^date -R | str trim }
    [
        $"($package) \(($version)\) unstable; urgency=medium"
        ''
        $"  * ($change)"
        ''
        $" -- ($maintainer)  ($date)"
        ''
    ] | str join "\n" | save --force debian/changelog
}

# Copy built package artifacts (.deb, .buildinfo, .changes) to the output directory.
def collect-artifacts [work: path, package: string, output: path] {
    for extension in [deb buildinfo changes] {
        let files = glob ($work | path join $"($package)_*.($extension)")
        assert (not ($files | is-empty)) $"Missing .($extension) artifacts"
        ^cp ...$files $output
    }
}

def main [package: string, --native] {
    if $package not-in ['coredns' 'acme-dns' 'caddy-with-acmedns'] {
        error make {msg: 'Unknown source package'}
    }
    if $native {
        assert equal $package 'caddy-with-acmedns' 'Native packaging is supported for Caddy only'
    }

    if not $native and (^id -u | str trim) == '0' {
        # Permission tests must run as a normal user, including during package builds.
        let owner = ^stat -c '%u:%g' /out | str trim
        let writable = [/build /out $env.GOMODCACHE $env.GOCACHE]
        ^chown -R builder:builder ...$writable

        let result = try {
            ^runuser -u builder -- nu --no-config-file ($env.FILE_PWD | path join build-source.nu) $package
                | complete
        } finally {
            ^chown -R $owner ...$writable | ignore --show-errors
        }

        print --no-newline $result.stdout
        print --stderr --no-newline $result.stderr
        assert equal $result.exit_code 0 'Package build failed'

        return
    }

    let packaging = if $native {
        $env.FILE_PWD | path dirname | path join packages $package
    } else { '/packaging' }
    let output = if $native { $packaging | path join build } else { '/out' }
    let pins = read-versions ($packaging | path join versions.env)
    if $native {
        $env.GOMODCACHE = $env.GOMODCACHE? | default ($packaging | path join .cache go-mod)
        $env.GOCACHE = $env.GOCACHE? | default ($packaging | path join .cache go-build)
        mkdir $output $env.GOMODCACHE $env.GOCACHE
    }
    let work = if $native { ^mktemp -d | str trim } else { '/build' }
    let original_directory = pwd

    try {
        let source = prepare-source $package $pins $packaging $work
        cd ($work | path join $package)
        ^cp -a ($packaging | path join debian) .
        write-changelog $package $"($source.version)-($pins.DEBIAN_REVISION)" $source.change
        ^dpkg-buildpackage -us -uc -b

        cd $work
        let debs = glob $"($package)_*.deb"
        assert (not ($debs | is-empty)) 'No Debian packages were built'

        ^lintian ...$debs

        if not $native {
            # Autopkgtest needs the generated changelog and tests, but no upstream sources.
            mkdir ($output | path join source)
            ^cp -a ($work | path join $package debian) ($output | path join source)
        }

        collect-artifacts $work $package $output
    } catch {|err|
        # Preserve command failures when cleanup runs another external command.
        error make {msg: $err.msg}
    } finally {
        if $native {
            cd $original_directory
            rm --recursive --force $work
        } else {
            # The host must be able to discard staged files after a failed test.
            let owner = ^stat -c '%u:%g' $output | str trim
            ^chown -R $owner $output | ignore --show-errors
        }
    }
}
