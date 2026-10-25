#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

host=${RA_HOST:-127.0.0.1}
port=${RA_PORT:-55355}
raw=/run/consoleos/pause-frame.raw
next=/run/consoleos/pause-frame.next
screenshot_dir=${SCREENSHOT_DIR:?set SCREENSHOT_DIR to the RetroArch PNG directory}
samples=${SAMPLES:-10}
work=$(mktemp -d /run/consoleos/pause-frame-benchmark.XXXXXX)
trap 'rm -rf "$work"' EXIT INT TERM

now_us() {
  local value
  value=$(date +%s%N)
  printf '%s\n' "${value:0:${#value}-3}"
}

send_reply() {
  local command=$1 reply
  exec 3<>"/dev/udp/$host/$port"
  printf '%s\n' "$command" >&3
  if ! IFS= read -r -t 5 reply <&3; then
    exec 3>&- 3<&-
    echo "no reply for: $command" >&2
    return 1
  fi
  exec 3>&- 3<&-
  printf '%s\n' "$reply"
}

send_no_reply() {
  printf '%s\n' "$1" >"/dev/udp/$host/$port"
}

field32() {
  od -An -v -tu4 -j "$1" -N 4 "$raw" | tr -d ' '
}

field64() {
  od -An -v -tu8 -j "$1" -N 8 "$raw" | tr -d ' '
}

verify_raw() {
  local expected_generation=$1
  local magic version header generation width height stride format orientation payload size
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
  [[ $width -gt 0 && $height -gt 0 && $stride -eq width*4 ]]
  [[ $format == 1 && $orientation == 1 ]]
  [[ $payload -eq stride*height && $size -eq header+payload ]]
  [[ ! -e $next ]]
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
    reply=$(send_reply "CONSOLEOS_PAUSE_FRAME $generation $scale")
    [[ $reply == "PAUSE_FRAME_READY $generation "*" RGBA8888" ]]
    verify_raw "$generation"
    total=$(capture_total_us "$generation")
    [[ $total =~ ^[0-9]+$ ]]
    printf '%s\n' "$total" >>"$work/$label"
  done
  printf '%s ' "$label"
  median_and_max "$work/$label"
}

run_png_set() {
  local i marker before after png
  : >"$work/png"
  for ((i=1; i<=samples; i++)); do
    marker="$work/png-marker-$i"
    touch "$marker"
    before=$(now_us)
    send_no_reply SCREENSHOT
    png=
    for _ in {1..500}; do
      png=$(find "$screenshot_dir" -type f -name '*.png' -newer "$marker" \
        -size +56c -print -quit)
      [[ -n $png ]] && break
      sleep 0.01
    done
    [[ -n $png ]]
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
reply=$(send_reply 'CONSOLEOS_PAUSE_FRAME 700001 3')
[[ $reply == 'PAUSE_FRAME_FAILED 700001 invalid_arguments' ]]
[[ $(sha256sum "$raw" | awk '{print $1}') == "$before_hash" ]]
[[ ! -e $next ]]
reply=$(send_reply 'CONSOLEOS_PAUSE_FRAME invalid 1')
[[ $reply == 'PAUSE_FRAME_FAILED 0 invalid_arguments' ]]
[[ $(sha256sum "$raw" | awk '{print $1}') == "$before_hash" ]]
[[ ! -e $next ]]

# Two captures without removing the destination exercise atomic replacement.
for generation in 800001 800002; do
  reply=$(send_reply "CONSOLEOS_PAUSE_FRAME $generation 2")
  [[ $reply == "PAUSE_FRAME_READY $generation "*" RGBA8888" ]]
  verify_raw "$generation"
done

run_png_set

# Optional destructive final check: close content, then prove a real capture
# failure leaves the prior valid publication untouched.
if [[ ${CHECK_NO_GAME_FAILURE:-0} == 1 ]]; then
  before_hash=$(sha256sum "$raw" | awk '{print $1}')
  send_no_reply CLOSE_CONTENT
  sleep 1
  reply=$(send_reply 'CONSOLEOS_PAUSE_FRAME 900001 1')
  [[ $reply == 'PAUSE_FRAME_FAILED 900001 no_game' ]]
  [[ $(sha256sum "$raw" | awk '{print $1}') == "$before_hash" ]]
  [[ ! -e $next ]]
fi
echo 'pause-frame benchmark: PASS'
