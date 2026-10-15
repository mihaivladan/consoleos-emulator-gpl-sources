# ConsoleOS emulator GPL sources

This repository publishes the GPLv3 emulator changes used by ConsoleOS on the
Retroid Pocket 5, together with reproducible ROCKNIX build and verification
workflows.

It is deliberately separate from the
[RP5 kernel test repository](https://github.com/mihaivladan/rp5-ufs-kernel-test):
kernel and Device Tree experiments live there; emulator patches live here.

## What is included

- **RetroArch:** a correlated load-completion interface so a caller can tell
  when a state load actually succeeded, failed or is still pending. See the
  [RetroArch notes](rocknix/retroarch/README.md).
- **SwanStation:** a bounded clean-room fast-forward option for the PlayStation
  boot sequence. See the [SwanStation notes](rocknix/swanstation/README.md).
- **Build provenance:** pinned upstream revisions, patches, build scripts,
  target-runtime ABI checks, checksums and GitHub Actions workflows for the
  ROCKNIX SM8250/aarch64 target.

The workflows publish the stable artifacts
`consoleos-rocknix-sm8250-retroarch` and
`consoleos-rocknix-sm8250-swanstation`. A successful host build is not device
acceptance; the component notes identify the remaining RP5 checks.

## What is not included

ConsoleOS itself is not open source. This repository does not contain its
shell, runtime-session owner, emulator adapters, service coordination or
product lifecycle logic. Those components communicate with the GPL programs
at arm's length and are not needed to build or understand the modifications
published here.

## License

The repository is licensed under GPL-3.0. The included patches modify their
respective GPLv3 upstream projects; upstream copyright notices remain with
their authors. See [LICENSE](LICENSE).
