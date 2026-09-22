# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Optional changed-layout radio oracle for the pinned Bumble release."""

import asyncio

from bumble import gatt, hci
from bumble.core import UUID
from bumble.device import Peer

from cccd_persistence import wait_board


class Guard:
    """Observes all updates before encryption and guards actual ATT submissions."""

    def __init__(self, client, cycle, *, withhold, changed):
        self.client = client
        self.withhold = withhold
        self.expected = {
            8: [b"\x01\x00\xff\xff"] if changed else [],
            15: [] if withhold else [bytes((cycle, i, 42)) for i in range(20)],
            18: [] if withhold else [bytes((cycle, i, 43)) for i in range(20)],
        }
        self.values = {handle: [] for handle in self.expected}
        self.confirmations = {8: 0, 18: 0}
        self.withheld = 0
        self.writes = 0
        self.cccd_attempts = 0
        self.control = False
        self.active_indication = None
        self.error = None
        self.changed = asyncio.Event()
        self.ready = asyncio.Event()
        self.original_send = client.send_gatt_pdu
        self.original_indication = client.on_att_handle_value_indication
        self.original_notification = client.on_att_handle_value_notification
        client.send_gatt_pdu = self.send
        client.on_att_handle_value_indication = self.indication
        client.on_att_handle_value_notification = self.notification

    def fail(self, reason):
        self.error = self.error or reason
        self.ready.set()
        self.changed.set()

    def record(self, handle, value, *, indication):
        expected_indication = handle in (8, 18)
        if handle not in self.expected or indication != expected_indication:
            self.fail("Unexpected update handle or kind, including reused decoy")
            return
        if handle != 8 and not self.control:
            self.fail("Application update before control/Service Changed confirmation")
        values = self.values[handle]
        if len(values) >= len(self.expected[handle]):
            self.fail("Unexpected or duplicate update")
        else:
            values.append(bytes(value))
            if values[-1] != self.expected[handle][len(values) - 1]:
                self.fail("Corrupt or out-of-order update")
        if handle == 8:
            self.changed.set()
        if all(len(self.values[h]) == len(v) for h, v in self.expected.items()):
            self.ready.set()

    def notification(self, pdu):
        self.record(pdu.attribute_handle, pdu.attribute_value, indication=False)
        self.original_notification(pdu)

    def indication(self, pdu):
        self.record(pdu.attribute_handle, pdu.attribute_value, indication=True)
        self.active_indication = pdu.attribute_handle
        try:
            # Bumble dispatches and confirms synchronously. send() intercepts
            # only the selected Service Changed confirmation, not application ones.
            self.original_indication(pdu)
        finally:
            self.active_indication = None

    def send(self, pdu):
        pdu = bytes(pdu)
        if pdu == b"\x1e":
            handle = self.active_indication
            if handle not in self.confirmations:
                self.fail("Unassociated indication confirmation")
                raise RuntimeError(self.error)
            if handle == 8 and self.withhold:
                self.withheld += 1
                return
            self.confirmations[handle] += 1
        elif pdu and pdu[0] in (0x12, 0x52, 0x16, 0x18):
            handle = int.from_bytes(pdu[1:3], "little") if len(pdu) >= 3 else 0
            if handle in (9, 13, 16, 19):
                self.cccd_attempts += 1
            expected = b"\x12\x15\x00" + bytes((0 if self.withhold else 1,))
            if pdu != expected or self.writes:
                self.fail("Only one control write is permitted; CCCD rewrites are forbidden")
                raise RuntimeError(self.error)
            self.writes += 1
            self.control = True
        return self.original_send(pdu)

    def check_error(self):
        if self.error:
            raise RuntimeError(self.error)

    def verify(self):
        self.check_error()
        changed = len(self.expected[8])
        if (self.values != self.expected or self.writes != 1 or self.cccd_attempts or
                self.withheld != (changed if self.withhold else 0) or
                self.confirmations != {8: 0 if self.withhold else changed,
                                       18: 0 if self.withhold else 20}):
            raise RuntimeError("Migration update/confirmation/write counts do not match")


async def run_central(args, device, keystore, numeric, emit):
    stage = args.cccd_migration
    withhold = stage == "migrate"
    identity = hci.Address(args.peer_address, hci.Address.PUBLIC_DEVICE_ADDRESS)
    emit(event="ready", role="central", phase="resume", migration=stage)
    results = []
    for cycle in range(1 if withhold else 2):
        await wait_board(args, numeric.offset, f"CCCD_MIGRATE READY stage={stage} cycle={cycle}")
        connection = await device.connect(identity, own_address_type=hci.OwnAddressType.PUBLIC,
                                          timeout=10)
        disconnected = False
        try:
            peer = Peer(connection)
            guard = Guard(peer.gatt_client, cycle, withhold=withhold, changed=cycle == 0)
            await connection.encrypt()
            if not connection.is_encrypted:
                raise RuntimeError("Migration connection not encrypted")
            saved = await keystore.get(str(identity))
            if not saved or not saved.ltk or not saved.ltk.authenticated or len(saved.ltk.value) != 16:
                raise RuntimeError("Missing retained authenticated migration bond")
            if cycle == 0:
                await asyncio.wait_for(guard.changed.wait(), 10)
            guard.check_error()
            await peer.discover_services()
            await peer.discover_characteristics()
            selected = []
            for uuid, handle in (("FFF1", 15), ("FFF2", 18), ("2A05", 8),
                                 ("FFF4", 12), ("FFF3", 21)):
                matches = peer.get_characteristics_by_uuid(UUID(uuid))
                if len(matches) != 1 or matches[0].handle != handle:
                    raise RuntimeError("Moved characteristic or stable Service Changed handle mismatch")
                selected.append(matches[0])
            for characteristic, handle, value in zip(selected[:4], (16, 19, 9, 13), (1, 2, 2, 0)):
                await characteristic.discover_descriptors()
                descriptor = characteristic.get_descriptor(gatt.GATT_CLIENT_CHARACTERISTIC_CONFIGURATION_DESCRIPTOR)
                if descriptor is None or descriptor.handle != handle:
                    raise RuntimeError("Migrated CCCD handle mismatch")
                if bytes(await descriptor.read_value()) != bytes((value, 0)):
                    raise RuntimeError("Migrated CCCD value mismatch")
            if bytes(await selected[3].read_value()) != b"\x63":
                raise RuntimeError("Reused-handle decoy value changed")
            await selected[4].write_value(bytes((0 if withhold else 1,)), with_response=True)
            await asyncio.wait_for(guard.ready.wait(), 15)
            marker = f"CCCD_MIGRATE {'BLOCKED' if withhold else 'SENT'} cycle={cycle} "
            await wait_board(args, numeric.offset, marker)
            guard.verify()
            await connection.disconnect()
            disconnected = True
            guard.verify()
            result = {"cycle": cycle, "resumed": True, "cccd_writes": guard.cccd_attempts,
                      "notifications": len(guard.values[15]), "indications": len(guard.values[18]),
                      "service_changed": len(guard.values[8]),
                      "changed_confirmed": guard.confirmations[8], "changed_withheld": guard.withheld,
                      "application_confirmations": guard.confirmations[18], "decoy_cccd": 0,
                      "stored_authenticated": True}
            results.append(result)
            emit(event="migration-cycle", **result)
        finally:
            if not disconnected:
                try:
                    await connection.disconnect()
                except Exception:
                    pass
    if len(await keystore.get_all()) != 1:
        raise RuntimeError("Migration reference bond not retained")
    return results
