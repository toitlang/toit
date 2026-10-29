# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
"""Manage Toit containers in nRF5340 application flash through SWD.

This development transport halts/resets the application core. It requires the
exact running firmware binary and the E83 bring-up partition layout.
"""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import time
import uuid
import zlib

ROOT = Path(__file__).resolve().parents[2]
PAGE = 4096
BASE = 0xe0000
FIRMWARE_LIMIT = 0xdc000
CAPACITY = 0x1e000
STORAGE_SIZE = 0x20000
HEADER_SIZE = 48
MARKER = 0xdeadface
DATA_UUID = bytes.fromhex("3d298596637f439cb65190fdcbc0df9a")
JOURNAL_MAGIC = 0x544f4954


def u32(data, offset=0):
    return struct.unpack_from("<I", data, offset)[0]


def crc(data, seed):
    # Same reflected CRC-32 and seed convention as Utils::crc32.
    return zlib.crc32(data, seed)


def round_page(size):
    return (size + PAGE - 1) // PAGE * PAGE


def header_size(data):
    return struct.unpack_from("<H", data, 30)[0] * PAGE


def allocation_size(data, offset, limit):
    size = header_size(data[offset:offset + HEADER_SIZE])
    if not size or offset + size > limit:
        raise ValueError("Allocation extends outside its flash partition")
    if data[offset + 29] == 0 and data[offset + 24] & 0x80:
        if offset + size + 4 > limit:
            raise ValueError("Missing program assets length")
        size += round_page(4 + u32(data, offset + size))
        if offset + size > limit:
            raise ValueError("Program assets extend outside their flash partition")
    return size


def firmware_sdk(data):
    if not 8 <= len(data) <= FIRMWARE_LIMIT:
        raise ValueError("Firmware must fit in the 880 KiB firmware partition")
    stack, entry = struct.unpack_from("<II", data)
    if not (0x20000000 < stack <= 0x20080000 and stack % 8 == 0 and
            entry & 1 and (entry & ~1) < len(data)):
        raise ValueError("Invalid nRF5340 application vector table")
    candidates = []
    for offset in range(PAGE, len(data) - PAGE + 1, PAGE):
        marker, used, free, count, checksum = struct.unpack_from("<5I", data, offset)
        if marker != 0x98dfc301 or marker ^ used ^ free ^ count ^ checksum != 0xb3147ee9:
            continue
        if free or not 1 <= count <= (PAGE - 20) // 8 or used % PAGE or offset + used > len(data):
            raise ValueError("Unsupported embedded image extension")
        sdk = None
        end = offset + PAGE
        for index in range(count):
            address, size = struct.unpack_from("<II", data, offset + 20 + index * 8)
            if address != end or size % PAGE or address + size > offset + used:
                raise ValueError("Invalid bundled image bounds")
            header = data[address:address + HEADER_SIZE]
            if len(header) != HEADER_SIZE or u32(header) != MARKER or u32(header, 4) or header[29] != 0:
                raise ValueError("Invalid bundled program header")
            if allocation_size(data, address, address + size) != size:
                raise ValueError("Invalid bundled image size")
            if sdk is not None and sdk != header[32:48]:
                raise ValueError("Bundled program SDK mismatch")
            sdk = header[32:48]
            end = address + size
        if end != offset + used:
            raise ValueError("Unexpected data after bundled images")
        candidates.append(sdk)
    if len(candidates) != 1:
        raise ValueError("Expected one Toit embedded image extension")
    return candidates[0]


class Image:
    def __init__(self, encoded, sdk):
        if not encoded or len(encoded) % 132:
            raise ValueError("Expected a relocatable 32-bit Toit image (132-byte chunks)")
        self.blocks = list(struct.iter_unpack("<33I", encoded))
        self.size = len(self.blocks) * 128
        if self.size % PAGE or self.size > CAPACITY:
            raise ValueError("Image must be page aligned and fit in the registry")
        self.data = b"".join(struct.pack("<32I", *block[1:]) for block in self.blocks)
        header = self.data[:HEADER_SIZE]
        if (u32(header) != MARKER or u32(header, 4) or header[29] != 0 or
                self.blocks[0][0] & 0xfff):
            raise ValueError("Invalid relocatable program header")
        if header[32:48] != sdk:
            raise ValueError("Image SDK does not match the running firmware")
        self.program_size = header_size(header)
        if not 0 < self.program_size <= self.size:
            raise ValueError("Invalid program size")
        self.has_assets = self.size > self.program_size
        if self.has_assets and round_page(4 + u32(self.data, self.program_size)) != self.size - self.program_size:
            raise ValueError("Invalid assets length")
        for index, block in enumerate(self.blocks):
            mask = block[0]
            if index * 128 >= self.program_size and mask:
                raise ValueError("Assets must not contain relocation entries")
            for bit, word in enumerate(block[1:]):
                if mask & (1 << bit) and word > self.program_size:
                    raise ValueError("Relocation points outside the program")
        self.id = str(uuid.UUID(bytes=header[8:24]))

    def relocate(self, address, flags, metadata):
        if address % PAGE or not BASE <= address <= BASE + CAPACITY - self.size:
            raise ValueError("Image destination is outside the registry")
        data = bytearray(self.size)
        for index, block in enumerate(self.blocks):
            values = [word + address if block[0] & (1 << bit) else word
                      for bit, word in enumerate(block[1:])]
            struct.pack_into("<32I", data, index * 128, *values)
        data[24] = flags | (0x80 if self.has_assets else 0)
        struct.pack_into("<I", data, 25, metadata)
        seed = crc(struct.pack("<I", address), MARKER)
        struct.pack_into("<I", data, 4, crc(data[8:HEADER_SIZE], seed))
        return bytes(data)


def scan(storage, sdk):
    if len(storage) != STORAGE_SIZE:
        raise ValueError("Incomplete storage read")
    descriptor = storage[CAPACITY:CAPACITY + 16]
    if u32(descriptor, 12) == JOURNAL_MAGIC and u32(descriptor, 8) == crc(descriptor[:8], JOURNAL_MAGIC):
        raise ValueError("Storage journal needs recovery; boot the firmware before deploying")
    allocations = []
    offset = 0
    while offset < CAPACITY:
        header = storage[offset:offset + HEADER_SIZE]
        kind = header[29]
        seed = MARKER if kind == 1 else crc(struct.pack("<I", BASE + offset), MARKER)
        if u32(header) != MARKER or u32(header, 4) != crc(header[8:], seed):
            offset += PAGE
            continue
        if kind not in (0, 1) or (kind == 1 and header[32:48] != DATA_UUID):
            raise ValueError("Unsupported allocation format; refusing to overwrite it")
        size = allocation_size(storage, offset, CAPACITY)
        allocations.append({"id": str(uuid.UUID(bytes=bytes(header[8:24]))), "offset": offset,
                            "address": BASE + offset, "size": size, "kind": "program" if kind == 0 else "data",
                            "flags": header[24], "data": u32(header, 25),
                            "compatible": kind == 1 or header[32:48] == sdk})
        offset += size
    return allocations


def free_slot(allocations, size):
    end = 0
    for allocation in allocations:
        if allocation["offset"] - end >= size:
            return end
        end = allocation["offset"] + allocation["size"]
    if CAPACITY - end >= size:
        return end
    raise ValueError("No contiguous space for this image; no allocations were erased")


def tcl_path(path):
    path = str(Path(path).resolve())
    if any(character in path for character in "{}\\\n\r"):
        raise ValueError("Path contains unsupported Tcl characters")
    return "{" + path + "}"


class Debug:
    def __init__(self, connection):
        self.connection = connection
        self.healthy = True

    def call(self, command):
        if not self.healthy:
            raise RuntimeError("OpenOCD connection is unusable after a transport failure")
        wrapped = f'if {{[catch {{{command}}} result]}} {{format "ERROR %s" $result}} else {{set result}}'
        try:
            self.connection.sendall(wrapped.encode() + b"\x1a")
            reply = bytearray()
            while not reply.endswith(b"\x1a"):
                chunk = self.connection.recv(65536)
                if not chunk:
                    raise ConnectionError("OpenOCD disconnected")
                reply.extend(chunk)
        except OSError:
            self.healthy = False
            self.connection.close()
            raise
        result = reply[:-1].decode().strip()
        if result.startswith("ERROR"):
            raise RuntimeError(result)
        return result


def read_storage(debug, path):
    # Keep SWD reads below the FTDI driver's large queued-transfer path.
    # dump_image's 4 KiB bursts intermittently stalled this adapter in MPSSE.
    data = bytearray()
    for offset in range(0, STORAGE_SIZE, 256):
        reply = debug.call(f"nrf53.cpuapp read_memory {BASE + offset} 32 64")
        words = [int(word, 0) for word in reply.split()]
        if len(words) != 64:
            raise RuntimeError("Incomplete SWD memory read")
        data.extend(struct.pack("<64I", *words))
    path.write_bytes(data)
    return bytes(data)


@contextmanager
def debugger(openocd, log, *, network=False, recovery=False):
    if recovery and not network:
        raise ValueError("Recovery requires the network target")
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    with log.open("w") as output:
        process = subprocess.Popen([str(openocd), "-s", str(ROOT / ".cache/nrf5340/openocd/tcl"),
                                    "-c", f"set TOIT_TCL_PORT {port}",
                                    *(["-c", "set TOIT_NETWORK_CORE 1"] if network else []),
                                    *(["-c", "set TOIT_RECOVERY 1", "-c", "set TOIT_FLASH_DISCARD_RAM 1"]
                                      if recovery else []),
                                    "-f", str(ROOT / "toolchains/nrf5340/openocd.cfg")],
                                   stdout=output, stderr=subprocess.STDOUT)
        connection = None
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f"OpenOCD exited; see {log}")
                # Verify our process bound the port before connecting to it.
                if f"Listening on port {port} for tcl connections" in log.read_text():
                    connection = socket.create_connection(("127.0.0.1", port), timeout=2)
                    connection.settimeout(60)
                    break
                time.sleep(.05)
            if connection is None:
                raise RuntimeError(f"OpenOCD did not start; see {log}")
            yield Debug(connection)
        finally:
            if connection:
                try:
                    connection.sendall(b"shutdown\x1a")
                except OSError:
                    pass
                connection.close()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)


def operate(debug, args, image, sdk, run_dir):
    # Reset before mutations so no running VM can retain stale allocation state.
    debug.call("poll")
    original_state = debug.call("nrf53.cpuapp curstate")
    if original_state not in ("running", "halted"):
        raise RuntimeError(f"Cannot determine target state: {original_state}")
    mutating = args.action != "list"
    debug.call("reset halt" if mutating else "halt")
    restart_safe = True
    try:
        debug.call(f"verify_image {tcl_path(args.firmware)} 0 bin")
        before_path = run_dir / "storage-before.bin"
        before = read_storage(debug, before_path)
        allocations = scan(before, sdk)
        result = {"action": args.action, "changed": False, "allocations": allocations}
        expected = bytearray(before)
        if args.action == "install":
            flags = (1 if args.run_boot else 0) | (2 if args.critical else 0)
            matches = [allocation for allocation in allocations if allocation["id"] == image.id]
            if matches:
                if len(matches) != 1 or matches[0]["kind"] != "program":
                    raise ValueError("Image ID conflicts with existing allocations")
                allocation = matches[0]
                relocated = image.relocate(allocation["address"], flags, args.data)
                offset = allocation["offset"]
                if allocation["size"] != len(relocated) or before[offset:offset + len(relocated)] != relocated:
                    raise ValueError("Image already installed with different content or flags; uninstall it first")
            else:
                offset = free_slot(allocations, image.size)
                address = BASE + offset
                relocated = image.relocate(address, flags, args.data)
                body = run_dir / "body.bin"
                header = run_dir / "header.bin"
                complete = run_dir / "installed.bin"
                body.write_bytes(relocated[HEADER_SIZE:])
                header.write_bytes(relocated[:HEADER_SIZE])
                complete.write_bytes(relocated)
                restart_safe = False
                debug.call(f"flash write_image erase {tcl_path(body)} {address + HEADER_SIZE} bin")
                debug.call(f"verify_image {tcl_path(body)} {address + HEADER_SIZE} bin")
                words = debug.call(f"nrf53.cpuapp read_memory {address} 32 {HEADER_SIZE // 4}")
                if any(int(word, 0) != 0xffffffff for word in words.split()):
                    raise RuntimeError("Program header was not left erased")
                debug.call(f"flash write_image {tcl_path(header)} {address} bin")
                debug.call(f"verify_image {tcl_path(complete)} {address} bin")
                expected[offset:offset + image.size] = relocated
                result["changed"] = True
            result.update(id=image.id, address=BASE + offset, size=image.size)
        elif args.action == "uninstall":
            matches = [allocation for allocation in allocations if allocation["id"] == args.id]
            if any(allocation["kind"] != "program" for allocation in matches):
                raise ValueError("The requested ID belongs to data, not a container")
            for allocation in matches:
                # Erasing the allocation's header page invalidates the program.
                restart_safe = False
                debug.call(f"flash erase_address {allocation['address']} {PAGE}")
                offset = allocation["offset"]
                expected[offset:offset + PAGE] = b"\xff" * PAGE
            result.update(id=args.id, changed=bool(matches))
        after_path = run_dir / "storage-after.bin"
        after = read_storage(debug, after_path)
        if after != expected:
            raise RuntimeError("Storage changed outside the planned operation; see before/after backups")
        debug.call(f"verify_image {tcl_path(args.firmware)} 0 bin")
        restart_safe = True
        result["allocations"] = scan(after, sdk)
        result["storage_before_sha256"] = hashlib.sha256(before).hexdigest()
        result["storage_after_sha256"] = hashlib.sha256(after).hexdigest()
        return result
    finally:
        if not restart_safe or not getattr(debug, "healthy", True):
            (run_dir / "not-resumed.txt").write_text("Target was not resumed after incomplete programming or a transport failure.\n")
        elif mutating:
            debug.call("reset run")
        elif original_state != "halted":
            debug.call("resume")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--firmware", type=Path, required=True, help="Exact running native firmware binary")
    parser.add_argument("--openocd", type=Path, default=ROOT / ".cache/nrf5340/openocd/src/openocd")
    parser.add_argument("--log-dir", type=Path, default=ROOT / "build/nrf5340-deploy")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--serial", help="Optional persistent Ebyte USB-TTL path for console capture")
    parser.add_argument("--expect", help="Require this console marker after reset")
    parser.add_argument("--seconds", type=float, default=10)
    actions = parser.add_subparsers(dest="action", required=True)
    actions.add_parser("list")
    install = actions.add_parser("install")
    install.add_argument("image", type=Path, help="Relocatable image from snapshot-to-image -m32")
    install.add_argument("--no-run-boot", dest="run_boot", action="store_false")
    install.add_argument("--critical", action="store_true")
    install.add_argument("--data", type=lambda value: int(value, 0), default=0)
    remove = actions.add_parser("uninstall")
    remove.add_argument("id", type=lambda value: str(uuid.UUID(value)))
    args = parser.parse_args()
    if args.expect and (not args.serial or args.action == "list"):
        parser.error("--expect requires --serial and an operation that resets the target")
    if args.action == "install" and not 0 <= args.data <= 0xffffffff:
        parser.error("--data must be an unsigned 32-bit integer")
    firmware = args.firmware.read_bytes()
    sdk = firmware_sdk(firmware)
    image = Image(args.image.read_bytes(), sdk) if args.action == "install" else None
    tcl_path(args.firmware)
    run_dir = args.log_dir / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex[:8])
    run_dir.mkdir(parents=True)
    reference = run_dir / "firmware-reference.bin"
    reference.write_bytes(firmware)
    args.firmware = reference
    console = None
    try:
        if args.serial:
            import serial
            console = serial.Serial(None, 115200, timeout=.2)
            console.dtr = False
            console.rts = False
            console.port = args.serial
            console.open()
            console.reset_input_buffer()
        try:
            with debugger(args.openocd, run_dir / "openocd.log") as debug:
                result = operate(debug, args, image, sdk, run_dir)
        except (ValueError, RuntimeError, OSError) as error:
            (run_dir / "error.json").write_text(json.dumps({"error": str(error)}) + "\n")
            state = "; target was not resumed" if (run_dir / "not-resumed.txt").exists() else ""
            raise RuntimeError(f"{error}{state}; logs={run_dir}") from error
        result.update(log_dir=str(run_dir), sdk_uuid=str(uuid.UUID(bytes=sdk)),
                      firmware_sha256=hashlib.sha256(firmware).hexdigest())
        (run_dir / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        if console:
            text = ""
            deadline = time.monotonic() + args.seconds
            with (run_dir / "console.log").open("w") as output:
                while time.monotonic() < deadline:
                    line = console.readline().decode(errors="replace")
                    if line:
                        text += line
                        output.write(line)
                        output.flush()
                        if not args.json:
                            print(line, end="", flush=True)
                        if args.expect and args.expect in text:
                            break
            if args.expect and args.expect not in text:
                raise RuntimeError(f"Flash operation verified, but missing console marker: {args.expect}; logs={run_dir}")
        if args.json:
            print(json.dumps(result))
        else:
            print(f"{args.action}: verified; changed={result['changed']}; logs={run_dir}")
            for allocation in result["allocations"]:
                print(f"{allocation['kind']:7} {allocation['id']} 0x{allocation['address']:05x} "
                      f"{allocation['size']} bytes flags=0x{allocation['flags']:02x} compatible={allocation['compatible']}")
    finally:
        if console:
            console.close()


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError) as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
