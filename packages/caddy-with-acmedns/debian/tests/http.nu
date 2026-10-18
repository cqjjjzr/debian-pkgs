#!/usr/bin/env -S nu --no-config-file
# Check the acmedns module and serve HTTP on an unprivileged loopback port.

use std/assert

# Write minimal Caddyfile with disabled admin endpoint and auto HTTPS.
def write-test-caddyfile [work: path] {
    '{
    admin off
    auto_https off
}
http://127.0.0.1:18080 {
    respond "package smoke"
}
' | save ($work | path join Caddyfile)
}

# Start Caddy in the background under start-stop-daemon.
def start-daemon [work: path, pidfile: path, log: path] {
    (
        ^start-stop-daemon --start --quiet --background --make-pidfile
            --pidfile $pidfile --no-close --startas /usr/bin/caddy
            -- run --config ($work | path join Caddyfile)
            o+e> $log
    )
}

# Poll loopback HTTP endpoint until Caddy serves the test response.
def wait-ready [pidfile: path] {
    for attempt in 1..10 {
        if ($pidfile | path exists) {
            ^start-stop-daemon --status --pidfile $pidfile --exec /usr/bin/caddy

            let response = (
                ^curl --disable --fail --silent --show-error --noproxy '*'
                    --max-time 1 http://127.0.0.1:18080
                | complete
            )

            if $response.exit_code == 0 {
                assert equal $response.stdout 'package smoke'
                return
            }
        }

        sleep 1sec
    }

    error make {msg: 'Caddy startup timed out'}
}

# Gracefully terminate Caddy with SIGTERM, escalating to SIGKILL on timeout.
def stop-daemon [pidfile: path] {
    (
        ^start-stop-daemon --stop --quiet --oknodo --pidfile $pidfile
            --exec /usr/bin/caddy --retry TERM/10/KILL/5
        | ignore --show-errors
    )
}

def main [] {
    let modules = ^/usr/bin/caddy list-modules | lines
    assert ('dns.providers.acmedns' in $modules) 'Missing acmedns module'

    let work = ^mktemp -d --tmpdir=($env.AUTOPKGTEST_TMP? | default '/tmp') caddy.XXXXXX | str trim
    let pidfile = $work | path join caddy.pid
    let log = $work | path join server.log

    # Keep autosaved configuration and certificate data inside the test directory.
    $env.XDG_CONFIG_HOME = $work | path join config
    $env.XDG_DATA_HOME = $work | path join data

    try {
        write-test-caddyfile $work
        start-daemon $work $pidfile $log
        wait-ready $pidfile
        ^start-stop-daemon --status --pidfile $pidfile --exec /usr/bin/caddy | ignore --show-errors
    } catch {|err|
        if ($log | path exists) {
            print --stderr (open --raw $log)
        }

        error make {msg: $err.msg}
    } finally {
        try {
            stop-daemon $pidfile
        } finally {
            rm --recursive --force $work
        }
    }
}
