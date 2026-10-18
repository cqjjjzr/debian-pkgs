#!/usr/bin/env -S nu --no-config-file
# Run only in the disposable test container: these tools install and remove packages.

use std/assert

def main [artifacts: path] {
    let debs = glob ($artifacts | path join '*.deb')
    assert (not ($debs | is-empty)) 'No packages to test'

    ^piuparts --distribution trixie --install-remove-install ...$debs

    # The outer container supplies isolation and is discarded after these tests.
    (
        ^autopkgtest --no-built-binaries
            --ignore-restrictions=isolation-container,breaks-testbed
            ...$debs ($artifacts | path join source) -- null
        | ignore --show-errors
    )
}
