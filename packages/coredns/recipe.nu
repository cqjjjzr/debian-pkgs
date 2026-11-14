use ../../scripts/recipe-helpers.nu [go-metadata prepare-go-source]

def main [] {
    go-metadata --packaging $env.FILE_PWD --title 'CoreDNS' | to json --raw
}

def 'main prepare' [source: path] {
    prepare-go-source --packaging $env.FILE_PWD --source $source
}
