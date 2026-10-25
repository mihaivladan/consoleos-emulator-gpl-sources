#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

host=${RA_HOST:-127.0.0.1}
port=${RA_PORT:-55355}
raw=/run/consoleos/pause-frame.raw
next=/run/consoleos/pause-frame.next
screenshot_dir=${SCREENSHOT_DIR:?set SCREENSHOT_DIR to the RetroArch PNG directory}
samples=${SAMPLES:-10}
helper=${PAUSE_FRAME_HELPER:-$(dirname "$0")/pause-frame-benchmark.py}

retroarch_pid=$(pgrep -xo retroarch || true)
if [[ -z $retroarch_pid ]]; then
  echo 'RetroArch is not running; launch a game before benchmarking' >&2
  exit 1
fi
if [[ "$(readlink /proc/self/ns/net)" != \
      "$(readlink "/proc/$retroarch_pid/ns/net")" ]]; then
  if [[ ${PAUSE_FRAME_NSENTERED:-0} == 1 ]]; then
    echo "network namespace mismatch; invoke with: nsenter -t $retroarch_pid -n -- $0" >&2
    exit 1
  fi
  export PAUSE_FRAME_NSENTERED=1
  exec nsenter -t "$retroarch_pid" -n -- "$0" "$@"
fi

work=$(mktemp -d /run/consoleos/pause-frame-benchmark.XXXXXX)
trap 'rm -rf "$work"' EXIT INT TERM
[[ -x $helper ]] || { echo "missing Python helper: $helper" >&2; exit 1; }

now_us() {
  local value
  value=$(date +%s%N)
  printf '%s\n' "${value:0:${#value}-3}"
}

send_reply() {
  "$helper" udp "$host" "$port" "$1" "$2"
}

send_no_reply() {
  "$helper" udp "$host" "$port" "$1" -
}

field32() {
  od -An -v -tu4 -j "$1" -N 4 "$raw" | tr -d ' '
}

field64() {
  od -An -v -tu8 -j "$1" -N 8 "$raw" | tr -d ' '
}

verify_raw() {
  local expected_generation=$1 reply=$2
  local magic version header generation width height stride format orientation payload size
  local bytes_per_pixel format_name status reply_generation reply_width reply_height reply_stride reply_format
  magic=$(dd if="$raw" bs=1 count=8 2>/dev/null)
  version=$(field32 8)
  header=$(field32 12)
  generation=$(field64 16)
  width=$(field32 24)
  height=$(field32 28)
  stride=$(field32 32)
  format=$(field32 36)
  orientation=$(field32 40)
  payload=$(field64 48)
  size=$(stat -c %s "$raw")
  [[ $magic == COSPFRAW ]]
  [[ $version == 1 && $header == 56 ]]
  [[ $generation == "$expected_generation" ]]
  case $format in
    1) bytes_per_pixel=4; format_name=RGBA8888 ;;
    2) bytes_per_pixel=2; format_name=RGB565 ;;
    *) return 1 ;;
  esac
  [[ $width -gt 0 && $height -gt 0 && $stride -eq width*bytes_per_pixel ]]
  [[ $orientation == 1 ]]
  [[ $payload -eq stride*height && $size -eq header+payload ]]
  [[ ! -e $next ]]
  read -r status reply_generation reply_width reply_height reply_stride reply_format <<<"$reply"
  [[ $status == PAUSE_FRAME_READY && $reply_generation == "$generation" ]]
  [[ $reply_width == "$width" && $reply_height == "$height" ]]
  [[ $reply_stride == "$stride" && $reply_format == "$format_name" ]]
}

capture_total_us() {
  local generation=$1 line
  line=$(journalctl -b -o cat --no-pager | \
    grep "pause_frame generation=$generation " | tail -1)
  [[ -n $line ]]
  sed -n 's/.* total_us=\([0-9][0-9]*\).*/\1/p' <<<"$line"
}

median_and_max() {
  local file=$1 median maximum
  sort -n "$file" >"$file.sorted"
  median=$(awk -v n="$samples" '
    NR == n/2 { lower=$1 }
    NR == n/2+1 { print int((lower+$1)/2) }
  ' "$file.sorted")
  maximum=$(tail -1 "$file.sorted")
  printf 'median_us=%s max_us=%s\n' "$median" "$maximum"
}

run_raw_set() {
  local scale=$1 label=$2 i generation reply total
  : >"$work/$label"
  for ((i=1; i<=samples; i++)); do
    rm -f "$raw" "$next"
    generation=$((100000 + scale*1000 + i))
    reply=$(send_reply "CONSOLEOS_PAUSE_FRAME $generation $scale" \
      "PAUSE_FRAME_READY $generation [1-9][0-9]* [1-9][0-9]* [1-9][0-9]* (RGBA8888|RGB565)")
    verify_raw "$generation" "$reply"
    total=$(capture_total_us "$generation")
    [[ $total =~ ^[0-9]+$ ]]
    printf '%s\n' "$total" >>"$work/$label"
  done
  printf '%s ' "$label"
  median_and_max "$work/$label"
}

run_png_set() {
  local i snapshot before after png
  : >"$work/png"
  for ((i=1; i<=samples; i++)); do
    snapshot="$work/png-before-$i.json"
    "$helper" snapshot "$screenshot_dir" "$snapshot"
    before=$(now_us)
    send_no_reply SCREENSHOT
    png=$("$helper" wait-png "$screenshot_dir" "$snapshot")
    [[ -s $png ]]
    after=$(now_us)
    printf '%s\n' "$((after-before))" >>"$work/png"
  done
  printf 'png_SCREENSHOT '
  median_and_max "$work/png"
}

[[ -d /run/consoleos && -d $screenshot_dir ]]
[[ $samples -eq 10 ]]

run_raw_set 1 raw_full
run_raw_set 2 raw_half_width_height

# A rejected command must not replace the last valid publication.
before_hash=$(sha256sum "$raw" | awk '{print $1}')
reply=$(send_reply 'CONSOLEOS_PAUSE_FRAME 700001 3' \
  'PAUSE_FRAME_FAILED 700001 invalid_arguments')
[[ $reply == 'PAUSE_FRAME_FAILED 700001 invalid_arguments' ]]
[[ $(sha256sum "$raw" | awk '{print $1}') == "$before_hash" ]]
[[ ! -e $next ]]
reply=$(send_reply 'CONSOLEOS_PAUSE_FRAME invalid 1' \
  'PAUSE_FRAME_FAILED 0 invalid_arguments')
[[ $reply == 'PAUSE_FRAME_FAILED 0 invalid_arguments' ]]
[[ $(sha256sum "$raw" | awk '{print $1}') == "$before_hash" ]]
[[ ! -e $next ]]

# Two captures without removing the destination exercise atomic replacement.
for generation in 800001 800002; do
  reply=$(send_reply "CONSOLEOS_PAUSE_FRAME $generation 2" \
    "PAUSE_FRAME_READY $generation [1-9][0-9]* [1-9][0-9]* [1-9][0-9]* (RGBA8888|RGB565)")
  verify_raw "$generation" "$reply"
done

run_png_set

# Optional destructive final check: close content, then prove a real capture
# failure leaves the prior valid publication untouched.
if [[ ${CHECK_NO_GAME_FAILURE:-0} == 1 ]]; then
  before_hash=$(sha256sum "$raw" | awk '{print $1}')
  send_no_reply CLOSE_CONTENT
  sleep 1
  reply=$(send_reply 'CONSOLEOS_PAUSE_FRAME 900001 1' \
    'PAUSE_FRAME_FAILED 900001 no_game')
  [[ $reply == 'PAUSE_FRAME_FAILED 900001 no_game' ]]
  [[ $(sha256sum "$raw" | awk '{print $1}') == "$before_hash" ]]
  [[ ! -e $next ]]
fi
echo 'pause-frame benchmark: PASS'
