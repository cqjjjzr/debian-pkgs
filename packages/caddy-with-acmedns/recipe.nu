use versions.nu read-versions

def main [] {
    let pins = read-versions ($env.FILE_PWD | path join versions.env)
    {
        title: 'Caddy with acmedns'
        version: $"($pins.CADDY_VERSION | str replace --regex '^v' '')-($pins.DEBIAN_REVISION)"
        upstream_repo: $pins.UPSTREAM_REPO
        upstream_tag: $pins.CADDY_VERSION
        build_args: {GO_VERSION: $pins.GO_VERSION}
        native: true
        changelog: $"Package upstream Caddy ($pins.CADDY_VERSION) with dns.providers.acmedns \(($pins.ACMEDNS_REVISION)\)."
    } | to json --raw
}

def 'main prepare' [source: path] {
    mkdir $source
    let packaging = $env.FILE_PWD
    (^cp -aH ($packaging | path join debian) ($packaging | path join build-caddy.nu)
        ($packaging | path join versions.env) ($packaging | path join versions.nu) $source)
}
