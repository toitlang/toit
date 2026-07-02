#!/usr/bin/env python3
"""Drive the EC618 uart-ota receiver over /dev/ttyUSB0 (UART1).

Protocol (host -> device, byte-oriented):
    'P'                    ping        -> 'P'
    'I'                    info        -> 'A' or 'B' (running slot)
    'T'                    trial?      -> 'Y' or 'N'
    'E'                    erase       -> 'K' (ok) or 'X' (fail)
    'W'<off:4 BE><len:4 BE>            -> 'R' then send <len> bytes -> 'K' or 'X'
    'S'                    stage+reset -> 'K' (device reboots into the trial slot)
    'V'                    validate    -> 'K' (cancels rollback; no reset)
    'N'                    invalidate  -> 'K' (device reboots, rolls back)

Trial-boot flow: after STAGE the device reboots and runs the new slot on
trial. This script then reconnects, confirms it is the trial slot, and
(unless --no-validate) sends VALIDATE to make it permanent. With
--no-validate the device is left unconfirmed, so the next reset rolls it
back — the rollback demonstration.

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

    def drain(self, quiet: float = 0.4):
        """Discard all buffered input until the wire is quiet for `quiet`
        seconds. Used after a ping handshake to flush the burst of 'P'
        replies the device emits for the many pings it buffered while
        booting — otherwise the next command's ack reads a stale 'P'."""
        self._buf = bytearray()
        end = time.monotonic() + quiet
        while time.monotonic() < end:
            n = self._port.in_waiting
            if n:
                self._port.read(n)
                end = time.monotonic() + quiet
            else:
                time.sleep(0.02)

    def expect(self, cmd_name: str, want: bytes, *, timeout: float):
        got = self.read_ack(timeout)
        if got != want:
            raise SystemExit(f"{cmd_name}: expected {want!r}, got {got!r}")


def handshake(dev: "Device") -> bytes:
    """PING until the device answers, then return its running slot via INFO.
    Tolerates the boot banner and a freshly-reset device."""
    time.sleep(1.0)  # Let the boot-rom banner pass.
    for attempt in range(1, 31):
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

    # Flush the backlog of 'P' replies (the device buffered every ping it
    # received while booting and answers them all once the receiver runs).
    dev.drain()
    dev.write(b"I")
    active = dev.read_ack(timeout=5)
    if active not in (b"A", b"B"):
        sys.exit(f"bad INFO response: {active!r}")
    return active


def query_trial(dev: "Device") -> bool:
    dev.write(b"T")
    t = dev.read_ack(timeout=5)
    if t not in (b"Y", b"N"):
        sys.exit(f"bad TRIAL response: {t!r}")
    return t == b"Y"


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--slot-a", required=True, type=Path)
    parser.add_argument("--slot-b", required=True, type=Path)
    parser.add_argument("--port", default="/dev/ttyUSB0")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--chunk", type=int, default=4096,
                        help="bytes per WRITE command (must be %16 == 0)")
    parser.add_argument("--chunk-delay", type=float, default=0.0,
                        help="seconds to pause after each chunk (lets the "
                             "device idle so the modem CP gets serviced)")
    parser.add_argument("--save-payload", type=Path)
    parser.add_argument("--no-stream", action="store_true",
                        help="only build the payload, don't talk to the device")
    parser.add_argument("--no-validate", action="store_true",
                        help="stage the trial but do NOT validate it; the next "
                             "reset will roll back (rollback demonstration)")
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
        active = handshake(dev)
        print(f"[host] running slot = {active!r}", file=sys.stderr)

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

        target = b"B" if active == b"A" else b"A"
        print(f"[host] payload written (SHA={sha.hex()[:16]}…); sending STAGE",
              file=sys.stderr)
        dev.write(b"S")
        dev.expect("STAGE", b"K", timeout=5)
        print(f"[host] STAGE acked — device reboots into trial slot {target!r}",
              file=sys.stderr)

        # The device has reset. Reconnect and confirm we are on the trial.
        print("[host] reconnecting to the trial boot", file=sys.stderr)
        running = handshake(dev)
        on_trial = query_trial(dev)
        print(f"[host] after reboot: running slot={running!r} trial={on_trial}",
              file=sys.stderr)
        if running != target:
            sys.exit(f"expected to boot trial slot {target!r}, got {running!r}")
        if not on_trial:
            sys.exit("device does not report being on trial after STAGE")

        if args.no_validate:
            print("[host] --no-validate: leaving slot unconfirmed. The NEXT "
                  "reset (power-cycle) will roll back to the previous slot.",
                  file=sys.stderr)
        else:
            dev.write(b"V")
            dev.expect("VALIDATE", b"K", timeout=10)
            print(f"[host] VALIDATE acked — slot {running!r} is now permanent",
                  file=sys.stderr)
    finally:
        dev.close()


if __name__ == "__main__":
    main()
