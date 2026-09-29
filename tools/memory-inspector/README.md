# Memory inspector

Finds out where the memory of a Toit device goes. The device writes a
capture of its memory state to the console; this tool decodes the capture
and answers questions about it. All answers are JSON, so the tool can be
used by agents and scripts.

## Workflow

1. Build the firmware with memory captures enabled (`CONFIG_TOIT_MEMORY_CAPTURE`,
   enabled by default).
2. Call `system.capture-memory` in a Toit program. The capture pauses all
   processes while it prints `#TMC` lines on the console, and then resumes
   them. The device keeps running, so it can be captured repeatedly. At
   115200 baud a capture of a small device takes around 10 seconds; a higher
   console baud rate shortens the pause.
3. Record the capture with `record`, or use any saved console output (for
   example from `jag monitor`). Other console output in the file is ignored.
4. Ask questions:

```sh
alias memory-inspector='toit run --project-root tools tools/memory-inspector/main.toit --'

memory-inspector record --port /dev/ttyUSB0 capture.txt
memory-inspector summary --envelope firmware.envelope capture.txt
memory-inspector census --process 1 --envelope firmware.envelope capture.txt
memory-inspector objects --process 1 --class MyClass --envelope firmware.envelope capture.txt
memory-inspector object --envelope firmware.envelope capture.txt 0x3fcc4850
memory-inspector path --envelope firmware.envelope capture.txt 0x3fcc4850
memory-inspector retainers --envelope firmware.envelope capture.txt 0x3fcc4850
```

On the host, `toit run` programs can capture too: their stdout contains the
capture lines. There is no system-heap map on the host.

QEMU gives a faster development loop than hardware (see tests/qemu/README.md
for how to install it):

```sh
toit tool firmware -e firmware.envelope container install -o app.envelope app app.snapshot
toit tool firmware -e app.envelope extract --format=image -o app.bin
qemu-system-xtensa -M esp32 -display none -monitor none -serial stdio -no-reboot \
    -drive file=app.bin,format=raw,if=mtd | tee console.log
memory-inspector summary --envelope app.envelope console.log
```

## Names

Class, field, and global names come from the snapshots of the programs. The
tool finds them by program UUID in:
- the containers of the firmware envelopes given with `--envelope`,
- the snapshot files given with `--snapshot`,
- `<uuid>.snapshot` files in the directories given with `--snapshot-dir`
  (by default the directories where `toit` and `jag` store snapshots).

Without a snapshot, classes are shown as `class#<id>`.

## What the answers mean

- `summary`: the size of the system heaps, the used blocks of the system heap
  by owner, and per process its heap and the classes that use the most memory.
  A process owns the malloc blocks that hold its heap chunks and the external
  content of its objects (external strings and byte arrays, and native
  resources that are referenced from byte-array proxies). The blocks the
  capture itself uses are owned by `memory capture`. All other blocks are
  grouped by their malloc tag.
- `census`: per class the number of objects, their bytes on the Toit heap,
  their external bytes in the system heap, and how many of them are live.
- Live objects are reachable from the roots of their process: its current
  task, its globals, its external roots, and the objects its finalizers keep
  alive. Other objects are garbage that hasn't been collected yet.
- `path`: a shortest chain of references from a root to an object. Stack slots
  are shown by index.

## Capture format

Each record is one console line: `#TMC <base64>`. The base64 payload is a
sequence number (u32 little endian), a UBJSON list whose first element is the
record type, and a CRC-32 of the preceding bytes (u32 little endian). The
record types are documented in `src/memory_capture.cc`. The capture contains
the object layout constants of the VM, so the tool doesn't need to know the
VM's layout. It contains all data of all processes, including secrets.
