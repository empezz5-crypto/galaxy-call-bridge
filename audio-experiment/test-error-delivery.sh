#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=$(mktemp "${TMPDIR:-/tmp}/gcb-delivery.XXXXXX")
trap 'rm -f "$BIN"' EXIT
swiftc -D GCB_PROTOCOL_TEST -parse-as-library -framework SwiftUI -framework AVFoundation -framework Network -framework CoreAudio \
 "$ROOT/Sources/LocalDiagnostics.swift" "$ROOT/audio-experiment/host/AudioWire.swift" \
 "$ROOT/audio-experiment/host/PCMExperimentCore.swift" "$ROOT/audio-experiment/host/AudioExperiment.swift" \
 "$ROOT/audio-experiment/host/MicrophoneInput.swift" "$ROOT/audio-experiment/host/MicrophoneGain.swift" \
 "$ROOT/audio-experiment/tests/ProtocolDelivery.swift" -o "$BIN"
# --live sends only diagnostic opcode 0x22 after HELLO; never sends a PCM start.
"$BIN" "$@"
