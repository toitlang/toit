# Experimental ESP32 memory dump

`esp32.dump-memory` is a privileged, terminal operation. It freezes Toit and
the other CPU, writes the readable RAM regions as binary frames to the console
UART, waits for the transmitter to become idle, and restarts the chip.

The dump contains data from all containers, including secrets. The receiver
must store and handle it accordingly.

## Snapshot boundary

The interpreter has synchronized the calling process before entering the
primitive. The primitive then uses ESP-IDF's IPC interrupt to make the peer CPU
spin with interrupts masked, and masks interrupts on the calling CPU. The Toit
scheduler therefore cannot enforce its normal ten-second maximum primitive run
time. The hardware watchdogs are fed after every frame.

The peer CPU can be interrupted while another interpreter or the garbage
collector is running. Its cached interpreter registers and stack pointer may
not be synchronized to RAM, and a heap may be part-way through mutation or
compaction. A later semantic capture path must first bring every Toit scheduler
thread to a cooperative global safepoint and park it, then enter this terminal
hardware freeze. Until then this is a useful raw acquisition, not a guaranteed
object-graph-consistent snapshot.

This first implementation is not a cycle-exact hardware snapshot:

- The primitive call and the dumper mutate the calling CPU's stack. All region
  frames carry the `VOLATILE` flag for this reason.
- The calling CPU frame is a post-primitive sample containing PC, SP, status,
  and, on Xtensa, SAR. It is not the pre-call Toit register file.
- A dual-core peer is interrupted asynchronously. ESP32-P4 (RISC-V) records
  all integer GPRs plus `mepc`, `mstatus`, `mcause`, and `mtval`. Here `mcause`
  describes the capture interrupt and `mtval` is normally not meaningful; they
  are raw CSR evidence, not a claim that the stopped code faulted. ESP32 and
  ESP32-S3 (Xtensa) record only the interrupted PC/PS/SP, SAR, and A5-A15;
  IDF's high-priority IPC prologue has already overwritten A0/A2-A4 and keeps
  their saved values private.
- IDF's public nonblocking IPC call briefly restores the calling core's prior
  interrupt level as it returns. The dumper masks interrupts immediately and
  then waits for the peer evidence, but an interrupt can land in that small
  hand-off window. A private panic/debug entry path would be needed to remove
  this race completely.
- Floating-point, vector, debug, and other optional architectural state is not
  captured. CPU frames therefore always carry the `PARTIAL` flag.
- Single-core ESP32-C3, ESP32-C6, and ESP32-S2 devices have no asynchronously
  interrupted peer; only the calling sample is available from this primitive.
- UART MMIO changes, and DMA-capable peripherals may continue modifying RAM.
- RAM that is readable only through a remapped bank is not included.

The next acquisition revision should switch to a dedicated excluded stack and
enter through a trap/debug mechanism if a pre-call register file for the
calling CPU is required.

## Region selection and PSRAM

The primitive emits the readable regions in ESP-IDF's `soc_memory_regions`
table. This avoids illegal gaps and memory-mapped peripherals. Word-only IRAM
is read with aligned 32-bit accesses.

RTC/LP memory is emitted only when ESP-IDF includes it in that table (normally
when it is enabled as heap memory). Enumerating the remaining target-specific
RTC fast/slow aliases safely is still open work.

When PSRAM is initialized, the primitive emits a dedicated external-memory
region starting at `SOC_EXTRAM_DATA_LOW`. Its size is the smaller of
`esp_psram_get_size()` and `SOC_EXTRAM_DATA_SIZE`. If physical PSRAM is larger
than the mapped CPU window, both the capture-level `PSRAM_TRUNCATED` flag and
the region-frame `TRUNCATED` flag are set. Dumping the remaining banks would
require changing MMU mappings and is deliberately not attempted in this
snapshot path.

OpenOCD/JTAG can read mapped PSRAM on chips where the debug target describes
that window correctly. It has the same bank-mapping limitation unless the
debugger actively changes mappings.

## Console limitations

The bytes go only to `CONFIG_ESP_CONSOLE_UART_NUM` using polling register
writes. A native USB CDC or USB Serial/JTAG console is not yet a substitute:
USB needs packet/host state, and the transmit FIFO can stop accepting bytes
when no host is listening. Current Toit ESP32-C3, ESP32-C6, and ESP32-S3
envelopes configure UART0 as the primary console, even when USB Serial/JTAG is
also configured as a secondary console.

Bytes already queued in the UART FIFO can precede the first frame. Receivers
must scan for the `TDM1` sync word and validate the frame CRC.

## Frame format, version 1

All integers are unsigned and little-endian. Every frame is independently
checksummed and can be parsed without buffering an entire region.

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | ASCII sync word `TDM1` |
| 4 | 1 | Frame type: `1` info, `2` region, `3` end, `4` CPU evidence |
| 5 | 1 | Region kind, CPU architecture, or zero |
| 6 | 2 | Frame flags |
| 8 | 4 | Monotonic frame sequence |
| 12 | 4 | Region id |
| 16 | 4 | Target virtual address |
| 20 | 4 | Payload length |
| 24 | N | Payload |
| 24+N | 4 | IEEE CRC-32 from frame type through payload |

Region kinds are `1` internal byte-addressable RAM, `2` external RAM, `3` RTC
RAM, and `4` word-only internal RAM. Frame flag bits are `FIRST=1`, `LAST=2`,
`VOLATILE=4`, `TRUNCATED=8`, and `PARTIAL=16`.

The info payload is eleven 32-bit words:

1. format version;
2. ESP-IDF chip model;
3. chip revision;
4. core count;
5. chip feature bits;
6. console UART number;
7. console baud rate;
8. expected region count;
9. physical PSRAM size;
10. mapped PSRAM size;
11. capture flags.

Capture flag bits are `PSRAM_PRESENT=1`, `PSRAM_TRUNCATED=2`,
`CURRENT_STACK_VOLATILE=4`, `PERIPHERALS_RUNNING=8`, and
`PEER_CPU_FROZEN=16`, `CPU_EVIDENCE=32`, and `PEER_CPU_PARTIAL=64`.

CPU evidence is an additive version-1 frame type. A version-1 parser that does
not interpret it can skip the payload using the common length and CRC fields.
Its frame `kind` is architecture `1` for Xtensa or `2` for RISC-V, `region_id`
is the core id, and `address` repeats the sampled PC. The payload starts with
five 32-bit words:

1. CPU evidence payload version (`1`);
2. core id;
3. architecture;
4. provenance (`1` post-primitive calling sample, `2` IPC interrupt);
5. register pair count.

The remainder is that many `(register-id, value)` pairs. Generic ids are
`PC=1`, `SP=2`, `STATUS=3`, `CAUSE=4`, and `FAULT_ADDRESS=5`. Xtensa uses
`SAR=0x100` and `A0..A15=0x110..0x11f`. RISC-V uses
`X0..X31=0x200..0x21f`. Missing pairs mean unavailable evidence; receivers
must not synthesize zero values for them.

Region payloads are at most 1024 bytes. The end payload contains the emitted
region count, chunk count, and byte count. The end frame is the completion
marker; its absence means the stream is incomplete even when all received
frames pass their CRC checks.
