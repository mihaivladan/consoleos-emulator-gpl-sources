# ConsoleOS SwanStation build

This directory publishes the GPLv3 patch and complete standalone build recipe
for ConsoleOS's pinned SwanStation libretro core. The implementation was made
from SwanStation's own source and the clean-room behavioural specification;
DuckStation source was not used.

The GitHub Actions workflow builds an unpatched control and the patched core
from SwanStation commit `4d309c05fd7bdc503d91d267bd542edb8d192b09`, matching
ROCKNIX commit `1ebff24f36501fb6493beb2bf83bf2604536d9aa`. It disables
LTO to match ROCKNIX's `PKG_BUILD_FLAGS="-lto"`, records the exact CMake flags,
checks the target ABI against the checksum-pinned ROCKNIX runtime, and caches
the artifacts by SwanStation commit, ROCKNIX commit, patch SHA-256 and build
recipe SHA-256.

The ABI gate requires the candidate's complete `NEEDED` set to match the
unpatched control and requires every entry to exist in the target runtime.
Ordinary libraries remain limited to libc, libm, libstdc++ and libgcc_s. The
AArch64 ELF loader (`ld-linux-aarch64.so.1`) is checked separately rather than
misclassified as an application-library dependency.

`swanstation_libretro.so` is the product core. The separately named
`swanstation_libretro-low-bound.so` is only a qualification artifact compiled
with a two-frame safety bound; it must never ship.
