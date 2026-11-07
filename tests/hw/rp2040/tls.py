#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Run authenticated TLS over USB against Python/OpenSSL, then restore the Pico."""
import argparse
import base64
from pathlib import Path
import re
import ssl
import subprocess
import sys
import tempfile
import time

import serial

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/rp2040"))
import upload


def context(directory):
    source = (ROOT / "tests/tls-no-net-test.toit").read_text()

    def pem(name):
        value = re.search(r"^" + name + r' ::= .*?"""\\\n(.*?)"""',
                          source, re.MULTILINE | re.DOTALL)
        if not value:
            raise ValueError(f"Missing test certificate: {name}")
        return value[1] + "\n"

    cert = directory / "server.pem"
    key = directory / "server-key.pem"
    cert.write_text(pem("TEST-LOCALHOST-CERT-DIRECTLY-SIGNED"))
    key.write_text(pem("TEST-LOCALHOST-KEY-DIRECTLY-SIGNED"))
    result = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    result.minimum_version = result.maximum_version = ssl.TLSVersion.TLSv1_2
    result.set_ciphers("ECDHE-ECDSA-AES128-GCM-SHA256")
    result.load_cert_chain(cert, key)
    result.load_verify_locations(cadata=pem("TEST-ROOT-CERT"))
    result.verify_mode = ssl.CERT_REQUIRED
    return result


def exercise(port, ctx):
    deadline = time.monotonic() + 360
    expected = {"unset", "valid", "wrong-host", "untrusted", "future", "expired", "valid-again"}
    authenticated = set()
    echoed = 0
    peer = incoming = outgoing = mode = None
    while time.monotonic() < deadline:
        try:
            with upload.connect(serial, port) as stream:
                console = upload.Console(stream)
                while time.monotonic() < deadline:
                    line = console.line(deadline)
                    if line.startswith("tls-rp2040: READY "):
                        mode = line.split()[-1]
                        if mode not in expected:
                            raise RuntimeError(f"Repeated or unknown scenario: {mode}")
                        expected.remove(mode)
                        incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
                        peer = ctx.wrap_bio(incoming, outgoing, server_side=True)
                    elif line.startswith("TLS "):
                        if peer is None:
                            raise RuntimeError("TLS record before scenario start")
                        incoming.write(base64.b64decode(line[4:], validate=True))
                        try:
                            peer.do_handshake()
                            if mode in ("valid", "valid-again"):
                                if not peer.getpeercert():
                                    raise RuntimeError("Client certificate not verified")
                                authenticated.add(mode)
                            while True:
                                data = peer.read(4096)
                                if not data:
                                    break
                                if mode not in ("valid", "valid-again"):
                                    raise RuntimeError("Unauthenticated scenario sent plaintext")
                                echoed += len(data)
                                if peer.write(data) != len(data):
                                    raise RuntimeError("Short echo write")
                        except ssl.SSLWantReadError:
                            pass
                        except ssl.SSLError:
                            if mode in ("valid", "valid-again"):
                                raise
                        while outgoing.pending:
                            console.command("TLS " + base64.b64encode(outgoing.read(512)).decode())
                    else:
                        print(line, flush=True)
                        if line.startswith("jag decode ") or "FAIL" in line:
                            raise RuntimeError(line)
                        if line == "tls-rp2040: PASS":
                            if expected or authenticated != {"valid", "valid-again"} or echoed != 6722:
                                raise RuntimeError("Incomplete TLS verification")
                            print("PASS: mutual TLS, 6722 echoed bytes, five certificate rejections and clock correction", flush=True)
                            return
        except (serial.SerialException, FileNotFoundError):
            time.sleep(.1)
    raise TimeoutError("TLS hardware test did not finish")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uploader", required=True, type=Path)
    parser.add_argument("--port", required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--restore-image", required=True, type=Path)
    args = parser.parse_args()
    for path in (args.image, args.restore_image):
        upload.validate_image(path.read_bytes())

    def install(path):
        subprocess.run([str(args.uploader), "--port", args.port, "--id", args.id,
                        str(path)], check=True)

    with tempfile.TemporaryDirectory() as directory:
        ctx = context(Path(directory))
        try:
            install(args.image)
            exercise(args.port, ctx)
        finally:
            install(args.restore_image)
            # Load by path: this fixture is named stdio.py, not Python's stdio.
            import stdio
            stream, _ = stdio.wait_application(args.port, "RP2040 VM/GC/timer smoke: PASS")
            stream.close()


if __name__ == "__main__":
    main()
