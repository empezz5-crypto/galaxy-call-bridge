#!/bin/sh
set -eu
PORT=${2:-38241}
SCREEN_CONFIRM=${3:-}
REPAIR_STALE=${4:-}
SOCKET_NAME=${5:-gcb_audio_v1}
AUTO_TRUSTED=0
case "$SOCKET_NAME" in gcb_audio_v1|gcb_control_v1) ;; *) echo 'Invalid project socket' >&2; exit 2;; esac
case "$PORT" in *[!0-9]*|'') echo 'Invalid port' >&2; exit 2;; esac
[ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || exit 2
[ -z "$REPAIR_STALE" ] || [ "$REPAIR_STALE" = "--repair-stale" ] || { echo 'Invalid repair option' >&2; exit 2; }
# Pin all helper invocations, including GUI-launched calls, to the same local ADB server.
export ADB_SERVER_SOCKET=tcp:127.0.0.1:5037
unset ANDROID_ADB_SERVER_PORT
if [ "${1:-}" = "--trusted-auto" ]; then
  HELPER_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
  RESOLVED=$(/usr/bin/python3 "$HELPER_DIR/discover-device.py") || { echo 'Trusted Galaxy unavailable; waiting for authenticated reconnect.' >&2; exit 1; }
  AUTO_TRUSTED=1
  SCREEN_CONFIRM="--trusted-tls-verified" # Helper permits pinned or TLS-advertised endpoints only.
  set -- "$RESOLVED" "${2:-38241}" "${3:-}" "${4:-}" "${5:-gcb_audio_v1}"
fi
DEVICES=$(adb devices | awk '$2=="device"{print $1}')
SERIAL=${1:-}
if [ -z "$SERIAL" ]; then
  [ "$(printf '%s\n' "$DEVICES" | wc -l | tr -d ' ')" = 1 ] || { echo 'Pass exact serial when zero or multiple devices are connected.' >&2; exit 1; }
  SERIAL=$(printf '%s\n' "$DEVICES")
fi
printf '%s\n' "$DEVICES" | grep -Fx "$SERIAL" >/dev/null || { echo "Selected serial is not an authorized ADB device on tcp:127.0.0.1:5037: $SERIAL" >&2; exit 1; }
case "$SERIAL" in
  *:*)
    case "$SERIAL" in *:5555) echo 'Refusing legacy ADB TCP port 5555.' >&2; exit 1;; esac
    if [ "$SCREEN_CONFIRM" = "--trusted-tls-verified" ]; then
      TRANSPORT='identity-pinned authenticated TLS endpoint'
    elif [ "$SCREEN_CONFIRM" = "--wireless-settings-screen-confirmed" ]; then
      TRANSPORT='previously verified Wireless debugging screen and paired-host endpoint'
    else
      SERIAL_PORT=${SERIAL##*:}
      TLS_PORT=$(adb -s "$SERIAL" shell getprop service.adb.tls.port | tr -d '\r')
      SERVICES=$(adb mdns services)
      if [ "$TLS_PORT" = "$SERIAL_PORT" ]; then
        TRANSPORT='verified TLS wireless ADB (adbd TLS port property)'
      elif printf '%s\n' "$SERVICES" | grep -F "$SERIAL" | grep -F '_adb-tls-connect._tcp' >/dev/null; then
        TRANSPORT='verified TLS wireless ADB (mDNS)'
      else
        echo 'Wireless transport encryption is unverified; confirm the exact Wireless debugging IP/port and paired-host screen before forwarding.' >&2; exit 1
      fi
    fi
    ;;
  *) TRANSPORT='USB ADB';;
esac
FORWARDS=$(adb forward --list)
EXPECTED="$SERIAL tcp:$PORT localabstract:$SOCKET_NAME"
IS_EXPECTED=0
printf '%s\n' "$FORWARDS" | grep -Fx "$EXPECTED" >/dev/null && IS_EXPECTED=1 || true
if [ "$IS_EXPECTED" = 1 ] && [ "$REPAIR_STALE" = "--repair-stale" ]; then
  adb -s "$SERIAL" forward --remove "tcp:$PORT"
  FORWARDS=$(adb forward --list)
  IS_EXPECTED=0
fi
if [ "$IS_EXPECTED" = 1 ]; then
  printf '%s loopback-only forward already ready at 127.0.0.1:%s (%s; server tcp:127.0.0.1:5037)\n' "$TRANSPORT" "$PORT" "$SERIAL"
else
  if printf '%s\n' "$FORWARDS" | awk -v target="tcp:$PORT" '$2 == target {found=1} END {exit !found}'; then
    OLD_SERIAL=$(printf '%s\n' "$FORWARDS" | awk -v target="tcp:$PORT" -v remote="localabstract:$SOCKET_NAME" '$2 == target && $3 == remote {print $1}')
    if [ "$AUTO_TRUSTED" = 1 ] && [ -n "$OLD_SERIAL" ] &&
       /usr/bin/python3 "$HELPER_DIR/discover-device.py" --owns-endpoint "$OLD_SERIAL"; then
      adb -s "$SERIAL" forward --remove "tcp:$PORT"
    else
      echo "Refusing to replace an existing different forward on tcp:$PORT." >&2
      exit 1
    fi
  fi
  adb -s "$SERIAL" forward --no-rebind "tcp:$PORT" localabstract:$SOCKET_NAME
  printf '%s loopback-only forward created at 127.0.0.1:%s (%s; server tcp:127.0.0.1:5037)\n' "$TRANSPORT" "$PORT" "$SERIAL"
fi
# --- Shizuku / companion UserService recovery (trusted-auto only) -------------------------
# Runs a command with stdout captured, killing it after $1 seconds (macOS has no `timeout`).
# Returns 124 on timeout; the output captured so far is still printed.
bounded() {
  _t=$1; shift
  _f=$(mktemp "${TMPDIR:-/tmp}/gcb-rec.XXXXXX")
  "$@" >"$_f" 2>/dev/null </dev/null &
  _p=$!; _i=0
  while kill -0 "$_p" 2>/dev/null && [ "$_i" -lt $((_t * 5)) ]; do sleep 0.2; _i=$((_i + 1)); done
  _rc=0
  if kill -0 "$_p" 2>/dev/null; then kill "$_p" 2>/dev/null || true; wait "$_p" 2>/dev/null || true; _rc=124
  else wait "$_p" || _rc=$?; fi
  tr -d '\r' <"$_f"; rm -f "$_f"; return "$_rc"
}
has_listener() { printf '%s\n' "$SOCKETS" | awk -v socket="@$SOCKET_NAME" '$NF == socket {found=1} END {exit !found}'; }
read_sockets() { SOCKETS=$(adb -s "$SERIAL" shell cat /proc/net/unix | tr -d '\r'); }
# Echoes the seconds since the last recovery attempt, or nothing when none is on record.
RECOVERY_LOCK=
recovery_age() {
  [ -d "$RECOVERY_LOCK" ] || return 0
  _m=$(stat -f %m "$RECOVERY_LOCK" 2>/dev/null) || { echo 0; return 0; }  # unreadable stamp => assume fresh
  echo $(( $(date +%s) - _m ))
}
# Safety gates: idle phone only, validated starter path, one attempt per 120 s across both ports.
# Never pairs, never `adb connect`s, never touches network settings or other forwards.
recover_shizuku() {
  [ -n "${HOME:-}" ] || return 0
  _dir="$HOME/Library/Application Support/GalaxyCallBridge"
  (umask 077; mkdir -p "$_dir") 2>/dev/null || return 0
  RECOVERY_LOCK="$_dir/shizuku-recovery.stamp"
  _age=$(recovery_age)
  if [ -n "$_age" ]; then
    [ "$_age" -ge 120 ] || return 0
    # mv is atomic: of two racing invocations only one retires the stale stamp.
    mv "$RECOVERY_LOCK" "$RECOVERY_LOCK.$$" 2>/dev/null || return 0
    rm -rf "$RECOVERY_LOCK.$$"
  fi
  (umask 077; mkdir "$RECOVERY_LOCK") 2>/dev/null || return 0
  # Every mCallState must be exactly 0; unreadable or missing output means do not touch the phone.
  _states=$(bounded 8 adb -s "$SERIAL" shell dumpsys telephony.registry | grep -o 'mCallState=[^ ,]*' || true)
  if [ -z "$_states" ] || [ -n "$(printf '%s\n' "$_states" | grep -vx 'mCallState=0' || true)" ]; then
    rm -rf "$RECOVERY_LOCK"  # nothing was touched; allow a retry once the phone is confirmed idle
    echo 'Shizuku recovery skipped: call state is not confirmed idle.' >&2; return 0
  fi
  _ps=$(bounded 8 adb -s "$SERIAL" shell ps -A || true)
  case "$_ps" in *system_server*) ;; *) rm -rf "$RECOVERY_LOCK"; echo 'Shizuku recovery skipped: process list unreadable.' >&2; return 0;; esac
  _started=no
  if ! printf '%s\n' "$_ps" | awk '$NF == "shizuku_server" {found=1} END {exit !found}'; then
    _pkg=$(bounded 10 adb -s "$SERIAL" shell dumpsys package moe.shizuku.privileged.api || true)
    _lib=$(printf '%s\n' "$_pkg" | sed -n 's/^[[:space:]]*legacyNativeLibraryDir=//p' | head -1)
    [ -n "$_lib" ] || _lib=$(printf '%s\n' "$_pkg" | sed -n 's/^[[:space:]]*nativeLibraryDir=//p' | head -1)
    case "$_lib" in
      /data/app/*moe.shizuku.privileged.api*) ;;
      *) echo 'Shizuku recovery refused: unexpected library path.' >&2; return 0;;
    esac
    case "$_lib" in *[!A-Za-z0-9_./=~+-]*|*..*) echo 'Shizuku recovery refused: unsafe library path.' >&2; return 0;; esac
    _started=yes
    bounded 20 adb -s "$SERIAL" shell "'$_lib/arm64/libshizuku.so'" >/dev/null || true
    sleep 1
  fi
  bounded 10 adb -s "$SERIAL" shell am broadcast -a com.galaxycallbridge.diagnostics.PREPARE_TUNNEL \
    -n com.galaxycallbridge.diagnostics/.TunnelMaintenanceReceiver >/dev/null || true
  printf 'Shizuku recovery attempted (started=%s)\n' "$_started"
}
read_sockets
if ! has_listener && [ "$AUTO_TRUSTED" = 1 ]; then
  recover_shizuku
  # Also covers the sibling port's invocation: wait if any recovery started within the last 40 s.
  _age=$(recovery_age)
  if [ -n "$_age" ] && [ "$_age" -lt 40 ]; then
    _n=0
    while [ "$_n" -lt 16 ]; do
      read_sockets; has_listener && break
      sleep 0.5; _n=$((_n + 1))
    done
  fi
fi
has_listener || {
  echo "Forward exists but Android UserService socket @$SOCKET_NAME is not listening." >&2
  exit 1
}
printf 'Android abstract listener @%s confirmed via read-only /proc/net/unix.\n' "$SOCKET_NAME"
