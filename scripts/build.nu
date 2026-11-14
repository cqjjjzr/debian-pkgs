#!/usr/bin/env -S nu --no-config-file
# Select, build and test packages in disposable containers with persistent Go caches.

use recipe-helpers.nu [collect-artifacts run-recipe]

def platform-args [] {
    if $env.CONTAINER_PLATFORM? == null { [] } else { [--platform $env.CONTAINER_PLATFORM] }
}

def image-name [name: string] {
    let tag = $env.CONTAINER_PLATFORM? | default 'native' | str replace --all '/' '-'
    $"localhost/($name):($tag)"
}

# Resolve target packages from CLI arguments, workflow_dispatch inputs, or discovery.
def select-packages [requested: list<string>, repository: path] {
    let available = glob ($repository | path join 'packages/*/recipe.nu')
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
def build-image [runtime: string, repository: path, package: string, recipe: record] {
    let local = $repository | path join packages $package Dockerfile
    let dockerfile = if ($local | path exists) { $local } else { $repository | path join containers go.Dockerfile }
    let args = $recipe.build_args? | default {} | transpose key value
        | each {|arg| [--build-arg $"($arg.key)=($arg.value)"] } | flatten
    (^$runtime build --pull ...(platform-args) ...$args
        --build-arg $"NU_VERSION=((version).version)"
        -t (image-name $"($package)-debian-build")
        -f $dockerfile
        ($repository | path join containers))
}

# Run the containerized build with read-only source mounts and isolated caches.
def run-build [runtime: string, repository: path, package: string, output: path] {
    let root = $repository | path join packages $package
    # Source mounts stay read-only; only build outputs and caches are writable.
    let mounts = [
        -v $"($root):/repo/packages/($package):ro"
        -v $"($repository)/scripts:/repo/scripts:ro"
        -v $"($output):/out"
        -v $"($root)/.cache/go-mod:/go/pkg/mod"
        -v $"($root)/.cache/go-build:/go-build"
    ]
    (^$runtime run --rm ...(platform-args) ...$mounts
        -e TARGET_ARCH -e GOCACHE=/go-build -e GOMODCACHE=/go/pkg/mod
        (image-name $"($package)-debian-build")
        nu --no-config-file /repo/scripts/build-source.nu $package)
}

# Build and test one package inside its container environment.
def build-single-package [runtime: string, repository: path, package: string, ci: bool] {
    let root = $repository | path join packages $package
    if $ci and ($root | path join build | path exists) {
        error make {msg: $"Build output already exists: ($package)"}
    }
    let recipe = run-recipe $root | from json
    mkdir ($root | path join build) ($root | path join .cache go-mod) ($root | path join .cache go-build)
    build-image $runtime $repository $package $recipe

    let work = ^mktemp -d | str trim
    try {
        run-build $runtime $repository $package $work

        let piuparts_ignore = $recipe.piuparts_ignore? | default []
        # Piuparts needs mounts inside its chroot. Keep caches out of this container.
        (
            ^$runtime run --rm --init --privileged ...(platform-args)
                -v $"($work):/artifacts:ro"
                -v $"($repository)/scripts:/repo/scripts:ro"
                (image-name 'debian-package-tests')
                nu --no-config-file /repo/scripts/test-package.nu /artifacts ...$piuparts_ignore
        )

        collect-artifacts $work ($root | path join build)
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
        ^$runtime build --pull ...(platform-args)
            --build-arg $"NU_VERSION=((version).version)"
            -t (image-name 'debian-package-tests')
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
