# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Run Toit's ATT client against Bumble's GATT server, with synthetic HCI setup."""

import argparse
import asyncio
import importlib.metadata
import json

from bumble import att, gatt, gatt_server


class Bearer:
    handle = 0x234
    att_mtu = 23
    encryption = False
    authenticated = False

    def on_att_mtu_update(self, mtu):
        assert mtu == 23
        self.att_mtu = mtu


class PipeDevice:
    def __init__(self, process):
        self.process = process
        self.responses = 0

    def send_l2cap_pdu(self, handle, cid, pdu):
        assert handle == 0x234 and cid == att.ATT_CID
        assert 0 < len(pdu) <= 23
        self.responses += 1
        print(json.dumps({"direction": "to-toit", "pdu": pdu.hex()}), flush=True)
        self.process.stdin.write(pdu.hex().encode() + b"\n")


async def run(command):
    process = await asyncio.create_subprocess_exec(
        *command, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE
    )
    device = PipeDevice(process)
    bearer = Bearer()
    server = gatt_server.Server(device)
    characteristic = gatt.Characteristic(
        "FFF1", gatt.Characteristic.Properties.READ | gatt.Characteristic.Properties.WRITE,
        att.Attribute.Permissions.READABLE | att.Attribute.Permissions.WRITEABLE, b"\x07"
    )
    server.add_service(gatt.Service("FFF0", [characteristic]))
    complete = False
    requests = 0
    try:
        async with asyncio.timeout(30):
            while line := await process.stdout.readline():
                line = line.decode().strip()
                if line == "ATT_CLIENT COMPLETE values=12 recovered=true":
                    assert not complete
                    complete = True
                    continue
                assert not complete and line.startswith("PDU "), line
                packet = bytes.fromhex(line[4:])
                assert 0 < len(packet) <= 23
                requests += 1
                print(json.dumps({"direction": "from-toit", "pdu": packet.hex()}), flush=True)
                server.on_gatt_pdu(bearer, att.ATT_PDU.from_bytes(packet))
            assert await process.wait() == 0
            assert complete and requests == device.responses
            assert characteristic.value == b"*"
        print(json.dumps({"result": "PASS", "bumble": importlib.metadata.version("bumble"),
                          "exchanges": requests, "role": "toit-client", "radio": False}),
              flush=True)
    finally:
        if process.returncode is None:
            process.kill()
            await process.wait()


if __name__ == "__main__":
    if not __debug__:
        raise RuntimeError("Run without Python -O: assertions are required")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command:
        parser.error("a Toit VM command and client fixture are required")
    asyncio.run(run(args.command))
