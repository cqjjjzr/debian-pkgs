use std/assert
use ../../scripts/versions.nu read-versions

def main [] {
    let pins = read-versions ($env.FILE_PWD | path join versions.env)
    {
        title: 'NUT with USB Modbus'
        version: $"($pins.DEBIAN_SOURCE_VERSION)+usbmodbus($pins.DEBIAN_REVISION)"
        upstream_repo: $pins.UPSTREAM_REPO
        upstream_tag: $"v($pins.UPSTREAM_VERSION)"
        build_args: {DSC_URL: $pins.DSC_URL, DSC_SHA256: $pins.DSC_SHA256}
        build_type: '-B'
        # udev and systemd leave this directory behind on purge.
        piuparts_ignore: ['/usr/lib/udev/']
        maintainer: 'chariri <w@chariri.moe>'
        changelog: $"Backport to trixie with static libmodbus USB support.\n    libmodbus revision: ($pins.LIBMODBUS_REVISION)."
    } | to json --raw
}

def 'main prepare' [source: path] {
    let packaging = $env.FILE_PWD
    let pins = read-versions ($packaging | path join versions.env)
    let work = $source | path dirname
    # The image supplies the verified .dsc; dpkg-source checks the files listed in it.
    let dsc = $work | path join ($pins.DSC_URL | path basename)
    let base = $pins.DSC_URL | str replace --regex '[^/]+$' ''
    for file in (open --raw $dsc | parse --regex '(?m)^ [0-9a-f]{64} [0-9]+ (?P<name>\S+)$' | get name) {
        ^curl -fsSL -o ($work | path join $file) $"($base)($file)"
    }
    ^dpkg-source -x $dsc $source

    # libmodbus with the USB RTU backend, fetched by commit so a moving branch cannot change the build.
    let libmodbus = $source | path join libmodbus-usb
    ^git init --quiet $libmodbus
    ^git -C $libmodbus fetch --quiet --depth 1 $"https://github.com/($pins.LIBMODBUS_REPO).git" $pins.LIBMODBUS_REVISION
    ^git -C $libmodbus checkout --quiet FETCH_HEAD
    assert equal (^git -C $libmodbus rev-parse HEAD | str trim) $pins.LIBMODBUS_REVISION

    ^patch --quiet -p1 -d $source -i ($packaging | path join backport.patch)
}
