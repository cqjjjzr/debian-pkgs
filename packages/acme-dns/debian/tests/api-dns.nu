#!/usr/bin/env -S nu --no-config-file
# Test registration, authentication, UDP/TCP DNS, and persistence across restart.
# Run as root in a disposable testbed; all credentials are synthetic.

use std/assert

const config_path = '/etc/acme-dns/config.cfg'

# Send an HTTP request to the local acme-dns API and assert the expected status code.
def api [path: string, --data: record, --account: record, --expected: int = 200] {
    let headers = if $account == null {
        []
    } else {
        [-H $"X-Api-User: ($account.username)" -H $"X-Api-Key: ($account.password)"]
    }
    let payload = if $data == null {
        []
    } else {
        [--json ($data | to json --raw)]
    }

    let response = (
        ^curl --disable --silent --show-error --noproxy '*' --max-time 2
            --write-out '\n%{http_code}' ...$headers ...$payload $"http://127.0.0.1:8080($path)"
        | lines
    )
    assert equal ($response | last | into int) $expected $"Unexpected HTTP status for ($path)"

    let body = $response | drop 1 | str join "\n"
    if $expected in [200 201] and not ($body | is-empty) {
        $body | from json
    }
}

# Verify that the TXT record resolves correctly over both UDP and TCP transport.
def verify-txt [account: record, value: string] {
    for transport in [+notcp +tcp] {
        let answer = (
            ^dig @127.0.0.1 -p 5354 $account.fulldomain TXT +short +time=2 +tries=1 $transport
            | lines
        )
        assert ($'"($value)"' in $answer) $"Incorrect TXT response over ($transport)"
    }
}

# Poll the /health endpoint until the acme-dns API daemon responds with HTTP 200.
def wait-ready [pidfile: path] {
    for attempt in 1..50 {
        if ($pidfile | path exists) {
            ^start-stop-daemon --status --pidfile $pidfile

            let response = (
                ^curl --disable --silent --show-error --noproxy '*' --max-time 2
                    --output /dev/null --write-out '%{http_code}' http://127.0.0.1:8080/health
                | complete
            )

            if $response.exit_code == 0 {
                assert equal $response.stdout '200' 'Health endpoint returned an unexpected status'
                return
            }
        }

        sleep 100ms
    }

    error make {msg: 'API startup timed out'}
}

# Stop the acme-dns daemon with SIGTERM, escalating to SIGKILL on timeout.
def stop-daemon [pidfile: path] {
    try {
        (
            ^start-stop-daemon --stop --quiet --oknodo --pidfile $pidfile
                --exec /usr/bin/acme-dns --retry TERM/10
            | ignore --show-errors
        )
    } catch {|err|
        # Clean up a stuck daemon, but still fail the test for exceeding the timeout.
        (
            ^start-stop-daemon --stop --quiet --oknodo --pidfile $pidfile
                --exec /usr/bin/acme-dns --retry KILL/5
            | ignore --show-errors
        )

        error make {msg: $err.msg}
    } finally {
        rm --force $pidfile
    }
}

# Execute a test lifecycle: start daemon, test registration/auth, query DNS, and stop.
def test-cycle [registration: bool, saved: any, value: string, work: path] {
    let pidfile = $work | path join acme-dns.pid
    let log = $work | path join acme-dns.log

    try {
        (
            ^start-stop-daemon --start --quiet --background --make-pidfile --pidfile $pidfile
                --chuid acme-dns --chdir /var/lib/acme-dns --no-close
                --startas /usr/bin/acme-dns -- -c $config_path
                o+e>> $log
        )

        wait-ready $pidfile

        let account = if $registration {
            let registered = api /register --data {} --expected 201
            (
                api /update --data {subdomain: $registered.subdomain, txt: $value}
                    --account $registered
                | ignore --show-errors
            )

            $registered
        } else {
            api /register --data {} --expected 404 | ignore --show-errors
            $saved
        }

        verify-txt $account $value

        # Rejected credentials must not modify the record.
        (
            api /update --data {subdomain: $account.subdomain, txt: (random chars --length 43)}
                --account ($account | update password wrong) --expected 401
            | ignore --show-errors
        )
        verify-txt $account $value

        if not $registration {
            # Existing credentials must still work when registration is disabled.
            let replacement = random chars --length 43
            (
                api /update --data {subdomain: $account.subdomain, txt: $replacement}
                    --account $account
                | ignore --show-errors
            )

            verify-txt $account $replacement
        }

        $account
    } finally {
        stop-daemon $pidfile
    }
}

def main [] {
    # StateDirectory is created by systemd in production, but created manually for testbeds.
    ^install -d -o acme-dns -g acme-dns -m 0750 /var/lib/acme-dns

    let original = open --raw $config_path
    let config = $original | from toml
    assert equal $config.general.listen '127.0.0.1:5354'
    assert equal $config.api.ip '127.0.0.1'
    assert ($config.api.tls == 'none' and $config.api.disable_registration)
    assert equal $config.database.connection '/var/lib/acme-dns/acme-dns.db'

    let value = random chars --length 43
    let work = ^mktemp -d --tmpdir=($env.AUTOPKGTEST_TMP? | default '/tmp') acme-dns.XXXXXX | str trim

    try {
        # Cycle 1: Enable registration to create an account and write a TXT record.
        $original
            | str replace 'disable_registration = true' 'disable_registration = false'
            | save --force $config_path
        let account = test-cycle true null $value $work

        # Cycle 2: Disable registration and restart; the stored record and credentials must persist.
        $original | save --force $config_path
        test-cycle false $account $value $work | ignore --show-errors

        # Keep a real database and edited config across reinstall and removal.
        "\n# administrator configuration\n" | save --append $config_path
        let config = open --raw $config_path
        let database = ^sha256sum /var/lib/acme-dns/acme-dns.db | str trim
        let version = ^dpkg-query -W '-f=${Version}' acme-dns

        (
            ^apt-get -y --reinstall -o Dpkg::Options::=--force-confold
                install $"acme-dns=($version)"
        )
        assert equal (open --raw $config_path) $config
        assert equal (^sha256sum /var/lib/acme-dns/acme-dns.db | str trim) $database

        ^dpkg -r acme-dns
        assert equal (open --raw $config_path) $config
        assert equal (^sha256sum /var/lib/acme-dns/acme-dns.db | str trim) $database
    } catch {|err|
        let log = $work | path join acme-dns.log
        if ($log | path exists) {
            print --stderr (open --raw $log)
        }

        error make {msg: $err.msg}
    } finally {
        $original | save --force $config_path
        rm --recursive --force $work
    }
}
