#!/bin/sh
set -eu
P=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
B=$(mktemp "${TMPDIR:-/tmp}/gcb-mic-gain.XXXXXX")
C=$(mktemp -d "${TMPDIR:-/tmp}/gcb-mic-gain-cache.XXXXXX")
trap 'rm -f "$B"; rm -rf "$C"' EXIT
swiftc -module-cache-path "$C" "$P/host/MicrophoneGain.swift" "$P/tests/MicrophoneGainChecks.swift" -o "$B"
"$B"
