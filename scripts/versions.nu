# Read the plain KEY=value assignments shared with Debian's shell scripts.
export def read-versions [file: path] {
    open --raw $file
    | lines
    | where {|line| $line !~ '^\s*(#|$)' }
    | split column --number 2 '=' key value
    | transpose --header-row --as-record
}
