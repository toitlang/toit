# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
import importlib.util
import pathlib
import struct
import time
import unittest
import zlib

spec = importlib.util.spec_from_file_location("upload", pathlib.Path(__file__).parents[1] / "upload.py")
upload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upload)


class Peer:
    """Checks framing and acknowledgements, including fragmented serial reads."""
    def __init__(self, reject=False):
        self.output = bytearray()
        self.data = bytearray()
        self.block_size = 0
        self.reject = reject
        self.committed = False

    def write(self, data):
        if self.block_size:
            assert len(data) == self.block_size
            assert zlib.crc32(data) == self.block_crc
            self.data.extend(data)
            self.block_size = 0
            self.output.extend(f"OK block {len(self.data)}\r\n".encode())
            return len(data)
        parts = data.decode().strip().split()
        if parts[0] == "begin":
            self.size, self.crc, self.version = int(parts[1]), int(parts[2], 16), int(parts[3])
            self.output.extend(b"RP2040-UPDATER heartbeat\r\nOK begin\r\n")
        elif parts[0] == "block":
            assert int(parts[1]) == len(self.data)
            self.block_size, self.block_crc = int(parts[2]), int(parts[3], 16)
            self.output.extend(b"ERR block\n" if self.reject else b"READY block\n")
        elif parts[0] == "commit":
            assert len(self.data) == self.size
            assert zlib.crc32(self.data) == self.crc
            self.committed = True
            self.output.extend(b"OK commit\n")
        else:
            raise AssertionError(parts)
        return len(data)

    def flush(self):
        pass

    def read(self, _size):
        count = min(len(self.output), 3)
        data = bytes(self.output[:count])
        del self.output[:count]
        return data


class UploadTest(unittest.TestCase):
    def test_fragmented_transfer(self):
        peer = Peer()
        data = bytes(range(256)) * 35 + b"tail"
        upload.transfer(upload.Console(peer), data, 123)
        self.assertEqual(peer.data, data)
        self.assertEqual(peer.version, 123)
        self.assertTrue(peer.committed)

    def test_rejection_stops_before_payload(self):
        peer = Peer(reject=True)
        with self.assertRaisesRegex(RuntimeError, "ERR block"):
            upload.transfer(upload.Console(peer), b"abc", 123)
        self.assertFalse(peer.data)
        self.assertFalse(peer.committed)

    def test_read_timeout(self):
        with self.assertRaises(TimeoutError):
            upload.Console(Peer()).line(time.monotonic())

    def test_image_origin(self):
        data = bytearray(1024)
        struct.pack_into("<II", data, 256, 0x20042000, upload.APP_ADDRESS + 513)
        upload.validate_image(data)
        struct.pack_into("<I", data, 260, 0x10000201)
        with self.assertRaisesRegex(ValueError, "linked for"):
            upload.validate_image(data)
        with self.assertRaises(ValueError):
            upload.validate_image(b"short")


if __name__ == "__main__":
    unittest.main()
