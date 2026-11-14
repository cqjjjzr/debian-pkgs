#!/usr/bin/env -S nu --no-config-file
# Publish one tested package with SHA256 hashes above the upstream release notes.

use std/assert
use recipe-helpers.nu run-recipe

# Select the release assets from the binary build's .changes manifest.
def release-files [package: string, version: string] {
    let prefix = $"($package)_($version)_"
    let changes = if $env.TARGET_ARCH? != null {
        $"($prefix)($env.TARGET_ARCH).changes"
    } else {
        let manifests = glob $"($prefix)*.changes"
        assert equal ($manifests | length) 1 'Expected one .changes manifest for this version. Set TARGET_ARCH to select a Debian architecture.'
        $manifests | first | path basename
    }
    assert (($changes | path type) == 'file') $"Missing or non-regular artifact: ($changes)"
    let manifest = open --raw $changes
    let fields = $manifest | lines
    assert ($"Source: ($package)" in $fields) $"Unexpected source in ($changes)"
    assert ($"Version: ($version)" in $fields) $"Unexpected version in ($changes)"

    let target_arch = $fields | parse 'Architecture: {arch}' | get arch | first
    let stem = $"($prefix)($target_arch)"
    assert equal $changes $"($stem).changes" 'Manifest architecture differs from its filename'
    let buildinfo = $"($stem).buildinfo"
    let checksums = $fields | skip until {|line| $line == 'Checksums-Sha256:' } | skip 1
        | take while {|line| $line =~ '^\s' }
    let files = $checksums | each {|line|
        let entry = $line | parse --regex '^\s+(?<sha256>[0-9a-f]{64})\s+\d+\s+(?<name>[a-z0-9][a-zA-Z0-9.+~_-]*)$' | first
        let file = $entry.name
        assert (($file | path type) == 'file') $"Missing or non-regular artifact: ($file)"
        assert equal (^sha256sum $file | split row ' ' | first) $entry.sha256 $"Checksum mismatch: ($file)"
        if ($file | str ends-with '.deb') {
            assert equal (^dpkg-deb -f $file Version | str trim) $version
            assert equal (^dpkg-deb -f $file Architecture | str trim) $target_arch
        } else {
            assert equal $file $buildinfo 'Unexpected release asset'
        }
        $file
    }
    assert ($buildinfo in $files) 'Missing .buildinfo in manifest'
    let binary_field = $manifest | parse --regex '(?m)^Binary:[ \t]*(?<names>[^\n]*(?:\n[ \t]+[^\n]*)*)' | get names | first
    let expected = $binary_field | str trim | split row --regex '\s+' | sort
    let packages = $files | where {|file| $file | str ends-with '.deb' }
        | each {|file| ^dpkg-deb -f $file Package | str trim } | sort
    assert (not ($packages | is-empty)) 'No .deb artifacts in manifest'
    assert equal $packages $expected $"Binary packages differ from the Binary field in ($changes)"
    $files | append $changes
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
    assert ($package =~ '^[a-z0-9][a-z0-9+.-]+$') 'Invalid source package name'
    let repository = $env.GH_REPO
    let commit = $env.GITHUB_SHA
    assert (not ($repository | is-empty)) 'Set GH_REPO to the destination owner/repository'
    assert (not ($commit | is-empty)) 'Set GITHUB_SHA to the tested packaging commit'

    let root = $env.FILE_PWD | path dirname
    let recipe = run-recipe ($root | path join packages $package) | from json
    let version = $recipe.version
    let tag = $"($package)/v($version)"

    cd $artifact_dir
    let files = release-files $package $version

    # Verify that the release tag does not already exist.
    let refs = ^gh api $"repos/($repository)/git/matching-refs/tags/($tag)" | from json
    assert ($refs | where ref == $"refs/tags/($tag)" | is-empty) $"Tag already exists: ($tag)"
    let notes = release-notes $recipe.title $recipe.upstream_tag $recipe.upstream_repo $files

    # Publish the release with attached artifacts and notes.
    ($notes | ^gh release create $tag ...$files --repo $repository
        --target $commit --title $"($recipe.title) ($version)"
        --notes-file - --latest=false)
}
