#!/usr/bin/env -S nu --no-config-file
# Build a package and run upstream tests and lintian.

use std/assert
use recipe-helpers.nu [collect-artifacts run-recipe]

# Generate the debian/changelog entry with pinned version and maintainer identity, above any existing history.
def write-changelog [package: string, version: string, change: string, maintainer?] {
    let maintainer = $maintainer | default (open --raw debian/control | lines
        | where {|line| $line | str starts-with 'Maintainer: ' }
        | first | str replace 'Maintainer: ' '')
    let history = if ('debian/changelog' | path exists) { [(open --raw debian/changelog)] } else { [] }
    let date = with-env {LC_ALL: C} { ^date -R | str trim }
    [
        $"($package) \(($version)\) unstable; urgency=medium"
        ''
        $"  * ($change)"
        ''
        $" -- ($maintainer)  ($date)"
        ''
        ...$history
    ] | str join "\n" | save --force debian/changelog
}

def main [package: string, --native] {
    assert ($package =~ '^[a-z0-9][a-z0-9+.-]+$') 'Invalid source package name'
    if not $native and (^id -u | str trim) == '0' {
        # Permission tests must run as a normal user, including during package builds.
        let owner = ^stat -c '%u:%g' /out | str trim
        let writable = [/build /out $env.GOMODCACHE $env.GOCACHE]
        ^chown -R builder:builder ...$writable

        try {
            ^runuser -u builder -- nu --no-config-file ($env.FILE_PWD | path join build-source.nu) $package
        } catch {|err|
            error make {msg: $err.msg}
        } finally {
            ^chown -R $owner ...$writable | ignore --show-errors
        }
        return
    }

    if $env.TARGET_ARCH? != null {
        assert equal (^dpkg --print-architecture | str trim) $env.TARGET_ARCH 'Unexpected Debian architecture. Use CONTAINER_PLATFORM to select the container platform.'
    }
    let packaging = $env.FILE_PWD | path dirname | path join packages $package
    let output = if $native { $packaging | path join build } else { '/out' }
    let recipe = run-recipe $packaging | from json
    if $native {
        assert ($recipe.native? | default false) $"Native packaging is unsupported for ($package)"
        $env.GOMODCACHE = $env.GOMODCACHE? | default ($packaging | path join .cache go-mod)
        $env.GOCACHE = $env.GOCACHE? | default ($packaging | path join .cache go-build)
        mkdir $output $env.GOMODCACHE $env.GOCACHE
    }
    let work = if $native { ^mktemp -d | str trim } else { '/build' }
    let original_directory = pwd

    try {
        let source = $work | path join $package
        run-recipe $packaging prepare $source
        cd $source
        write-changelog $package $recipe.version $recipe.changelog $recipe.maintainer?
        ^dpkg-buildpackage -us -uc ($recipe.build_type? | default '-b')

        cd $work
        let debs = glob '*.deb'
        assert (not ($debs | is-empty)) 'No Debian packages were built'

        ^lintian ...$debs

        if not $native {
            mkdir ($output | path join source)
            ^cp -a ($source | path join debian) ($output | path join source)
        }

        collect-artifacts $work $output
    } catch {|err|
        # Preserve command failures when cleanup runs another external command.
        error make {msg: $err.msg}
    } finally {
        if $native {
            cd $original_directory
            rm --recursive --force $work
        }
    }
}
