# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Passkey Entry against Bumble through pipes, Secure Connections or legacy.

The Toit fixture (smp-passkey.toit) prints SMP PDUs as hex lines, "PASSKEY n"
when it displays a passkey, and "KEY-DIGEST <sha256>" when it has a key.
This side writes Bumble's PDUs as hex lines and "passkey n" when Bumble
displays the passkey the Toit side types. No controller encryption is
simulated.
"""

import argparse
import asyncio
import hashlib
import json
from types import SimpleNamespace

from bumble import core, hci, pairing, smp
from pyee import EventEmitter


class Connection(EventEmitter):
    EVENT_DISCONNECTION = "disconnection"
    EVENT_CONNECTION_ENCRYPTION_CHANGE = "encryption_change"
    EVENT_CONNECTION_ENCRYPTION_KEY_REFRESH = "key_refresh"
    handle = 1
    role = hci.Role.PERIPHERAL
    transport = core.PhysicalTransport.LE
    self_resolvable_address = None
    peer_resolvable_address = None
    self_address = hci.Address("06:05:04:03:02:01", hci.Address.RANDOM_DEVICE_ADDRESS)
    peer_address = hci.Address("01:02:03:04:05:06", hci.Address.PUBLIC_DEVICE_ADDRESS)
    is_encrypted = False

    def __init__(self, toit_role):
        super().__init__()
        self.process = None
        self.tasks = []
        if toit_role == "responder":
            self.role = hci.Role.CENTRAL
            self.self_address, self.peer_address = self.peer_address, self.self_address

    def cancel_on_disconnection(self, awaitable):
        task = asyncio.ensure_future(awaitable)
        self.tasks.append(task)
        return task

    def send_l2cap_pdu(self, cid, pdu):
        assert cid == smp.SMP_CID
        print(json.dumps({"direction": "to-toit", "opcode": pdu[0], "size": len(pdu)}), flush=True)
        self.process.stdin.write(pdu.hex().encode() + b"\n")


async def run(command, toit_role, bumble_io, legacy, wrong):
    connection = Connection(toit_role)
    toit_passkey = asyncio.get_running_loop().create_future()
    failures = []

    class Delegate(pairing.PairingDelegate):
        async def get_number(self):
            # The user reads the Toit display and types it here.
            value = await toit_passkey
            return (value + 1) % 1_000_000 if wrong else value

        async def display_number(self, number, digits):
            assert digits == 6 and 0 <= number < 1_000_000
            print(json.dumps({"bumble_displays": True}), flush=True)
            typed = (number + 1) % 1_000_000 if wrong else number
            connection.process.stdin.write(f"passkey {typed}\n".encode())

    def pairing_failure(connection_, reason):
        failures.append(int(reason))

    device = SimpleNamespace(on_pairing_start=lambda _: None, on_pairing_failure=pairing_failure,
                             host=SimpleNamespace(send_command_sync=lambda command: None))
    delegate = Delegate(io_capability=pairing.PairingDelegate.IoCapability(bumble_io),
                        local_initiator_key_distribution=0, local_responder_key_distribution=0)
    config = pairing.PairingConfig(sc=not legacy, mitm=True, bonding=False, delegate=delegate)
    manager = smp.Manager(device, lambda _: config)
    process = await asyncio.create_subprocess_exec(
        *command, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE)
    connection.process = process
    digest = None
    toit_failure = None
    try:
        async with asyncio.timeout(20):
            if toit_role == "responder":
                session = smp.Session(manager, connection, config, is_initiator=True)
                manager.sessions[connection.handle] = session
                session.send_pairing_request_command()
            while line := await process.stdout.readline():
                text = line.decode().strip()
                if text.startswith("PASSKEY "):
                    toit_passkey.set_result(int(text[8:]))
                    continue
                if text.startswith("KEY-DIGEST "):
                    digest = text[11:]
                    continue
                if text.startswith("FAILED "):
                    toit_failure = int(text[7:])
                    continue
                pdu = bytes.fromhex(text)
                print(json.dumps({"direction": "from-toit", "opcode": pdu[0], "size": len(pdu)}), flush=True)
                manager.on_smp_pdu(connection, pdu)
            assert await process.wait() == 0
        session = manager.sessions[connection.handle]
        if session.pairing_result is not None and session.pairing_result.done():
            # Retrieve a failed result so asyncio does not report it at exit.
            session.pairing_result.exception()
        if wrong:
            assert digest is None and (toit_failure == 4 or 4 in failures), (toit_failure, failures)
            return {"result": "PASS", "wrong_passkey_rejected": True}
        assert session.pairing_method == smp.PairingMethod.PASSKEY
        assert session.sc == (not legacy)
        key = session.stk if legacy else session.ltk
        assert digest == hashlib.sha256(bytes(key)[::-1]).hexdigest(), "keys differ"
        return {"result": "PASS", "legacy": legacy, "toit_role": toit_role, "bumble_io": bumble_io,
                "key_match": True}
    finally:
        for task in connection.tasks:
            task.cancel()
        await asyncio.gather(*connection.tasks, return_exceptions=True)
        if process.returncode is None:
            process.kill()
            await process.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toit-role", choices=["initiator", "responder"], default="initiator")
    parser.add_argument("--bumble-io", type=int, choices=[0, 2], required=True)
    parser.add_argument("--legacy", action="store_true")
    parser.add_argument("--wrong", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    result = asyncio.run(run(args.command, args.toit_role, args.bumble_io, args.legacy, args.wrong))
    print(json.dumps(result), flush=True)
