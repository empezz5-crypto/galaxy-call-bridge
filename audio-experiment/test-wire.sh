#!/bin/sh
set -eu
P=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
B=$(mktemp "${TMPDIR:-/tmp}/gcb-wire.XXXXXX")
C=$(mktemp -d "${TMPDIR:-/tmp}/gcb-cache.XXXXXX")
trap 'rm -f "$B"; rm -rf "$C"' EXIT
swiftc -module-cache-path "$C" "$P/host/AudioWire.swift" "$P/host/PCMExperimentCore.swift" "$P/tests/main.swift" -o "$B"
"$B"
