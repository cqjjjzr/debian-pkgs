#!/usr/bin/env -S nu --no-config-file
# Select, build and test packages in disposable containers with persistent Go caches.

use versions.nu read-versions

# Resolve target packages from CLI arguments, workflow_dispatch inputs, or discovery.
def select-packages [requested: list<string>, repository: path] {
    let available = glob ($repository | path join 'packages/*/versions.env')
        | path dirname | path basename | sort
    let selected = if not ($requested | is-empty) {
        $requested
    } else if ($env.GITHUB_EVENT_NAME? | default '') == 'workflow_dispatch' {
        let inputs = $env.SELECTED_INPUTS | from json
        $available | where {|package| ($inputs | get -o $package) == true }
    } else {
        $available
    }
    if ($selected | is-empty) {
        error make {msg: 'Select at least one package'}
    }
    for package in $selected {
        if $package not-in $available {
            error make {msg: $"Unknown package: ($package)"}
        }
    }
    $selected
}

# Build the disposable container image tailored for the package.
def build-image [runtime: string, repository: path, package: string, pins: record] {
    let dockerfile = if $package == 'caddy-with-acmedns' { 'caddy' } else { 'go' }
    let args = if $package == 'caddy-with-acmedns' {
        []
    } else {
        [--build-arg $"GO_VERSION=($pins.GO_VERSION)"]
    }
    (^$runtime build --pull --platform linux/amd64 ...$args
        --build-arg $"NU_VERSION=((version).version)"
        -t $"localhost/($package)-debian-build"
        -f ($repository | path join containers $"($dockerfile).Dockerfile")
        ($repository | path join containers))
}

# Run the containerized build with read-only source mounts and isolated caches.
def run-build [runtime: string, repository: path, package: string, output: path] {
    let root = $repository | path join packages $package
    # Source mounts stay read-only; only build outputs and caches are writable.
    let mounts = [
        -v $"($root):/packaging:ro"
        -v $"($repository)/scripts:/shared:ro"
        -v $"($output):/out"
        -v $"($root)/.cache/go-mod:/go/pkg/mod"
        -v $"($root)/.cache/go-build:/go-build"
    ]
    (^$runtime run --rm --platform linux/amd64 ...$mounts
        -e GOCACHE=/go-build -e GOMODCACHE=/go/pkg/mod
        $"localhost/($package)-debian-build"
        nu --no-config-file /shared/build-source.nu $package)
}

# Build and test one package inside its container environment.
def build-single-package [runtime: string, repository: path, package: string, ci: bool] {
    let root = $repository | path join packages $package
    if $ci and ($root | path join build | path exists) {
        error make {msg: $"Build output already exists: ($package)"}
    }
    let pins = read-versions ($root | path join versions.env)
    mkdir ($root | path join build) ($root | path join .cache go-mod) ($root | path join .cache go-build)
    build-image $runtime $repository $package $pins

    let work = ^mktemp -d | str trim
    try {
        run-build $runtime $repository $package $work

        # Piuparts needs mounts inside its chroot. Keep caches out of this container.
        (
            ^$runtime run --rm --privileged --platform linux/amd64
                -v $"($work):/artifacts:ro"
                -v $"($repository)/scripts:/shared:ro"
                localhost/debian-package-tests
                nu --no-config-file /shared/test-package.nu /artifacts
        )

        for extension in [deb buildinfo changes] {
            let files = glob ($work | path join $"*.($extension)")
            ^cp ...$files ($root | path join build)
        }
    } finally {
        rm --recursive --force $work
    }
}

# Restore cache directory ownership to host user when running under CI.
def restore-cache-permissions [repository: path] {
    let owner = $"(^id -u | str trim):(^id -g | str trim)"
    for cache in (glob ($repository | path join 'packages/*/.cache')) {
        ^sudo chown -R $owner $cache
    }
}

def main [...requested: string] {
    let repository = $env.FILE_PWD | path dirname
    let packages = select-packages $requested $repository
    let runtime = $env.CONTAINER_RUNTIME? | default 'podman'
    let ci = $env.GITHUB_ACTIONS? == 'true'
    if $ci {
        $"packages=($packages | to json --raw)\n" | save --append $env.GITHUB_OUTPUT
    }

    (
        ^$runtime build --pull --platform linux/amd64
            --build-arg $"NU_VERSION=((version).version)"
            -t localhost/debian-package-tests
            -f ($repository | path join containers test.Dockerfile)
            ($repository | path join containers)
    )

    mut status = 0
    try {
        for package in $packages {
            let ok = try {
                build-single-package $runtime $repository $package $ci
                true
            } catch {|err|
                print --stderr $err.msg
                false
            }
            if not $ok { $status = 1 }
        }
    } finally {
        if $ci {
            restore-cache-permissions $repository
        }
    }
    exit $status
}
