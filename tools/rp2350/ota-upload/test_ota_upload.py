#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.

import hashlib
import os
import pathlib
import pty
import select
import subprocess
import sys
import tempfile
import time
import unittest


UPLOADER = pathlib.Path(sys.argv[1]).resolve()
del sys.argv[1]


def read_exact(fd, size, timeout=5):
    deadline = time.monotonic() + timeout
    result = bytearray()
    while len(result) < size:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"wanted {size} bytes, received {len(result)}")
        readable, _, _ = select.select([fd], [], [], remaining)
        if not readable:
            raise TimeoutError(f"wanted {size} bytes, received {len(result)}")
        try:
            data = os.read(fd, size - len(result))
        except OSError as error:
            if error.errno == 5:  # The PTY slave has not been opened yet.
                time.sleep(0.01)
                continue
            raise
        if not data:
            raise EOFError("PTY closed")
        result.extend(data)
    return bytes(result)


def read_line(fd, timeout=5):
    result = bytearray()
    while True:
        byte = read_exact(fd, 1, timeout)
        if byte == b"\n":
            return bytes(result).decode()
        result.extend(byte)


def write_partial(fd, data):
    encoded = data.encode() if isinstance(data, str) else data
    steps = [1, 2, 5, 3, 11]
    offset = 0
    index = 0
    while offset < len(encoded):
        amount = min(steps[index % len(steps)], len(encoded) - offset)
        os.write(fd, encoded[offset:offset + amount])
        offset += amount
        index += 1
        time.sleep(0.001)


class UploadFixture:
    def __init__(self, image):
        self.directory = tempfile.TemporaryDirectory()
        self.image_path = pathlib.Path(self.directory.name) / "image.bin"
        self.image_path.write_bytes(image)
        self.master, self.slave = pty.openpty()
        self.port = os.ttyname(self.slave)
        self.process = subprocess.Popen(
            [str(UPLOADER), "--port", self.port, "--no-reboot", str(self.image_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def finish(self, timeout=8):
        stdout, stderr = self.process.communicate(timeout=timeout)
        os.close(self.master)
        os.close(self.slave)
        self.directory.cleanup()
        return self.process.returncode, stdout, stderr

    def info(self):
        assert read_line(self.master) == "TOIT-OTA INFO"
        write_partial(self.master, "unrelated startup log\r\n")
        write_partial(self.master, "TOIT-OTA INFO 1 0 0 131072\r\n")


class OtaUploadTest(unittest.TestCase):
    def test_partial_io_and_chunk_acknowledgements(self):
        image = bytes((index * 37 + 11) & 0xff for index in range(9001))
        fixture = UploadFixture(image)
        fixture.info()

        write_command = read_line(fixture.master)
        words = write_command.split()
        self.assertEqual(words[:2], ["TOIT-OTA", "WRITE"])
        self.assertEqual(int(words[2]), len(image))
        self.assertEqual(words[3], hashlib.sha256(image).hexdigest())
        write_partial(fixture.master, "flash worker ready\nTOIT-OTA READY 4096\n")

        received = bytearray()
        while len(received) < len(image):
            amount = min(4096, len(image) - len(received))
            received.extend(read_exact(fixture.master, amount))
            write_partial(fixture.master, "chunk log\n")
            write_partial(fixture.master, f"TOIT-OTA ACK {len(received)}\n")
        self.assertEqual(bytes(received), image)
        write_partial(fixture.master, "TOIT-OTA COMMITTED\n")

        returncode, stdout, stderr = fixture.finish()
        self.assertEqual(returncode, 0, stderr)
        self.assertIn("OTA image committed", stdout)
        self.assertIn(f"Uploaded {len(image)}/{len(image)} bytes", stderr)

    def test_device_error(self):
        fixture = UploadFixture(b"error-case")
        fixture.info()
        self.assertTrue(read_line(fixture.master).startswith("TOIT-OTA WRITE "))
        write_partial(fixture.master, "TOIT-OTA ERROR flash-busy\n")
        returncode, _, stderr = fixture.finish()
        self.assertEqual(returncode, 1)
        self.assertIn("device rejected OTA request", stderr)
        self.assertIn("flash-busy", stderr)

    def test_bad_ack(self):
        image = b"bad-ack"
        fixture = UploadFixture(image)
        fixture.info()
        self.assertTrue(read_line(fixture.master).startswith("TOIT-OTA WRITE "))
        write_partial(fixture.master, "TOIT-OTA READY 4096\n")
        self.assertEqual(read_exact(fixture.master, len(image)), image)
        write_partial(fixture.master, f"TOIT-OTA ACK {len(image) + 1}\n")
        returncode, _, stderr = fixture.finish()
        self.assertEqual(returncode, 1)
        self.assertIn("bad ACK offset", stderr)

    def test_info_timeout(self):
        fixture = UploadFixture(b"timeout-case")
        self.assertEqual(read_line(fixture.master), "TOIT-OTA INFO")
        returncode, _, stderr = fixture.finish(timeout=8)
        self.assertEqual(returncode, 1)
        self.assertIn("timed out", stderr)


if __name__ == "__main__":
    unittest.main()
