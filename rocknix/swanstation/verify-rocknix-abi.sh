#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 TARGET_ROOT STOCK_CORE CANDIDATE_CORE REPORT_DIR" >&2
  exit 2
fi

target_root=$1
stock=$2
candidate=$3
report_dir=$4
mkdir -p "$report_dir"

needed() {
  aarch64-linux-gnu-readelf -d "$1" | \
    sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p' | LC_ALL=C sort -u
}

exports() {
  aarch64-linux-gnu-readelf --dyn-syms --wide "$1" | \
    awk '$5 == "GLOBAL" && $7 != "UND" {sub(/@.*/, "", $8); print $8}' | LC_ALL=C sort -u
}

options() {
  strings "$1" | grep '^swanstation_' | LC_ALL=C sort -u
}

needed "$stock" > "$report_dir/STOCK-NEEDED.txt"
needed "$candidate" > "$report_dir/CANDIDATE-NEEDED.txt"
allowed='libc.so.6 libm.so.6 libstdc++.so.6 libgcc_s.so.1'
while IFS= read -r soname; do
  case " $allowed " in
    *" $soname "*) ;;
    *) echo "::error title=SwanStation ABI::unexpected NEEDED soname: $soname"; exit 1 ;;
  esac
  find "$target_root" \( -type f -o -type l \) -name "$soname" -print -quit | grep -q . || {
    echo "::error title=SwanStation ABI::target runtime lacks $soname"
    exit 1
  }
done < "$report_dir/CANDIDATE-NEEDED.txt"

required_versions() {
  aarch64-linux-gnu-readelf --version-info "$1" | \
    sed -n 's/.*Name: \(\(GLIBC\|GLIBCXX\|GCC\)_[^ ]*\).*/\1/p' | LC_ALL=C sort -u
}

required_versions "$candidate" > "$report_dir/CANDIDATE-SYMBOL-VERSIONS.txt"
find "$target_root/usr/lib" \( -type f -o -type l \) \
  \( -name 'libc.so.6' -o -name 'libstdc++.so.6*' -o -name 'libgcc_s.so.1' \) \
  -exec aarch64-linux-gnu-strings {} + | \
  grep -E '^(GLIBC|GLIBCXX|GCC)_[0-9]' | LC_ALL=C sort -u > "$report_dir/ROCKNIX-SYMBOL-VERSIONS.txt"
comm -23 "$report_dir/CANDIDATE-SYMBOL-VERSIONS.txt" \
  "$report_dir/ROCKNIX-SYMBOL-VERSIONS.txt" > "$report_dir/MISSING-SYMBOL-VERSIONS.txt"
if [ -s "$report_dir/MISSING-SYMBOL-VERSIONS.txt" ]; then
  missing_versions=$(tr '\n' ' ' < "$report_dir/MISSING-SYMBOL-VERSIONS.txt")
  echo "::error title=SwanStation ABI::target runtime lacks symbol versions: $missing_versions"
  exit 1
fi

exports "$stock" > "$report_dir/STOCK-EXPORTS.txt"
exports "$candidate" > "$report_dir/CANDIDATE-EXPORTS.txt"
if ! diff -u "$report_dir/STOCK-EXPORTS.txt" "$report_dir/CANDIDATE-EXPORTS.txt" \
    > "$report_dir/EXPORT-DIFF.txt"; then
  export_delta=$(tr '\n' ' ' < "$report_dir/EXPORT-DIFF.txt" | cut -c1-500)
  echo "::error title=SwanStation ABI::export mismatch: $export_delta"
  exit 1
fi

options "$stock" > "$report_dir/STOCK-CORE-OPTIONS.txt"
options "$candidate" > "$report_dir/CANDIDATE-CORE-OPTIONS.txt"
comm -13 "$report_dir/STOCK-CORE-OPTIONS.txt" "$report_dir/CANDIDATE-CORE-OPTIONS.txt" \
  > "$report_dir/ADDED-CORE-OPTIONS.txt"
if ! printf '%s\n' swanstation_BIOS_FastForwardBoot | \
    diff -u - "$report_dir/ADDED-CORE-OPTIONS.txt" > "$report_dir/CORE-OPTION-DIFF.txt"; then
  option_delta=$(tr '\n' ' ' < "$report_dir/CORE-OPTION-DIFF.txt" | cut -c1-500)
  echo "::error title=SwanStation core options::unexpected option delta: $option_delta"
  exit 1
fi

grep -Fxq swanstation_BIOS_PatchFastBoot "$report_dir/CANDIDATE-CORE-OPTIONS.txt"
grep -Fxq swanstation_BIOS_FastForwardBoot "$report_dir/CANDIDATE-CORE-OPTIONS.txt"

{
  printf 'abi_gate=pass\n'
  printf 'needed_sonames=allowlisted-and-present\n'
  printf 'symbol_versions=all-provided-by-rocknix-runtime\n'
  printf 'exports=match-unpatched-control\n'
  printf 'core_options=unpatched-plus-fast-forward-boot\n'
  printf 'device_smoke=pending\n'
} > "$report_dir/ABI-REPORT.txt"
