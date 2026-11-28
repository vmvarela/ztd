#!/bin/sh
# Full check for the Zig product and its Zig conformance harness.
set -eu
zig=${ZIG:-zig}

"$zig" fmt --check src test build.zig
"$zig" build --release=fast
"$zig" build test
"$zig" build corpus
"$zig" build integration
