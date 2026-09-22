# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Independent SMP exchange through pipes; no controller encryption is simulated."""

import argparse
import asyncio
import hashlib
import importlib.metadata
import json
from types import SimpleNamespace

from bumble import core, crypto, hci, pairing, smp
from cryptography.hazmat.primitives.asymmetric import ec
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

    def __init__(self, process, toit_role, corrupt_dhkey, invalid_public_key, peer_features):
        super().__init__()
        self.process = process
        self.tasks = []
        self.sent = []
        self.corrupt_dhkey = corrupt_dhkey
        self.corrupted = 0
        self.invalid_public_key = invalid_public_key
        self.public_keys_replaced = 0
        self.valid_public_key = None
        self.toit_public_key = None
        self.peer_features = peer_features
        if toit_role == "responder":
            self.role = hci.Role.CENTRAL
            self.self_address, self.peer_address = self.peer_address, self.self_address

    def cancel_on_disconnection(self, awaitable):
        task = asyncio.ensure_future(awaitable)
        self.tasks.append(task)
        return task

    def send_l2cap_pdu(self, cid, pdu):
        assert cid == smp.SMP_CID and pdu[0] != 5
        if pdu[0] in (1, 2):
            assert bytes(pdu) == bytes([pdu[0], *self.peer_features])
        if self.corrupt_dhkey and pdu[0] == 0x0D:
            assert len(pdu) == 17 and self.corrupted == 0
            pdu = bytes([pdu[0], pdu[1] ^ 1]) + bytes(pdu[2:])
            self.corrupted += 1
        if self.invalid_public_key and pdu[0] == 0x0C:
            assert len(pdu) == 65 and self.public_keys_replaced == 0
            if self.invalid_public_key == "same-x":
                # Q and -Q are distinct valid points. Reflect Toit's actual
                # public X, not a malformed or unrelated tester point.
                assert self.toit_public_key is not None
                public = self.toit_public_key
                prime = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
                y = prime - int.from_bytes(public[32:], "little")
                reflected = public[:32] + y.to_bytes(32, "little")
                assert reflected != public
                ec.EllipticCurvePublicNumbers(
                    int.from_bytes(reflected[:32], "little"), y,
                    ec.SECP256R1()).public_key()
                pdu = bytes([0x0C]) + reflected
            else:
                assert bytes(pdu[1:]) == self.valid_public_key
                if self.invalid_public_key == "zero":
                    pdu = bytes([0x0C]) + bytes(64)
                elif self.invalid_public_key == "flip-y":
                    pdu = bytes(pdu[:33]) + bytes([pdu[33] ^ 1]) + bytes(pdu[34:])
                else:
                    # Retain X from Bumble's fresh valid key; replace only Y.
                    y = 1 if self.invalid_public_key == "one-y" else 0
                    pdu = pdu[:33] + y.to_bytes(32, "little")
                try:
                    ec.EllipticCurvePublicNumbers(
                        int.from_bytes(pdu[1:33], "little"),
                        int.from_bytes(pdu[33:], "little"), ec.SECP256R1()).public_key()
                except ValueError:
                    pass
                else:
                    raise AssertionError("substituted point must be off curve")
            self.public_keys_replaced += 1
        self.sent.append(pdu[0])
        print(json.dumps({"direction": "to-toit", "opcode": pdu[0], "size": len(pdu)}), flush=True)
        self.process.stdin.write(pdu.hex().encode() + b"\n")


async def run(command, toit_role, numeric, reject, corrupt_dhkey, invalid_public_key,
              security_request, peer_no_mitm, peer_io, toit_display):
    peer_io = (1 if numeric else 3) if peer_io is None else peer_io
    peer_features = [peer_io, 0, 12 if numeric and not peer_no_mitm else 8, 16, 0, 0]
    connection = Connection(None, toit_role, corrupt_dhkey, invalid_public_key, peer_features)
    encryption_requests = []
    failures = []

    def pairing_failure(connection_, reason):
        assert (reject or corrupt_dhkey or invalid_public_key) and connection_ is connection
        assert reason == (0x0B if corrupt_dhkey or invalid_public_key else 0x0C)
        failures.append(int(reason))

    def encryption_request(command):
        assert isinstance(command, hci.HCI_LE_Enable_Encryption_Command)
        assert command.connection_handle == connection.handle
        assert command.random_number == bytes(8) and command.encrypted_diversifier == 0
        encryption_requests.append(command)
        # Deliberately do not emit an encryption-change event.

    device = SimpleNamespace(on_pairing_start=lambda _: None, on_pairing_failure=pairing_failure,
                             host=SimpleNamespace(send_command_sync=encryption_request))
    peer_number = asyncio.get_running_loop().create_future()
    approval = asyncio.get_running_loop().create_future()

    class Delegate(pairing.PairingDelegate):
        async def compare_numbers(self, number, digits):
            assert numeric and digits == 6 and 0 <= number < 1_000_000
            assert not peer_number.done()
            peer_number.set_result(number)
            return await approval

    delegate = Delegate(
        io_capability=pairing.PairingDelegate.IoCapability(peer_io),
        local_initiator_key_distribution=0, local_responder_key_distribution=0)
    config = pairing.PairingConfig(sc=True, mitm=numeric and not peer_no_mitm,
                                  bonding=False, delegate=delegate)
    manager = smp.Manager(device, lambda _: config)
    if invalid_public_key and invalid_public_key != "same-x":
        # Pin the tester's key to a fresh even scalar, as SM p30 Table 4.9
        # requires. This private Manager hook is specific to pinned Bumble.
        for _ in range(64):
            key = ec.generate_private_key(ec.SECP256R1())
            scalar = key.private_numbers().private_value
            if scalar & 1:
                continue
            candidate = crypto.EccKey.from_private_key_bytes(scalar.to_bytes(32, "big"))
            public = candidate.x[::-1] + candidate.y[::-1]
            changed_y = int.from_bytes(public[32:], "little") ^ 1
            if invalid_public_key in ("zero-y", "one-y"):
                changed_y = int(invalid_public_key == "one-y")
            x = 0 if invalid_public_key == "zero" else int.from_bytes(public[:32], "little")
            y = 0 if invalid_public_key == "zero" else changed_y
            try:
                ec.EllipticCurvePublicNumbers(x, y, ec.SECP256R1()).public_key()
            except ValueError:
                manager._ecc_key = candidate
                connection.valid_public_key = public
                break
        else:
            raise AssertionError("could not generate an even-scalar invalid-point probe")
    # Complete fallible fixture preparation before starting a child process.
    process = await asyncio.create_subprocess_exec(
        *command, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE
    )
    connection.process = process
    received = []
    toit_nonce = None
    matched = False
    rejected = False
    try:
        async with asyncio.timeout(15):
            if toit_role == "responder":
                session = smp.Session(manager, connection, config, is_initiator=True)
                manager.sessions[connection.handle] = session
                session.send_pairing_request_command()
            while line := await process.stdout.readline():
                text = line.decode().strip()
                if text.startswith("NUMBER "):
                    assert numeric and not matched and not approval.done()
                    number = int(text[7:])
                    assert 0 <= number < 1_000_000 and number == await peer_number
                    approval.set_result(True)
                    process.stdin.write(b"reject\n" if reject else b"approve\n")
                    print(json.dumps({"numeric_comparison_matched": True}), flush=True)
                    continue
                if text.startswith("KEY-DIGEST "):
                    assert not matched and not reject and not corrupt_dhkey and not invalid_public_key
                    session = manager.sessions[connection.handle]
                    assert session.sc and not session.bonding
                    expected_method = (smp.PairingMethod.NUMERIC_COMPARISON
                                       if numeric else smp.PairingMethod.JUST_WORKS)
                    assert session.pairing_method == expected_method
                    if numeric:
                        assert approval.done() and approval.result() is True
                    assert connection.sent[-1] == 0x0D and received[-1] == 0x0D
                    assert len(session.ltk) == 16
                    # Bumble stores Bluetooth little-endian key bytes; Toit's
                    # pairing session exposes the big-endian crypto result.
                    assert hashlib.sha256(session.ltk[::-1]).hexdigest() == text[11:]
                    if toit_role == "responder":
                        assert len(encryption_requests) == 1
                        assert encryption_requests[0].long_term_key == session.ltk
                    else:
                        assert not encryption_requests
                    matched = True
                    continue
                if text == "PUBLIC-KEY-REJECTED":
                    assert invalid_public_key and not matched and not rejected
                    assert connection.public_keys_replaced == 1
                    assert failures == [0x0B] and not encryption_requests
                    session = manager.sessions[connection.handle]
                    assert session.completed
                    if session.pairing_result is not None:
                        assert session.pairing_result.done()
                        assert session.pairing_result.exception() is not None
                    assert 0x0D not in received and 0x0D not in connection.sent
                    rejected = True
                    continue
                if text in ("REJECTED", "DHKEY-REJECTED"):
                    assert (reject or corrupt_dhkey) and not rejected and not matched
                    assert text == ("DHKEY-REJECTED" if corrupt_dhkey else "REJECTED")
                    assert failures == [0x0B if corrupt_dhkey else 0x0C] and not encryption_requests
                    assert connection.corrupted == int(corrupt_dhkey)
                    session = manager.sessions[connection.handle]
                    assert session.completed
                    if session.pairing_result is not None:
                        assert session.pairing_result.done()
                        assert session.pairing_result.exception() is not None
                    rejected = True
                    continue
                assert not matched
                pdu = bytes.fromhex(text)
                if pdu[0] == 0x0C:
                    assert len(pdu) == 65 and connection.toit_public_key is None
                    connection.toit_public_key = bytes(pdu[1:])
                if pdu[0] == 4:
                    assert len(pdu) == 17 and toit_nonce is None
                    toit_nonce = pdu[1:]
                if pdu[0] in (1, 2):
                    assert pdu == bytes([pdu[0], 1 if numeric or toit_display else 3,
                                         0, 12 if numeric else 8, 16, 0, 0])
                assert pdu[0] != 5 or ((reject or corrupt_dhkey or invalid_public_key) and
                                      pdu == bytes([5, 0x0B if corrupt_dhkey or invalid_public_key else 0x0C]))
                received.append(pdu[0])
                print(json.dumps({"direction": "from-toit", "opcode": pdu[0], "size": len(pdu)}), flush=True)
                if security_request and pdu[0] == 1:
                    assert received.count(1) == 1 and 0x0B not in connection.sent
                    # Use Bumble's actual peripheral request API before its
                    # normal Pairing Request handler sends Pairing Response.
                    manager.request_pairing(connection)
                manager.on_smp_pdu(connection, pdu)
            assert await process.wait() == 0
            assert rejected if reject or corrupt_dhkey or invalid_public_key else matched
            assert connection.sent.count(0x0B) == int(security_request)
            for task in connection.tasks:
                if task.done():
                    task.result()
            assert not connection.is_encrypted
        result = {"result": "PASS", "bumble": importlib.metadata.version("bumble"),
                          "key_match": matched, "rejected": rejected,
                          "dhkey_checks_corrupted": connection.corrupted,
                          "public_keys_replaced": connection.public_keys_replaced,
                          "public_key_shape": invalid_public_key,
                          "same_x_valid_point": invalid_public_key == "same-x",
                          "tester_even_scalar": connection.valid_public_key is not None,
                          "security_requests": connection.sent.count(0x0B),
                          "controller_encryption": False,
                          "toit_role": toit_role, "encryption_requests": len(encryption_requests),
                          "numeric_comparison": numeric,
                          "peer_no_mitm": peer_no_mitm,
                          "peer_io": peer_io,
                          "toit_io": 1 if numeric or toit_display else 3,
                          "received": received,
                          "sent": connection.sent}
        return result, toit_nonce
    finally:
        for task in connection.tasks:
            task.cancel()
        await asyncio.gather(*connection.tasks, return_exceptions=True)
        if process.returncode is None:
            process.kill()
            await process.wait()


async def run_rounds(args):
    nonces = set()
    for round_index in range(args.rounds):
        result, nonce = await run(
            args.command, args.toit_role, args.numeric, args.reject,
            args.corrupt_dhkey, args.invalid_public_key, args.security_request,
            args.peer_no_mitm, args.peer_io, args.toit_display)
        if args.rounds > 1:
            assert result["key_match"] and nonce is not None and len(nonce) == 16
            assert nonce not in nonces, "Toit reused a pairing nonce"
            nonces.add(nonce)
            print(json.dumps({"round_complete": round_index + 1, "key_match": True}), flush=True)
    result["rounds"] = args.rounds
    result["distinct_toit_nonces"] = len(nonces) if args.rounds > 1 else None
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    if not __debug__:
        raise RuntimeError("Run without Python -O: assertions are required")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toit-role", choices=["initiator", "responder"], default="initiator")
    parser.add_argument("--numeric", action="store_true")
    parser.add_argument("--peer-no-mitm", action="store_true")
    parser.add_argument("--peer-io", type=int, choices=range(5))
    parser.add_argument("--toit-display", action="store_true")
    parser.add_argument("--rounds", type=int, choices=(1, 3), default=1)
    parser.add_argument("--reject", action="store_true")
    parser.add_argument("--corrupt-dhkey", action="store_true")
    parser.add_argument("--invalid-public-key", action="store_const", const="zero")
    parser.add_argument("--invalid-public-key-shape", dest="invalid_public_key",
                        choices=["zero", "zero-y", "one-y", "flip-y", "same-x"])
    parser.add_argument("--security-request", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command:
        parser.error("a Toit command and SMP fixture are required")
    if args.invalid_public_key == "same-x" and args.toit_role != "initiator":
        parser.error("same-x reflection requires Toit to send its public key first")
    if args.reject and not args.numeric:
        parser.error("--reject requires --numeric")
    if args.peer_no_mitm and (not args.numeric or args.reject or args.security_request):
        parser.error("--peer-no-mitm requires a successful numeric case without Security Request")
    if args.numeric and args.peer_io not in (None, 1, 4):
        parser.error("numeric cases require peer IO 1 or 4")
    if args.rounds > 1 and (args.reject or args.corrupt_dhkey or args.invalid_public_key):
        parser.error("three-round nonce checks require successful pairings")
    if args.corrupt_dhkey and args.numeric:
        parser.error("--corrupt-dhkey currently exercises Just Works only")
    if args.invalid_public_key and (args.numeric or args.corrupt_dhkey):
        parser.error("--invalid-public-key requires Just Works without another fault")
    if args.security_request and (args.toit_role != "initiator" or args.reject or
                                  args.corrupt_dhkey or args.invalid_public_key):
        parser.error("--security-request requires a successful Toit-initiator case")
    asyncio.run(run_rounds(args))
