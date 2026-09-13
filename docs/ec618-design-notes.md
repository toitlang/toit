# EC618 design notes

These notes cover constraints that are easy to miss when changing the port.
Build, flashing, and wiring instructions are in [the rig guide](ec618-rig-guide.md).

## Why the base and VM are linked separately

Vendor libraries and their mutable state live in a base flashed through the
boot ROM. A VM slot links against the exact `base.elf` using `--just-symbols`.
This keeps new VM C++ helpers from changing the base through linker deduplication
and allows slots to be updated without rewriting the platform runtime.

A slot therefore depends on the exact base fingerprint, not merely a compatible
API or version number. The device checks that identity before accepting an
update. Base-side source, toolchain, geometry, or keep-list changes require a
new base build and a full flash. The keep-list intentionally retains some
currently unused platform entry points to avoid needless base replacements.
Newlib-nano's optional `_printf_float` must be retained explicitly: retaining
`snprintf` alone does not enable fixed-precision float formatting.

## Why the slot carries relocation metadata and a RAM initializer

One canonical VM image must run in either flash slot. SRL3 describes absolute
pointers into the slot and Thumb branches out to the base. Firmware containers
are part of that same relocatable unit. A build relocates A to B and compares
it byte-for-byte with an independently linked B image; keep that check when
changing toolchains or linker scripts. A four-byte relocation can cross a flash
sector boundary, so the writer preserves both halves across sector flushes.

The base's startup copy table cannot initialize a future VM's mutable data.
Each slot consequently carries its own `.data` initializer, and generated
metadata relocates slot pointers copied into shared RAM. The base reserves a
fixed VM RAM pool; growing within it is slot work, enlarging the pool is a
base change. See `src/slot_reloc_ec618.*` and `tools/ec618/gen-data-reloc.toit`.

## Why console selection is part of the image transaction

The two rigs use different console UARTs. The anchor associates the console
and partition table with the selected image, so trial boot, validation, and
rollback move them together. Changing the console of the running image alone
could make the rollback image unreachable. The provisioning tool can choose
the initial console; the runtime setter applies only to a staged trial.

## Why UART uses DMA and holds a sleep vote

IRQ-only receive cannot keep up during XIP flash erase/write stalls. RX DMA
and a ring continue capturing while the CPU cannot execute flash code. An open
UART also prevents sleep states that discard armed receives. Release the port
when receive wakefulness is no longer needed. RS485 TX completion must wait for
the FIFO to drain before dropping DE; ordinary streaming uses earlier completion
notification to prepare the next chunk.

## Why the application watchdog has a task and a hardware backstop

The normal WDT counts CPU-active time and stops during tickless idle. The AON
watchdog is fed by the modem core, so it can remain satisfied while the
application is wedged. A separate FreeRTOS task enforces the application's
wall-clock deadline and feeds the normal WDT. If a busy lockup prevents that
task from running, the normal WDT provides the backstop.

## Why task-stack initialization is wrapped

The prebuilt FreeRTOS kernel aligns stack tops to four bytes, but the ARM C ABI
requires eight-byte alignment at call boundaries. Variadic double arguments
otherwise land at a different address from the one newlib reads. The base wraps
`pxPortInitialiseStack` to align the top before constructing the exception
frame, covering both static and dynamically allocated tasks.

## Why libc allocation entry points are wrapped

The base uses cmpctmalloc. Newlib's reentrant allocation entry points must reach
that same allocator. In particular, `_memalign_r` cannot use its normal chunk
splitting after calling a wrapped `_malloc_r`: it would interpret cmpctmalloc
headers as newlib headers and corrupt memory. It is wrapped directly to the
aligned allocator instead. See `toolchains/ec618/project/src/heap_7.c`.
