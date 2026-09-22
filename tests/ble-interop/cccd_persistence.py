# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Optional independent CCCD radio checks, pinned to Bumble 0.0.234."""

import asyncio
import re

from bumble import gatt, hci
from bumble.core import UUID
from bumble.device import Peer


class Updates:
    def __init__(self, cycle):
        self.expected = {
            "notification": [bytes((cycle, index, 42)) for index in range(20)],
            "indication": [bytes((cycle, index, 43)) for index in range(20)],
            "changed": [b"\x01\x00\xff\xff"],
        }
        self.received = {name: [] for name in self.expected}
        self.overflow = False
        self.ready = asyncio.Event()

    def record(self, name, value):
        values = self.received[name]
        if len(values) >= len(self.expected[name]):
            self.overflow = True
        else:
            values.append(bytes(value))
        if self.overflow or all(len(self.received[key]) == len(expected)
                                for key, expected in self.expected.items()):
            self.ready.set()

    def verify(self):
        if self.overflow or self.received != self.expected:
            raise RuntimeError("CCCD notification/indication/Service Changed sequence mismatch")


def attach_local(characteristic, subscriber, *, indication):
    # subscribe() always writes the CCCD in this pinned Bumble release. Register
    # only the local dispatch callback, so reconnect cannot silently rewrite it.
    client = characteristic.client
    subscribers = client.indication_subscribers if indication else client.notification_subscribers
    subscribers.setdefault(characteristic.handle, set()).add(subscriber)


class WriteGuard:
    def __init__(self, client, handles, *, allow):
        self.original = client.write_value
        self.handles = set(handles)
        self.allow = allow
        self.count = 0

    async def write(self, attribute, value, with_response=False):
        handle = attribute if isinstance(attribute, int) else attribute.handle
        if handle in self.handles:
            if not self.allow:
                raise RuntimeError("CCCD rewrite forbidden during resumption")
            self.count += 1
        return await self.original(attribute, value, with_response)


async def wait_board(args, offset, marker):
    async with asyncio.timeout(45):
        while True:
            with args.board_log.open("rb") as log:
                log.seek(offset)
                fresh = log.read(65536)
            if b"EXCEPTION" in fresh or b"ASSERTION_FAILED" in fresh:
                raise RuntimeError("Board failed before CCCD readiness")
            if marker.encode() in fresh:
                return
            await asyncio.sleep(0.05)


def address_text(address):
    return str(address).split("/")[0].replace(":", "").lower()


def private_log(fresh, cycle, peripheral, central):
    pattern = (rb"^CCCD_PRIVATE CONNECTED cycle=" + str(cycle).encode() +
               rb" local=([0-9a-f]{12}) peer=([0-9a-f]{12}) resolved=true\r?$")
    matches = re.findall(pattern, fresh, re.M)
    expected = (peripheral.encode(), central.encode())
    if matches != [expected]:
        raise RuntimeError("Private CCCD addresses differ from the resolved board connection")


async def private_addresses(args, device, identity, cycle):
    await device.refresh_resolving_list()
    async with asyncio.timeout(10):
        target = await device.find_peer_by_identity_address(identity)
    if not target.is_resolvable or device.address_resolver.resolve(target) != identity:
        raise RuntimeError("CCCD peripheral did not resolve to its retained identity")
    own = hci.Address.generate_private_address(device.irk)
    # This pinned Bumble update_rpa sends the previous address before updating
    # its field. Set the generated address explicitly, as in the mixed-role test.
    await device.send_sync_command(hci.HCI_LE_Set_Random_Address_Command(random_address=own))
    device.random_address = own
    expected = f"CCCD_PRIVATE LOCAL cycle={cycle} address={address_text(target)}"
    if expected.encode() not in args.board_log.read_bytes():
        raise RuntimeError("CCCD scan result differs from this provider's fresh RPA")
    return target, {"peripheral": address_text(target), "central": address_text(own)}


async def run_central(args, device, keystore, numeric, emit):
    results = []
    observed_private = []
    identity = hci.Address(args.peer_address, hci.Address.PUBLIC_DEVICE_ADDRESS)
    emit(event="ready", role="central", phase=args.phase, cccd=True)
    for cycle in range(2):
        initial = args.phase == "pair" and cycle == 0
        numeric.phase = "pair" if initial else "resume"
        await wait_board(args, numeric.offset,
                         f"CCCD_PERSIST READY phase={args.phase} cycle={cycle} ")
        target = identity
        own_type = hci.OwnAddressType.PUBLIC
        addresses = None
        if args.private and not initial:
            target, addresses = await private_addresses(args, device, identity, cycle)
            if any(addresses[key] == previous[key] for previous in observed_private
                   for key in ("central", "peripheral")):
                raise RuntimeError("CCCD resumption reused a private address")
            observed_private.append(addresses)
            own_type = hci.OwnAddressType.RANDOM
        connection = await device.connect(target, own_address_type=own_type,
                                          timeout=10)
        disconnected = False
        try:
            if initial:
                await connection.pair()
                if not numeric.confirmed or not connection.authenticated:
                    raise RuntimeError("Missing matched authenticated initial pairing")
            else:
                await connection.encrypt()
            if not connection.is_encrypted:
                raise RuntimeError("CCCD link is not encrypted")
            saved = await keystore.get(str(identity))
            if not saved or not saved.ltk or not saved.ltk.authenticated or len(saved.ltk.value) != 16:
                raise RuntimeError("Missing retained authenticated reference bond")
            if args.private and (not saved.irk or len(saved.irk.value) != 16 or saved.irk.value == bytes(16)):
                raise RuntimeError("Missing retained peripheral resolving key")
            if addresses:
                await wait_board(args, numeric.offset, f"CCCD_PRIVATE CONNECTED cycle={cycle} ")
                private_log(args.board_log.read_bytes()[numeric.offset:], cycle,
                            addresses["peripheral"], addresses["central"])
            peer = Peer(connection)
            await peer.discover_services()
            await peer.discover_characteristics()
            selected = []
            for uuid in ("FFF1", "FFF2", "2A05", "FFF3"):
                matches = peer.get_characteristics_by_uuid(UUID(uuid))
                if len(matches) != 1:
                    raise RuntimeError(f"Expected one characteristic {uuid}")
                selected.append(matches[0])
            descriptors = []
            for characteristic in selected[:3]:
                await characteristic.discover_descriptors()
                descriptor = characteristic.get_descriptor(gatt.GATT_CLIENT_CHARACTERISTIC_CONFIGURATION_DESCRIPTOR)
                if descriptor is None:
                    raise RuntimeError("Missing CCCD")
                descriptors.append(descriptor)
            guard = WriteGuard(peer.gatt_client, [item.handle for item in descriptors], allow=initial)
            peer.gatt_client.write_value = guard.write
            updates = Updates(cycle)
            for index, name in enumerate(("notification", "indication", "changed")):
                attach_local(selected[index], lambda value, name=name: updates.record(name, value),
                             indication=index != 0)
                expected = b"\x01\x00" if index == 0 else b"\x02\x00"
                before = bytes(await descriptors[index].read_value())
                if before != (b"\x00\x00" if initial else expected):
                    raise RuntimeError("CCCD did not have the expected initial/restored value")
                if initial:
                    await descriptors[index].write_value(expected, with_response=True)
                if bytes(await descriptors[index].read_value()) != expected:
                    raise RuntimeError("CCCD value mismatch after configuration/restoration")
            await selected[3].write_value(b"\x01", with_response=True)
            await asyncio.wait_for(updates.ready.wait(), 15)
            updates.verify()
            await wait_board(args, numeric.offset, f"CCCD_PERSIST SENT cycle={cycle} ")
            await connection.disconnect()
            disconnected = True
            updates.verify()
            if guard.count != (3 if initial else 0):
                raise RuntimeError("Unexpected CCCD write count")
            result = {"cycle": cycle, "resumed": not initial, "cccd_writes": guard.count,
                      "notifications": 20, "indications": 20, "service_changed": 1,
                      "stored_authenticated": True}
            if addresses:
                result["private_addresses"] = addresses
            results.append(result)
            emit(event="cccd-cycle", **result)
        finally:
            if not disconnected:
                # Preserve the original failure if best-effort cleanup fails.
                try:
                    await connection.disconnect()
                except Exception:
                    pass
    if len(await keystore.get_all()) != 1:
        raise RuntimeError("Reference bond not retained")
    return results
