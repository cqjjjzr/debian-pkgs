#!/usr/bin/env -S nu --no-config-file
# Publish one tested package with SHA256 hashes above the upstream release notes.

use std/assert
use versions.nu read-versions

# Verify existence, package name, version, and architecture of built artifacts.
def verify-artifacts [package: string, version: string, files: list<string>] {
    for file in $files {
        assert (($file | path type) == 'file') $"Missing or non-regular artifact: ($file)"
    }
    let deb = $files | first
    assert equal (^dpkg-deb -f $deb Package | str trim) $package
    assert equal (^dpkg-deb -f $deb Version | str trim) $version
    assert equal (^dpkg-deb -f $deb Architecture | str trim) 'amd64'
}

# Fetch upstream release notes and format release body with artifact SHA256 checksums.
def release-notes [title: string, tag: string, repository: string, files: list<string>] {
    let upstream = ^gh release view $tag --repo $repository --json body | from json | get body
    let body = if ($upstream | is-empty) { 'Upstream published no release notes.' } else { $upstream }
    let hashes = ^sha256sum ...$files | str trim
    [
        '## SHA256' '' '```text' $hashes '```' ''
        '## Upstream release notes' ''
        $"[($title) ($tag)]\(https://github.com/($repository)/releases/tag/($tag)\)" ''
        $body ''
    ] | str join "\n"
}

def main [package: string, artifact_dir: path] {
    let title = match $package {
        'coredns' => 'CoreDNS'
        'acme-dns' => 'acme-dns'
        'caddy-with-acmedns' => 'Caddy with acmedns'
        _ => { error make {msg: 'Unknown package'} }
    }
    let repository = $env.GH_REPO
    let commit = $env.GITHUB_SHA
    assert (not ($repository | is-empty)) 'Set GH_REPO to the destination owner/repository'
    assert (not ($commit | is-empty)) 'Set GITHUB_SHA to the tested packaging commit'

    let root = $env.FILE_PWD | path dirname
    let pins = read-versions ($root | path join packages $package versions.env)
    let upstream_tag = if $package == 'caddy-with-acmedns' { $pins.CADDY_VERSION } else { $"v($pins.UPSTREAM_VERSION)" }
    let version = $"($upstream_tag | str replace --regex '^v' '')-($pins.DEBIAN_REVISION)"
    let tag = $"($package)/v($version)"
    let files = [deb buildinfo changes] | each {|extension| $"($package)_($version)_amd64.($extension)" }

    cd $artifact_dir
    verify-artifacts $package $version $files

    # Verify that the release tag does not already exist.
    let refs = ^gh api $"repos/($repository)/git/matching-refs/tags/($tag)" | from json
    assert ($refs | where ref == $"refs/tags/($tag)" | is-empty) $"Tag already exists: ($tag)"
    let notes = release-notes $title $upstream_tag $pins.UPSTREAM_REPO $files

    # Publish the release with attached artifacts and notes.
    ($notes | ^gh release create $tag ...$files --repo $repository
        --target $commit --title $"($title) ($version)"
        --notes-file - --latest=false)
}
