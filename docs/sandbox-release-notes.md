# Sandbox release notes

What changes for someone who upgrades to this branch. Each item names the
option, flag or error as it appears in the code; the details are in
docs/sandbox-policy.md, docs/sandbox-guarantee.md and
docs/format2-migration.md.

## Building and installing

- **Sandbox support is a build option, `TOIT_SANDBOX`.** On devices it is
  the Kconfig option `CONFIG_TOIT_SANDBOX` (needs `TOIT_VERIFIED_CORE`) and
  defaults to off; it costs about 35 KB of flash and 2.8 KB of static RAM on
  the classic ESP32. Host builds (CMake `-DTOIT_SANDBOX=ON|OFF`) have it on
  by default. Without it, every untrusted start, launch and install fails
  with `SANDBOX_NOT_SUPPORTED`; trusted containers are not affected.
  Firmware that runs third-party code must set `CONFIG_TOIT_SANDBOX=y`
  (docs/sandbox-policy.md, "Firmware without sandboxes").
- **Untrusted programs must be in bytecode format 2.** The host flag
  `-Xuntrusted_format1` and the variable `TOIT_UNTRUSTED_FORMAT1` are
  removed. An untrusted format-1 program is refused at install, spawn and
  launch with `FORMAT_2_REQUIRED`, in every build.
- **The image format tag is now `TBC3`.** Images built by an earlier
  version are refused where programs start, with "bytecode format TBC2 is
  not supported by this VM; recompile" (the tag letter in the message is
  the one of the image). Recompile with the SDK that matches the firmware.
  The compiler flag is still `-Xbytecode_format=2`.
- **A verified image must be reinstalled after a firmware update that
  changes the verification epoch.** An install-time verdict is valid only
  for the epoch (`verified/verification-epoch.cmake`) of the firmware that
  computed it. After an update with another epoch, the installed untrusted
  container does not start: it fails with `VERIFICATION_FAILED`, and the
  console prints "untrusted image: verdict of verification epoch XXXXXXXX,
  not YYYYYYYY: reinstall it". The image stays installed until it is
  reinstalled or removed.
- **The Xtensa firmware (classic ESP32, ESP32-S3) with the verified core
  needs the `toit-esp` Rust toolchain.** The RISC-V chips (ESP32-C6, H2)
  need only the Rust target `riscv32imac-unknown-none-elf`. See docs/xtensa-rust-toolchain.md.

## What a sandbox may do

- **A sandboxed container may only use the services on its list.** The
  default list is empty: besides service discovery and printing (which every
  sandbox may use) it discovers and opens no service. Give the services at
  start: `containers.start image-id arguments --untrusted
  --services=[Service.SELECTOR, "uuid"]`. `--services="all"`
  (`ContainerService.ALL-SERVICES`) allows every provider that accepts
  sandboxed clients. The list does not restrict trusted containers. Opening
  a service that is not on the list fails with `PERMISSION_DENIED`.
- **Providing services is a privilege** of the launch policy; a sandbox
  without it cannot provide services (`--may-provide-services`).

## Memory

On devices a sandbox has a heap quota (default 128 KB) and also leaves part
of the system heap free. Three levels of free system heap, from the top
(Kconfig, default in KB; `CONFIG_TOIT_SANDBOX_HEAP_FLOOR_KB` = 0 turns all
three off; none has an effect without `TOIT_SANDBOX`):

| Level | What stops there | Kconfig | Default |
|---|---|---|---|
| floor + headroom + start | a sandboxed container does not start (`QUOTA_EXCEEDED`) | `CONFIG_TOIT_SANDBOX_START_KB` | 16 |
| floor + headroom | sandbox heaps stop growing (`OUT_OF_MEMORY` in the sandbox) | `CONFIG_TOIT_SANDBOX_GROWTH_HEADROOM_KB` | 16 |
| floor | messages queued at a sandbox or sent by one are refused (`QUOTA_EXCEEDED`) | `CONFIG_TOIT_SANDBOX_HEAP_FLOOR_KB` | 16 |

- **Exit code 243 (`containers.EXIT-EVICTED`):** the system stopped the
  sandbox because a request of trusted code (a WiFi connect, a container
  start) or an operation of the system ran out of memory. Sandboxes lose
  first, the one reserving the most memory first. The system does not
  restart it; that is up to its trusted owner.
- **Exit code 244 (`containers.EXIT-REPLY-LOST`):** the VM ended the
  sandbox because an RPC reply to it could be neither delivered nor replaced
  by an error reply (its mailbox or the memory floor refused it). Before,
  its call waited forever.
- **Restart delay:** a program whose sandboxed runs keep dying after running
  out of memory is started again only after a delay: 1 s after such a run,
  doubling for each such run in a row up to 32 s, reset after 60 s without
  one. Each refused start prints `[sandbox start refused: ...]`. Trusted
  containers are not affected.
- **The boot container running out of memory at start restarts the
  device** (the system ends with exit value 1, no retry), so that a firmware
  that is not validated yet is rolled back. Before, such a container was
  refused and the device kept running without it. Other starts of a
  container fail with `OUT_OF_MEMORY` instead.
- A WiFi connect that fails for lack of memory fails the call instead of
  restarting the device, and stops sandboxes first.

## Experimental

- **Sandbox network service.** Sandboxes cannot call socket, TLS or DNS
  primitives and the network service refuses them. The network is offered
  by an installable trusted container, `services/sandbox_network/main.toit`,
  with two services (TCP/TLS streams, and HTTP requests). A sandbox needs
  it on its service list (or `--services="all"`). It is experimental
  and has not passed a device test yet: its tests
  (`tests/sandbox/net/`) run on the host. See docs/sandbox-policy.md,
  "Network access (experimental)".
