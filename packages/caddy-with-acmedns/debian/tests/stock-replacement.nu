#!/usr/bin/env -S nu --no-config-file
# Check replacement in both directions against Debian's real Caddy package.

use std/assert

def main [] {
    let version = ^dpkg-query -W '-f=${Version}' caddy-with-acmedns
    let config = '/etc/caddy/Caddyfile'
    let state = '/var/lib/caddy/package-test-state'
    let work = ^mktemp -d --tmpdir=($env.AUTOPKGTEST_TMP? | default '/tmp') caddy-stock.XXXXXX | str trim

    try {
        # Download by package name to get the real package, not our virtual Provides.
        cd $work
        ^apt-get download caddy
        let stock = glob ($work | path join 'caddy_*.deb') | first
        assert equal (^dpkg-deb -f $stock Package | str trim) 'caddy'
        ^apt-get -y -o Dpkg::Options::=--force-confold install $stock

        "\n# administrator configuration\n" | save --append $config
        'persistent state' | save $state
        let before = open --raw $config

        ^apt-get -y -o Dpkg::Options::=--force-confold install $"caddy-with-acmedns=($version)"
        let status = ^dpkg-query -W '-f=${db:Status-Status}' caddy | complete
        assert (($status.stdout | str trim) != 'installed') 'Stock Caddy is still installed'
        assert equal (open --raw $config) $before
        assert equal (open --raw $state) 'persistent state'

        (
            ^apt-get -y --reinstall -o Dpkg::Options::=--force-confold
                install $"caddy-with-acmedns=($version)"
        )
        assert equal (open --raw $config) $before
        assert equal (open --raw $state) 'persistent state'

        ^dpkg -r caddy-with-acmedns
        assert equal (open --raw $config) $before
        assert equal (open --raw $state) 'persistent state'

        ^apt-get -y -o Dpkg::Options::=--force-confold install $stock
        assert equal (open --raw $config) $before
        assert equal (open --raw $state) 'persistent state'
    } finally {
        cd /tmp
        rm --recursive --force $work
    }
}
