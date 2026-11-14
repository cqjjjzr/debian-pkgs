use std/assert
use versions.nu read-versions

export def collect-artifacts [work: path, output: path] {
    for extension in [deb buildinfo changes] {
        let files = glob ($work | path join $"*.($extension)")
        assert (not ($files | is-empty)) $"Missing .($extension) artifacts"
        ^cp ...$files $output
    }
}

# Invoke the package's recipe in a separate Nushell process.
export def run-recipe [packaging: path, ...args: string] {
    ^nu --no-config-file ($packaging | path join recipe.nu) ...$args
}

# Defaults for packages built from an upstream Go release tag.
export def go-metadata [--packaging: path, --title: string] {
    assert ($packaging != null and $title != null) 'go-metadata requires --packaging and --title'
    let pins = read-versions ($packaging | path join versions.env)
    {
        title: $title
        version: $"($pins.UPSTREAM_VERSION)-($pins.DEBIAN_REVISION)"
        upstream_repo: $pins.UPSTREAM_REPO
        upstream_tag: $"v($pins.UPSTREAM_VERSION)"
        build_args: {GO_VERSION: $pins.GO_VERSION}
        changelog: $"Package upstream ($pins.UPSTREAM_REPO | split row '/' | last) ($pins.UPSTREAM_VERSION) \(($pins.SOURCE_REVISION)\)."
    }
}

export def prepare-go-source [--packaging: path, --source: path] {
    assert ($packaging != null and $source != null) 'prepare-go-source requires --packaging and --source'
    let pins = read-versions ($packaging | path join versions.env)
    assert ($pins.UPSTREAM_VERSION =~ '^[0-9.]+$') 'Unsupported UPSTREAM_VERSION in versions.env'
    (^git clone --quiet --depth 1 --branch $"v($pins.UPSTREAM_VERSION)"
        $"https://github.com/($pins.UPSTREAM_REPO).git" $source)
    assert equal (^git -C $source rev-parse HEAD | str trim) $pins.SOURCE_REVISION
    ^cp -a ($packaging | path join debian) $source
}
