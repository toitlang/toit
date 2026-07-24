# EC618 AP project (PLAT side)

The Toit "user project" that the EC618 SDK build (xmake, in
`third_party/luatos-soc-ec618`) compiles and links into the base image.
It used to live inside the SDK tree as `project/toit/`; the Makefile now
points the SDK at this directory through the `PROJECT_DIR` environment
override.

- `src/toit_main.c` — boot entry: VM slot dispatcher (A/B), per-slot
  `.data` copy, reset handling.
- `src/bsp_custom.c` — board init override (link-level override of the
  SDK's `BSP_CustomInit`).
- `src/sys_ro_override.c` — flash write guard (`sysROSpaceCheck`
  override).
- `src/anchor.c`, `inc/anchor.h` — the anchor record (boot state + the active partition table, power-fail-safe)
  (shared with the VM via the cmake include path in
  `toolchains/ec618.cmake`).
- `src/plat_keep.c` — symbols the frozen base guarantees to separately
  linked VM slots.
- `inc/RTE_Device.h` — peripheral RTE configuration for the SDK drivers.
- `xmake.lua` — the project build description, included by the SDK's
  top-level xmake.lua.

Base stability matters here: slots link directly against the published
`base.elf`, and the base ID prevents them from running against another base.
