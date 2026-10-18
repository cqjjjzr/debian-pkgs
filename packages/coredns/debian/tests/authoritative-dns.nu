#!/usr/bin/env -S nu --no-config-file
# Check UDP/TCP answers, authority flags, and NXDOMAIN on a loopback port.

use std/assert

# Write loopback Corefile and test zone records for example.test.
def setup-zone-fixture [work: path] {
    'example.test:1053 {
    bind 127.0.0.1
    errors
    file example.zone
}
' | save ($work | path join Corefile)

    '$ORIGIN example.test.
@ 60 IN SOA ns.example.test. hostmaster.example.test. 1 3600 600 86400 60
@ 60 IN NS ns.example.test.
ns 60 IN A 192.0.2.53
www 60 IN A 192.0.2.80
' | save ($work | path join example.zone)
}

# Start CoreDNS in the background under start-stop-daemon.
def start-daemon [work: path, pidfile: path, log: path] {
    (
        ^start-stop-daemon --start --quiet --background --make-pidfile
            --pidfile $pidfile --chdir $work --no-close
            --startas /usr/bin/coredns -- -conf ($work | path join Corefile)
            o+e> $log
    )
}

# Poll loopback DNS until the server resolves the test A record.
def wait-ready [pidfile: path] {
    for attempt in 1..10 {
        if ($pidfile | path exists) {
            ^start-stop-daemon --status --pidfile $pidfile --exec /usr/bin/coredns

            let response = (
                ^dig @127.0.0.1 -p 1053 www.example.test A +short +time=1 +tries=1
                | complete
            )

            if $response.exit_code == 0 {
                assert equal ($response.stdout | str trim) '192.0.2.80'
                return
            }
        }

        sleep 1sec
    }

    error make {msg: 'CoreDNS startup timed out'}
}

# Verify TCP response, authoritative answer flags, and NXDOMAIN handling.
def verify-dns-queries [] {
    let answer = (
        ^dig +tcp @127.0.0.1 -p 1053 www.example.test A +short +time=1 +tries=1
        | str trim
    )
    assert equal $answer '192.0.2.80' 'Incorrect TCP answer'

    let soa = ^dig @127.0.0.1 -p 1053 example.test SOA +norecurse +time=1 +tries=1
    assert ($soa | str contains 'flags: qr aa;') 'Missing authoritative answer flag'

    let missing = ^dig @127.0.0.1 -p 1053 missing.example.test A +time=1 +tries=1
    assert ($missing | str contains 'status: NXDOMAIN') 'Expected NXDOMAIN'
}

# Gracefully terminate CoreDNS with SIGTERM, escalating to SIGKILL on timeout.
def stop-daemon [pidfile: path] {
    (
        ^start-stop-daemon --stop --quiet --oknodo --pidfile $pidfile
            --exec /usr/bin/coredns --retry TERM/10/KILL/5
        | ignore --show-errors
    )
}

def main [] {
    let work = ^mktemp -d --tmpdir=($env.AUTOPKGTEST_TMP? | default '/tmp') coredns.XXXXXX | str trim
    let pidfile = $work | path join coredns.pid
    let log = $work | path join server.log

    try {
        setup-zone-fixture $work
        start-daemon $work $pidfile $log
        wait-ready $pidfile
        ^start-stop-daemon --status --pidfile $pidfile --exec /usr/bin/coredns
        verify-dns-queries
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
