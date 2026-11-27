#!/bin/sh
# Full check for the Zig product plus the Go conformance harness.
set -eu
zig=${ZIG:-/Users/victor/bin/zig}
go=${GO:-/opt/homebrew/bin/go}

"$zig" build --release=fast
"$zig" build test
ZTD_BIN=./zig-out/bin/ztd "$go" test ./test/corpus -count=1
"$go" vet ./test/...
test -z "$("$go" fmt ./test/... 2>&1 | head -1)"
"$go" mod verify
