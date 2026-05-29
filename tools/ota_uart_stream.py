#!/usr/bin/env python3
"""Drive the EC618 uart-ota receiver over /dev/ttyUSB1.

Protocol (host -> device, byte-oriented):
    'P'                    ping       -> 'P'
    'I'                    info       -> 'A' or 'B'
    'E'                    erase      -> 'K' (ok) or 'X' (fail)
    'W'<off:4 BE><len:4 BE>            -> 'R' then send <len> bytes -> 'K' or 'X'
    'S'                    swap+reset -> 'K' (and the device reboots)

The device interleaves human-readable `[ota] ...\\n` status lines on
the same UART; we drain those before reading each ack so they don't
confuse the protocol.
"""

import argparse
import hashlib
import struct
import sys
import time
from pathlib import Path

AP_LOAD_ADDR = 0x00824000
VM_A_ORIGIN  = 0x00991000
VM_B_ORIGIN  = 0x009F1000
VM_SLOT_SIZE = 0x00060000
DROM_MAGIC_1 = 0x7017DA7A
DROM_MAGIC_2 = 0x00C09F19
UUID_SIZE = 16
DROM_FULL_SIZE = 4 + 4 + UUID_SIZE + 4

ACKS_OK    = {b'K'}
ACKS_ERROR = {b'X'}


def find_drom_in_range(image: bytes, lo: int, hi: int) -> int:
    for off in range(lo & ~3, hi - DROM_FULL_SIZE, 4):
        magic1, _ = struct.unpack_from("<II", image, off)
        if magic1 != DROM_MAGIC_1:
            continue
        magic2_off = off + 4 + 4 + UUID_SIZE
        (magic2,) = struct.unpack_from("<I", image, magic2_off)
        if magic2 == DROM_MAGIC_2:
            return off
    raise SystemExit(f"no DromData in 0x{lo:x}..0x{hi:x}")


def build_payload(slot_a_path: Path, slot_b_path: Path) -> bytes:
    a = slot_a_path.read_bytes()
    b = slot_b_path.read_bytes()
    slot_b_file_off = VM_B_ORIGIN - AP_LOAD_ADDR
    payload = bytearray(b[slot_b_file_off:slot_b_file_off + VM_SLOT_SIZE])
    a_drom = find_drom_in_range(a, VM_A_ORIGIN - AP_LOAD_ADDR,
                                VM_A_ORIGIN - AP_LOAD_ADDR + VM_SLOT_SIZE)
    b_drom = find_drom_in_range(payload, 0, len(payload))
    src = a_drom + 4
    dst = b_drom + 4
    payload[dst:dst + 4 + UUID_SIZE] = a[src:src + 4 + UUID_SIZE]
    return bytes(payload)


class Device:
    """Thin wrapper over pyserial. Reads one protocol byte at a time,
    transparently consuming any `[ota] ...\\n` status lines the device
    interleaves on the same wire and printing them to stderr."""

    def __init__(self, port_path: str, baud: int):
        import serial
        self._port = serial.Serial(port_path, baudrate=baud, timeout=1)
        self._buf = bytearray()

    def close(self):
        self._port.close()

    def _refill(self, deadline: float, want: int = 64):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"timed out; buffer = {bytes(self._buf)!r}")
        self._port.timeout = max(0.05, min(remaining, 1.0))
        # Read whatever is already buffered (returns immediately); only
        # block (for one byte) when nothing is available yet. Using a
        # fixed read(want) made pyserial wait the whole timeout for the
        # buffer to fill, which throttled the transfer to ~1.7 KB/s.
        n = self._port.in_waiting
        chunk = self._port.read(n if n > 0 else 1)
        if chunk:
            self._buf += chunk

    def next_protocol_byte(self, timeout: float) -> int:
        """Return the next protocol byte's value (int 0..255), eating
        any status lines that come before it. Leading CR/LF between
        status lines is treated as filler."""
        deadline = time.monotonic() + timeout
        while True:
            # Drop stray CR/LF — neither is a defined protocol byte.
            while self._buf and self._buf[0] in (0x0A, 0x0D):
                self._buf = self._buf[1:]
            if not self._buf:
                self._refill(deadline)
                continue
            head = self._buf[0]
            if head != ord('['):
                # Plain protocol byte.
                self._buf = self._buf[1:]
                return head
            # Could be the start of an `[ota]` or `[toit]` status
            # line — but we need enough buffered to decide, and to
            # find the terminating '\n'.
            if len(self._buf) < 6:
                self._refill(deadline)
                continue
            tag5 = bytes(self._buf[:5])
            tag6 = bytes(self._buf[:6])
            if tag5 != b"[ota]" and tag6 != b"[toit]":
                # `[` was a real protocol byte after all.
                self._buf = self._buf[1:]
                return head
            nl = self._buf.find(b"\n", 5)
            if nl == -1:
                self._refill(deadline)
                continue
            sys.stderr.write(bytes(self._buf[:nl+1]).decode("utf-8", "replace"))
            sys.stderr.flush()
            self._buf = self._buf[nl+1:]
            # loop to try again

    def read_ack(self, timeout: float) -> bytes:
        return bytes([self.next_protocol_byte(timeout)])

    def write(self, data: bytes):
        self._port.write(data)
        self._port.flush()

    def expect(self, cmd_name: str, want: bytes, *, timeout: float):
        got = self.read_ack(timeout)
        if got != want:
            raise SystemExit(f"{cmd_name}: expected {want!r}, got {got!r}")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--slot-a", required=True, type=Path)
    parser.add_argument("--slot-b", required=True, type=Path)
    parser.add_argument("--port", default="/dev/ttyUSB1")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--chunk", type=int, default=4096,
                        help="bytes per WRITE command (must be %16 == 0)")
    parser.add_argument("--chunk-delay", type=float, default=0.0,
                        help="seconds to pause after each chunk (lets the "
                             "device idle so the modem CP gets serviced)")
    parser.add_argument("--save-payload", type=Path)
    parser.add_argument("--no-stream", action="store_true",
                        help="only build the payload, don't talk to the device")
    args = parser.parse_args()

    if args.chunk % 16 != 0:
        sys.exit("--chunk must be a multiple of 16")

    payload = build_payload(args.slot_a, args.slot_b)
    if args.save_payload:
        args.save_payload.write_bytes(payload)
    if args.no_stream:
        return

    dev = Device(args.port, args.baud)
    try:
        # Wait for the receiver's `[ota] ready` banner so we don't
        # start sending bytes before the container's read loop is
        # actually running. The banner is one of the `[ota] ...\n`
        # status lines next_protocol_byte will print to stderr while
        # it eats them; we just keep calling that function until the
        # device sends a real protocol byte in response to PING.
        print("[host] waiting for device to boot, then pinging", file=sys.stderr)
        # Sleep briefly to let the boot rom banner pass; then drain
        # any pending status lines from the boot path.
        time.sleep(1.0)
        # Send PING; the function below will skip past banner lines.
        for attempt in range(1, 21):
            dev.write(b"P")
            try:
                b = dev.read_ack(timeout=1.5)
            except TimeoutError:
                continue
            if b == b"P":
                print(f"[host] ping ok on attempt {attempt}", file=sys.stderr)
                break
            print(f"[host] ping #{attempt}: got {b!r}", file=sys.stderr)
        else:
            sys.exit("never got ping response")

        # Which slot is active?
        dev.write(b"I")
        active = dev.read_ack(timeout=5)
        print(f"[host] active slot = {active!r}", file=sys.stderr)
        if active not in (b"A", b"B"):
            sys.exit(f"bad INFO response: {active!r}")

        # Erase the inactive slot. Single 'E' command drives the
        # device's sector-by-sector erase loop, which prints `[ota]
        # ERASE: N/96 sectors` lines we tee to stderr. Per-sector
        # erase blocks ~50-100 ms; allow plenty of total time.
        print("[host] sending ERASE (sector-by-sector; ~7-10s)", file=sys.stderr)
        dev.write(b"E")
        dev.expect("ERASE", b"K", timeout=60)

        # Write the payload.
        size = len(payload)
        sha = hashlib.sha256(payload).digest()
        chunk_size = args.chunk
        offset = 0
        start = time.monotonic()
        while offset < size:
            n = min(chunk_size, size - offset)
            # Round up to multiple of 16 (flash segment) and pad with 0xff
            # — should already be aligned since both `size` and the per-
            # iteration n are sector-multiples.
            if n % 16 != 0:
                pad = 16 - (n % 16)
                chunk_bytes = payload[offset:offset + n] + b"\xff" * pad
                n_padded = n + pad
            else:
                chunk_bytes = payload[offset:offset + n]
                n_padded = n
            dev.write(b"W" + struct.pack(">II", offset, n_padded))
            dev.expect(f"WRITE@0x{offset:x}", b"R", timeout=5)
            dev.write(chunk_bytes)
            dev.expect(f"WRITE@0x{offset:x}", b"K", timeout=30)
            offset += n
            if args.chunk_delay > 0:
                time.sleep(args.chunk_delay)
            if offset % (32 * 1024) == 0 or offset == size:
                elapsed = time.monotonic() - start
                rate = offset / max(elapsed, 1e-6) / 1024
                print(f"[host] wrote {offset}/{size} ({rate:.1f} KB/s)",
                      file=sys.stderr)

        print(f"[host] payload written (SHA={sha.hex()[:16]}…); sending SWAP",
              file=sys.stderr)
        dev.write(b"S")
        dev.expect("SWAP", b"K", timeout=5)
        print("[host] SWAP acked — device should boot from the other slot now",
              file=sys.stderr)
    finally:
        dev.close()


if __name__ == "__main__":
    main()
