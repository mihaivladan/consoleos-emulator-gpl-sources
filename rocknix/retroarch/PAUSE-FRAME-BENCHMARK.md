# Experimental raw pause-frame benchmark

This experiment is stacked after the pinned ROCKNIX patches and
`0001-consoleos-correlated-load-completion.patch`. It does not replace the
accepted RetroArch artifact or alter the existing `SCREENSHOT` command.

Pinned inputs:

- RetroArch: `bdba046fa6766380bc2457532f38e589df769aaf`
- ROCKNIX: `1ebff24f36501fb6493beb2bf83bf2604536d9aa`

## Protocol

Send one UDP network-control command:

```text
CONSOLEOS_PAUSE_FRAME <generation> <scale>
```

`generation` is a nonzero decimal `uint64_t`. `scale` is exactly `1` or `2`.
Scale 1 publishes the source dimensions. Scale 2 selects every second source
pixel in each direction and therefore publishes one quarter of the pixels.

Success is returned only after the atomic rename:

```text
PAUSE_FRAME_READY <generation> <width> <height> <stride> RGBA8888
PAUSE_FRAME_READY <generation> <width> <height> <stride> RGB565
```

Failures use:

```text
PAUSE_FRAME_FAILED <generation> <reason>
```

Malformed generations report generation 0. The bounded reasons are
`invalid_arguments`, `no_game`, `unsupported_format`, `no_cpu_frame`,
`allocation_failed`, `open_failed`, `write_failed`, and `rename_failed`.

The experiment reads the lifetime-safe CPU frame cache already used by the
normal screenshot pipeline. XRGB8888 is converted to RGBA8888. Native RGB565
is copied without conversion. It intentionally does not add GPU/backend
readback. If the RP5 returns `no_cpu_frame`, stop the experiment: adding a
graphics-backend path is outside this benchmark.

## Raw file

The producer writes `/run/consoleos/pause-frame.next`, closes it, and renames
it over `/run/consoleos/pause-frame.raw`. The 56-byte header is little-endian:

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 8 | ASCII magic `COSPFRAW` |
| 8 | 4 | version, currently 1 |
| 12 | 4 | header bytes, currently 56 |
| 16 | 8 | generation |
| 24 | 4 | width |
| 28 | 4 | height |
| 32 | 4 | stride: `width * 4` for RGBA8888 or `width * 2` for RGB565 |
| 36 | 4 | format: 1 = RGBA8888, 2 = RGB565 |
| 40 | 4 | orientation, 1 = top-left |
| 44 | 4 | reserved, zero |
| 48 | 8 | payload bytes, exactly `stride * height` |

The payload contains consecutive top-to-bottom rows with no padding. RGB565
payload bytes are the core's native pixels and are not channel-converted. The
prior valid `.raw` remains untouched on every failure.

One log line records `readback_us`, `downsample_us`, `publish_us`, and
`total_us`. Readback includes the required XRGB8888-to-RGBA8888 conversion.

## RP5 benchmark

With a game visibly running and RetroArch network commands enabled:

```sh
SCREENSHOT_DIR=/storage/screenshots \
  /run/consoleos/benchmark-pause-frame.sh
```

The script finds the running RetroArch PID and re-executes itself through
`nsenter -t "$pid" -n --` when necessary. It does not weaken RetroArch's
`PrivateNetwork=yes` isolation. If automatic entry is unavailable, run the
exact command printed by the script. UDP requests and replies use a connected
Python 3 socket with a five-second bound and full-response validation.

Override `SCREENSHOT_DIR` with the actual configured screenshot directory.
The script performs exactly 10 full-size raw captures, 10 half-width/height
raw captures, and 10 ordinary `SCREENSHOT` PNG captures. PNG completion
requires a changed file with a valid signature and final `IEND` chunk; the
pre-command directory snapshot detects reuse of a same-second filename. It
removes the raw file before each measured raw sample, validates the complete
header and payload length, reports median/maximum total time, rejects an
invalid scale
and malformed generation without changing the last valid raw file, and
exercises two atomic replacements without removing the destination. Set
`CHECK_NO_GAME_FAILURE=1` for a destructive final check that sends
`CLOSE_CONTENT` and proves the resulting `no_game` capture failure also leaves
the prior valid `.raw` unchanged.

## Reversible device deployment

Do not replace `/usr/bin/retroarch` on disk. Stage the experimental artifact
and script in tmpfs, verify hashes, then bind-mount the binary for one launch:

```sh
install -m 0755 retroarch-pause-frame-rgb565-experiment \
  /run/consoleos/retroarch-pause-frame-rgb565-experiment
install -m 0755 benchmark-pause-frame.sh \
  /run/consoleos/benchmark-pause-frame.sh
install -m 0755 pause-frame-benchmark.py \
  /run/consoleos/pause-frame-benchmark.py
sha256sum /run/consoleos/retroarch-pause-frame-rgb565-experiment \
  /run/consoleos/benchmark-pause-frame.sh \
  /run/consoleos/pause-frame-benchmark.py
mount --bind /run/consoleos/retroarch-pause-frame-rgb565-experiment /usr/bin/retroarch
```

Launch a game through the unchanged session after the bind mount. Roll back
without modifying the immutable image:

```sh
umount /usr/bin/retroarch
rm -f /run/consoleos/retroarch-pause-frame-rgb565-experiment \
  /run/consoleos/benchmark-pause-frame.sh \
  /run/consoleos/pause-frame-benchmark.py \
  /run/consoleos/pause-frame.next /run/consoleos/pause-frame.raw
```

The ConsoleOS system repository's dev-lane policy still governs an actual RP5
run; these commands document the reversible mount, not acceptance evidence.
