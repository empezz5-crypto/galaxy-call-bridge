#!/bin/sh
# Offline check of connect-local-tunnel.sh recovery gates. Uses a fake `adb` on PATH and a temp HOME;
# never contacts a phone or the real adb server.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/gcb-recovery.XXXXXX")
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/helper" "$W/home" "$W/d"
cp "$ROOT/audio-experiment/connect-local-tunnel.sh" "$W/helper/"
printf 'print("FAKE123")\n' > "$W/helper/discover-device.py"   # stub: no real adb discovery
cat > "$W/bin/adb" <<'FAKE'
#!/bin/sh
D=$FAKE_DIR
echo "$*" >> "$D/log"
[ "$1" = "-s" ] && { shift 2; }
case "$1" in
  devices) printf 'List of devices attached\nFAKE123\tdevice\n';;
  forward) [ "$2" = "--list" ] && printf 'FAKE123 tcp:38241 localabstract:gcb_audio_v1\nFAKE123 tcp:38242 localabstract:gcb_control_v1\n';;
  shell) shift
    case "$1" in
      cat) printf '0 0 0 0 0 0 /x\n'; [ -f "$D/up" ] && printf '0 0 0 0 0 0 @gcb_audio_v1\n0 0 0 0 0 0 @gcb_control_v1\n' || true;;
      dumpsys)
        if [ "$2" = telephony.registry ]; then cat "$D/calls" 2>/dev/null || true
        else printf '  legacyNativeLibraryDir=%s\n' "$(cat "$D/libdir")"; fi;;
      ps) echo 'root 1 init'; echo 'system 2 system_server'; [ -f "$D/shizuku" ] && echo 'shell 3 shizuku_server' || true;;
      am) echo "BROADCAST" >> "$D/events"; [ -f "$D/shizuku" ] && touch "$D/up" || true;;
      *) echo "STARTER $1" >> "$D/events"; touch "$D/shizuku"; echo 'info: shizuku_starter exit with 0';;
    esac;;
  *) echo "FORBIDDEN $*" >> "$D/events";;
esac
FAKE
chmod +x "$W/bin/adb"
LIB=/data/app/~~abc==/moe.shizuku.privileged.api-xyz==/lib
FAILS=0
run() { # name port socket args... ; sets OUT RC
  _port=$2; _sock=$3; shift 3
  RC=0; OUT=$(HOME="$W/home" PATH="$W/bin:/usr/bin:/bin" FAKE_DIR="$W/d" /bin/sh "$W/helper/connect-local-tunnel.sh" "$@" "$_port" --wireless-settings-screen-confirmed "" "$_sock" 2>/dev/null) || RC=$?
}
reset() { rm -rf "$W/d" "$W/home"; mkdir -p "$W/d" "$W/home"; : > "$W/d/events"; printf '%s' "$LIB" > "$W/d/libdir"; printf 'mCallState=0\nmCallState=0\n' > "$W/d/calls"; }
count() { grep -c "^$1" "$W/d/events" || true; }
expect() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (expected $3, got $2)"; FAILS=$((FAILS+1)); fi; }
STAMP="$W/home/Library/Application Support/GalaxyCallBridge/shizuku-recovery.stamp"

reset; run a 38241 gcb_audio_v1 --trusted-auto
expect "idle + shizuku dead: exit 0" "$RC" 0
expect "idle + shizuku dead: starter once" "$(count STARTER)" 1
expect "idle + shizuku dead: broadcast once" "$(count BROADCAST)" 1
case "$OUT" in *"Shizuku recovery attempted (started=yes)"*) expect "marker started=yes" 1 1;; *) expect "marker started=yes" 0 1;; esac
grep -q "STARTER '$LIB/arm64/libshizuku.so'" "$W/d/events" && expect "starter path quoted" 1 1 || expect "starter path quoted" 0 1
expect "stamp mode" "$(stat -f %Lp "$STAMP")" 700

rm -f "$W/d/up" "$W/d/shizuku"; run b 38242 gcb_control_v1 --trusted-auto   # within 120s, sibling port
expect "throttled: exit 1" "$RC" 1
expect "throttled: no second starter" "$(count STARTER)" 1
expect "throttled: no second broadcast" "$(count BROADCAST)" 1

touch -t 202001010000 "$STAMP"; run c 38241 gcb_audio_v1 --trusted-auto   # stale stamp => allowed again
expect "stale stamp: recovered" "$RC" 0
expect "stale stamp: starter again" "$(count STARTER)" 2

reset; printf 'mCallState=0\nmCallState=1\n' > "$W/d/calls"; run d 38241 gcb_audio_v1 --trusted-auto
expect "call active: exit 1" "$RC" 1
expect "call active: nothing started" "$(count STARTER)$(count BROADCAST)" 00
expect "call active: stamp released" "$([ -e "$STAMP" ] && echo held || echo free)" free

reset; : > "$W/d/calls"; run e 38241 gcb_audio_v1 --trusted-auto
expect "unreadable call state: exit 1" "$RC" 1
expect "unreadable call state: nothing started" "$(count STARTER)$(count BROADCAST)" 00

reset; touch "$W/d/shizuku"; run f 38241 gcb_audio_v1 --trusted-auto
expect "shizuku running: exit 0" "$RC" 0
expect "shizuku running: no starter" "$(count STARTER)" 0
expect "shizuku running: broadcast" "$(count BROADCAST)" 1
case "$OUT" in *"(started=no)"*) expect "marker started=no" 1 1;; *) expect "marker started=no" 0 1;; esac

reset; printf '%s' '/data/local/tmp/evil' > "$W/d/libdir"; run g 38241 gcb_audio_v1 --trusted-auto
expect "bad lib path: refused" "$(count STARTER)$(count BROADCAST)" 00
printf '%s' "/data/app/x/moe.shizuku.privileged.api-1/lib; reboot" > "$W/d/libdir"; rm -rf "$W/home"; mkdir "$W/home"; run g2 38241 gcb_audio_v1 --trusted-auto
expect "injection path: refused" "$(count STARTER)$(count BROADCAST)" 00

reset; run h 38241 gcb_audio_v1 FAKE123      # explicit serial, not --trusted-auto
expect "non-auto mode: exit 1" "$RC" 1
expect "non-auto mode: no recovery" "$(count STARTER)$(count BROADCAST)" 00
expect "no forbidden adb commands" "$(count FORBIDDEN)" 0
[ "$FAILS" = 0 ] && echo "ALL PASS" || { echo "$FAILS FAILED"; exit 1; }
