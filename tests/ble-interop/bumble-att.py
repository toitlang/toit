# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Run Bumble's GATT client against a Toit ATT session through process pipes."""

import argparse
import asyncio
import contextlib
import importlib.metadata
import json

from bumble import att, gatt_client
from att_type_pages import type_pages
from att_transactions import transactions
from pyee import EventEmitter


class PipeBearer(EventEmitter):
    EVENT_DISCONNECTION = "disconnection"
    handle = 1
    att_mtu = 23

    def __init__(self, process):
        super().__init__()
        self.process = process
        self.client = gatt_client.Client(self)
        self.exchanges = 0
        self.updates_received = 0
        self.controls = asyncio.Queue()
        self.drop_confirmation = False
        self.confirmations_dropped = 0
        self.malformed_confirmation = False
        self.confirmations_corrupted = 0

    def on_att_mtu_update(self, mtu):
        self.att_mtu = mtu

    def send_l2cap_pdu(self, cid, pdu):
        assert cid == att.ATT_CID
        assert len(pdu) <= self.att_mtu
        if self.drop_confirmation and pdu == b"\x1e":
            self.confirmations_dropped += 1
            print(json.dumps({"fault": "confirmation-dropped", "pdu": pdu.hex()}), flush=True)
            return
        if self.malformed_confirmation and pdu == b"\x1e":
            self.confirmations_corrupted += 1
            pdu = b"\x1e\x00"
            print(json.dumps({"fault": "confirmation-corrupted", "pdu": pdu.hex()}), flush=True)
        print(json.dumps({"direction": "to-toit", "pdu": pdu.hex()}), flush=True)
        self.process.stdin.write(pdu.hex().encode() + b"\n")

    async def receive(self):
        while line := await self.process.stdout.readline():
            if line.startswith(b"@"):
                self.controls.put_nowait(line.decode().strip())
                continue
            packet = bytes.fromhex(line.decode().strip())
            assert len(packet) <= self.att_mtu
            print(json.dumps({"direction": "from-toit", "pdu": packet.hex()}), flush=True)
            if packet[0] in (0x1B, 0x1D):
                self.updates_received += 1
            else:
                self.exchanges += 1
            self.client.on_gatt_pdu(att.ATT_PDU.from_bytes(packet))
        raise RuntimeError("Toit ATT peer exited before test completion")


async def cases(client, mtu, boundaries):
    assert await client.request_mtu(mtu) == mtu
    services = await client.discover_services()
    assert len(services) == 1
    characteristics = await client.discover_characteristics([], service=services[0])
    assert len(characteristics) == 1
    handle = characteristics[0].handle
    assert await client.read_value(handle) == b"\x07"

    if boundaries:
        # Boundaries for acknowledged writes, Prepare Write parts, Read Blob
        # continuation, and Toit's internal/external message size transition.
        lengths = sorted({n for n in (
            0, 1, 128, 129, 512, mtu - 5, mtu - 4, mtu - 3,
            mtu - 2, mtu - 1, mtu, 2 * (mtu - 1)
        ) if 0 <= n <= 512})
        for length in lengths:
            expected = bytes((i * 17 + length) % 251 for i in range(length))
            await client.write_value(handle, expected, with_response=True)
            assert await client.read_value(handle) == expected
        print(json.dumps({"boundaries": lengths, "mtu": mtu}), flush=True)

    # Exercise Bumble's own fragmentation and long-read procedures.
    value = bytes(i % 251 for i in range(512))
    await client.write_value(handle, value, with_response=True)
    assert await client.read_value(handle) == value

    async def prepare(offset, value):
        response = await client.send_request(att.ATT_Prepare_Write_Request(
            attribute_handle=handle, value_offset=offset, part_attribute_value=value
        ))
        assert isinstance(response, att.ATT_Prepare_Write_Response)
        assert response.attribute_handle == handle
        assert response.value_offset == offset
        assert response.part_attribute_value == value

    async def execute(flags):
        return await client.send_request(att.ATT_Execute_Write_Request(flags=flags))

    await prepare(0, b"cancelled")
    assert isinstance(await execute(0), att.ATT_Execute_Write_Response)
    assert await client.read_value(handle) == value

    await client.write_value(handle, b"old", with_response=True)
    await prepare(0, b"abc")
    await prepare(10, b"gap")
    response = await execute(1)
    assert isinstance(response, att.ATT_Error_Response)
    assert response.request_opcode_in_error == 0x18
    assert response.attribute_handle_in_error == handle
    assert response.error_code == att.ATT_INVALID_OFFSET_ERROR
    assert await client.read_value(handle) == b"old"
    assert isinstance(await execute(1), att.ATT_Execute_Write_Response)
    assert await client.read_value(handle) == b"old"
    await client.write_value(handle, value, with_response=True)
    assert await client.read_value(handle) == value


async def notifications(bearer):
    client = bearer.client
    characteristic = client.services[0].characteristics[0]
    received = asyncio.Queue()

    async def trigger(value, expected):
        bearer.process.stdin.write(b"@notify " + value.hex().encode() + b"\n")
        assert await bearer.controls.get() == expected

    await trigger(b"disabled", "@suppressed")
    await client.subscribe(characteristic, received.put_nowait)
    # At MTU 23 this also covers the largest untruncated notification payload.
    for value in (b"", b"first", bytes(range(20))):
        await trigger(value, "@sent")
        assert await received.get() == value
    await client.unsubscribe(characteristic, received.put_nowait)
    await trigger(b"unsubscribed", "@suppressed")
    assert await client.read_value(characteristic.handle) == b"\x09"
    assert received.empty()
    await client.subscribe(characteristic, received.put_nowait)
    await trigger(b"again", "@sent")
    assert await received.get() == b"again"
    await client.unsubscribe(characteristic, received.put_nowait)
    print(json.dumps({"notifications": 4, "unsubscribe": True, "resubscribe": True}), flush=True)


async def indications(bearer, drop_confirmation, malformed_confirmation):
    client = bearer.client
    characteristic = client.services[0].characteristics[0]
    received = asyncio.Queue()
    await client.subscribe(characteristic, received.put_nowait, prefer_notify=False)
    if malformed_confirmation:
        bearer.malformed_confirmation = True
        bearer.process.stdin.write(b"@malformed 626164\n")
        assert await received.get() == b"bad"
        assert await bearer.controls.get() == "@malformed-rejected"
        assert bearer.confirmations_corrupted == 1
        print(json.dumps({"malformed_confirmation_rejected": True}), flush=True)
        return
    if drop_confirmation:
        bearer.drop_confirmation = True
        started = asyncio.get_running_loop().time()
        bearer.process.stdin.write(b"@timeout 74696d656f7574\n")
        assert await received.get() == b"timeout"
        assert await bearer.controls.get() == "@timed-out"
        elapsed = asyncio.get_running_loop().time() - started
        assert elapsed >= 2.5  # The real owner uses a three-second deadline.
        assert bearer.confirmations_dropped == 1
        print(json.dumps({"indication_timeout": True, "elapsed_seconds": elapsed}), flush=True)
        return
    for value in (b"first", bytes(range(20))):
        bearer.process.stdin.write(b"@indicate " + value.hex().encode() + b"\n")
        assert await received.get() == value
        # This marker is emitted only after Toit's real Indication.wait returns.
        assert await bearer.controls.get() == "@confirmed"
        assert await client.read_value(characteristic.handle) == b"\x09"
    await client.unsubscribe(characteristic, received.put_nowait)
    print(json.dumps({"indications": 2, "confirmed": True}), flush=True)


async def descriptors(bearer, mtu):
    client = bearer.client
    assert await client.request_mtu(mtu) == mtu
    services = await client.discover_services()
    assert len(services) == 1
    values = await client.discover_characteristics([], service=services[0])
    assert len(values) == 1
    records = await client.discover_descriptors(values[0])
    assert len(records) == 4
    assert [record.type.to_bytes() for record in records] == [b"\xf2\xff", b"\xf3\xff", b"\x00\x29", b"\x01\x29"]
    encrypted, authenticated, extended, description = (record.handle for record in records)
    assert values[0].properties == 0x82  # Read and Extended Properties, not value write.
    assert await client.read_value(extended) == b"\x02\x00"  # Writable Auxiliaries only.
    response = await client.send_request(att.ATT_Write_Request(
        attribute_handle=extended, attribute_value=b"\x00\x00"))
    assert isinstance(response, att.ATT_Error_Response)
    assert response.error_code == att.ATT_WRITE_NOT_PERMITTED_ERROR
    assert response.attribute_handle_in_error == extended

    async def security(state):
        bearer.process.stdin.write(f"@security {state}\n".encode())
        assert await bearer.controls.get() == f"@security {state}"

    async def denied(handle):
        for request in (
            att.ATT_Read_Request(attribute_handle=handle),
            att.ATT_Write_Request(attribute_handle=handle, attribute_value=b"bad"),
            att.ATT_Prepare_Write_Request(attribute_handle=handle, value_offset=0,
                                          part_attribute_value=b"bad"),
        ):
            response = await client.send_request(request)
            assert isinstance(response, att.ATT_Error_Response)
            assert response.request_opcode_in_error == request.op_code
            assert response.attribute_handle_in_error == handle
            assert response.error_code == att.ATT_INSUFFICIENT_AUTHENTICATION_ERROR

    await denied(encrypted)
    await denied(authenticated)
    await denied(description)
    await security(1)
    await denied(authenticated)
    await denied(description)
    assert await client.read_value(encrypted) == b"\x07"
    payload = bytes(i % 251 for i in range(512))
    await client.write_value(encrypted, payload, with_response=True)
    assert await client.read_value(encrypted) == payload
    await security(2)
    assert await client.read_value(authenticated) == b"\x07"
    for handle in (encrypted, authenticated):
        await client.write_value(handle, payload, with_response=True)
        assert await client.read_value(handle) == payload
    response = await client.send_request(att.ATT_Prepare_Write_Request(
        attribute_handle=authenticated, value_offset=0, part_attribute_value=b"bad"))
    assert isinstance(response, att.ATT_Prepare_Write_Response)
    await security(1)
    response = await client.send_request(att.ATT_Execute_Write_Request(flags=1))
    assert isinstance(response, att.ATT_Error_Response)
    assert response.error_code == att.ATT_INSUFFICIENT_AUTHENTICATION_ERROR
    assert response.attribute_handle_in_error == authenticated
    assert response.request_opcode_in_error == 0x18
    await security(2)
    assert await client.read_value(authenticated) == payload
    for handle in (encrypted, authenticated):
        await client.write_value(handle, b"", with_response=True)
        assert await client.read_value(handle) == b""

    text = b"A" * 509 + "€".encode()
    await client.write_value(description, text, with_response=True)
    assert await client.read_value(description) == text
    for malformed in (b"\xc3", b"\xc0\xaf", b"\xed\xa0\x80", b"\xf4\x90\x80\x80"):
        response = await client.send_request(att.ATT_Write_Request(
            attribute_handle=description, attribute_value=malformed))
        assert isinstance(response, att.ATT_Error_Response)
        assert response.error_code == 0x13
        assert response.attribute_handle_in_error == description
        assert response.request_opcode_in_error == 0x12
    assert await client.read_value(description) == text
    for handle, value in ((encrypted, b"changed"), (description, b"\xc3")):
        response = await client.send_request(att.ATT_Prepare_Write_Request(
            attribute_handle=handle, value_offset=0, part_attribute_value=value))
        assert isinstance(response, att.ATT_Prepare_Write_Response)
    response = await client.send_request(att.ATT_Execute_Write_Request(flags=1))
    assert isinstance(response, att.ATT_Error_Response)
    assert response.error_code == 0x13
    assert response.attribute_handle_in_error == description
    assert response.request_opcode_in_error == 0x18
    assert await client.read_value(encrypted) == b""
    assert await client.read_value(description) == text
    for offset, value in ((0, b"\xe2"), (1, b"\x82\xac")):
        response = await client.send_request(att.ATT_Prepare_Write_Request(
            attribute_handle=description, value_offset=offset, part_attribute_value=value))
        assert isinstance(response, att.ATT_Prepare_Write_Response)
        assert response.value_offset == offset and response.part_attribute_value == value
    assert isinstance(await client.send_request(att.ATT_Execute_Write_Request(flags=1)),
                      att.ATT_Execute_Write_Response)
    assert await client.read_value(description) == "€".encode()
    await client.write_value(description, b"", with_response=True)
    assert await client.read_value(description) == b""


async def scenario(bearer, mtu, boundaries, updates, indicate, drop_confirmation, malformed_confirmation, descriptor_mode=False, type_page_mode=False, transaction_mode=False):
    if transaction_mode:
        await transactions(bearer.client, mtu)
        return
    if type_page_mode:
        await type_pages(bearer.client)
        return
    if descriptor_mode:
        await descriptors(bearer, mtu)
        return
    await cases(bearer.client, mtu, boundaries)
    if updates:
        await notifications(bearer)
    if indicate:
        await indications(bearer, drop_confirmation, malformed_confirmation)


async def run(command, mtu, boundaries, updates, indicate, drop_confirmation, malformed_confirmation, descriptor_mode=False, type_page_mode=False, transaction_mode=False):
    process = await asyncio.create_subprocess_exec(
        *command, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE
    )
    bearer = PipeBearer(process)
    receiver = asyncio.create_task(bearer.receive())
    scenario_task = asyncio.create_task(scenario(
        bearer, mtu, boundaries, updates, indicate, drop_confirmation, malformed_confirmation, descriptor_mode, type_page_mode, transaction_mode
    ))
    try:
        async with asyncio.timeout(30):
            done, _ = await asyncio.wait(
                [receiver, scenario_task], return_when=asyncio.FIRST_COMPLETED
            )
            if receiver in done:
                await receiver
            await scenario_task
            receiver.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await receiver
            process.stdin.close()
            assert await process.wait() == 0
        print(json.dumps({"result": "PASS", "bumble": importlib.metadata.version("bumble"),
                          "exchanges": bearer.exchanges, "mtu": mtu,
                          "updates_received": bearer.updates_received,
                          "confirmations_dropped": bearer.confirmations_dropped,
                          "confirmations_corrupted": bearer.confirmations_corrupted,
                          "boundaries": boundaries, "updates": updates, "radio": False,
                          "descriptors": descriptor_mode, "synthetic_security": descriptor_mode,
                          "writable_description": descriptor_mode,
                          "type_page_pairs": 16 if type_page_mode else 0,
                          "multi_attribute_transactions": 3 if transaction_mode else 0}), flush=True)
    finally:
        for task in (scenario_task, receiver):
            task.cancel()
        await asyncio.gather(scenario_task, receiver, return_exceptions=True)
        if process.returncode is None:
            process.kill()
            await process.wait()


if __name__ == "__main__":
    if not __debug__:
        raise RuntimeError("Run this test without Python -O: assertions are required")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mtu", type=int, default=247, choices=range(23, 518),
                        metavar="23..517")
    parser.add_argument("--descriptors", action="store_true")
    parser.add_argument("--type-pages", action="store_true")
    parser.add_argument("--transactions", action="store_true")
    parser.add_argument("--boundaries", action="store_true")
    parser.add_argument("--updates", action="store_true")
    parser.add_argument("--indications", action="store_true")
    parser.add_argument("--drop-confirmation", action="store_true")
    parser.add_argument("--malformed-confirmation", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command:
        parser.error("a Toit VM command and ATT fixture are required")
    if args.drop_confirmation and not args.indications:
        parser.error("--drop-confirmation requires --indications")
    if args.malformed_confirmation and (not args.indications or args.drop_confirmation):
        parser.error("--malformed-confirmation requires --indications and excludes --drop-confirmation")
    if args.descriptors and (args.boundaries or args.updates or args.indications):
        parser.error("--descriptors excludes other ATT scenarios")
    if args.type_pages and (args.mtu != 517 or args.descriptors or args.boundaries or
                            args.updates or args.indications):
        parser.error("--type-pages requires MTU 517 and excludes other ATT scenarios")
    if args.transactions and (args.type_pages or args.descriptors or args.boundaries or
                              args.updates or args.indications):
        parser.error("--transactions excludes other ATT scenarios")
    asyncio.run(run(args.command, args.mtu, args.boundaries, args.updates,
                    args.indications, args.drop_confirmation, args.malformed_confirmation,
                    args.descriptors, args.type_pages, args.transactions))
