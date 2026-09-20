#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Encode a relocatable test container as a Toit program asset."""
import pathlib
import struct
import sys

data = pathlib.Path(sys.argv[1]).read_bytes()
name = b"container"
result = struct.pack("<III", 0x6395F9F1, 1, len(name))
result += name + bytes(-len(name) % 4)
result += struct.pack("<I", len(data)) + data + bytes(-len(data) % 4)
pathlib.Path(sys.argv[2]).write_bytes(result)
