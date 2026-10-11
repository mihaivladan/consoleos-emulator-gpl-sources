#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 SOURCE_DIR OUTPUT_DIR [MAX_BOOT_FF_FRAMES]" >&2
  exit 2
fi

source_dir=$1
output_dir=$2
max_frames=${3:-0}
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT

cmake -S "$source_dir" -B "$build_dir" -G Ninja \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
  -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=OFF \
  -DCMAKE_C_FLAGS_RELEASE="-O2 -DNDEBUG" \
  -DCMAKE_CXX_FLAGS_RELEASE="-O2 -DNDEBUG -DCONSOLEOS_BOOT_FAST_FORWARD_MAX_FRAMES=$max_frames" \
  -DBUILD_LIBRETRO_CORE=ON

cmake --build "$build_dir" --target swanstation_libretro --parallel "$(nproc)"
install -d "$output_dir"
install -m 0755 "$build_dir/swanstation_libretro.so" "$output_dir/swanstation_libretro.so"

{
  printf 'cmake_generator=Ninja\n'
  printf 'cmake_build_type=Release\n'
  printf 'cmake_interprocedural_optimization=OFF\n'
  printf 'cmake_interprocedural_optimization_release=OFF\n'
  printf 'c_compiler=aarch64-linux-gnu-gcc\n'
  printf 'cxx_compiler=aarch64-linux-gnu-g++\n'
  printf 'build_libretro_core=ON\n'
  printf 'consoleos_boot_fast_forward_max_frames=%s\n' "$max_frames"
} > "$output_dir/BUILD-FLAGS.txt"
