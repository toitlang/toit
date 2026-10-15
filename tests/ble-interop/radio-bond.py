# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Optional Linux/Bumble radio bond test; requires explicitly selected hardware.

Run pair and resume as separate processes with an ESP32 restart between them.
The matching firmware depends on --reference-role; see README.md. Both roles
require Numeric Comparison and an isolated storage namespace. This tool never
flashes a board.
"""

import argparse
import asyncio
import json
import logging
import os
from pathlib import Path
import re
import signal
import secrets
import hashlib
import importlib.metadata

from bumble import att, gatt, hci
from bumble.device import Device, DeviceConfiguration, Peer
from bumble.host import Host
from bumble.keys import JsonKeyStore
from bumble.pairing import PairingConfig, PairingDelegate
from bumble.transport.common import BaseSource
from radio_transport import Sink, packets
import cccd_persistence
import cccd_migration

def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("pair", "resume"))
    parser.add_argument("--reference-role", choices=("central", "peripheral"), default="central",
                        help="Bumble role; Toit takes the opposite role")
    parser.add_argument("--private", action="store_true", help="Require stored IRKs and fresh RPA resumption")
    parser.add_argument("--cccd", action="store_true", help="Verify persistent CCCDs with the dedicated public-address firmware")
    parser.add_argument("--cccd-migration", choices=("migrate", "confirm"),
                        help="Verify retained Service Changed across a firmware layout update")
    parser.add_argument("--local-irk", type=Path, help="Persistent secret file for private peripheral and CCCD reference modes")
    parser.add_argument("--adapter-index", type=int, required=True)
    parser.add_argument("--adapter-address", required=True)
    parser.add_argument("--peer-address", required=True, help="Toit peer public identity")
    for name in ("vm", "supervisor", "policy", "relay", "board-log", "key-store", "output"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    args = parser.parse_args()
    if args.cccd and args.reference_role != "central":
        parser.error("--cccd requires a reference central")
    if args.cccd_migration and (args.cccd or args.private or args.reference_role != "central" or args.phase != "resume"):
        parser.error("--cccd-migration requires public central resumption without --cccd")
    if bool(args.local_irk) != (args.private and (args.reference_role == "peripheral" or args.cccd)):
        parser.error("--local-irk is required with private peripheral or CCCD reference modes")
    if not 0 <= args.adapter_index < 0xffff:
        parser.error("adapter index must be between 0 and 65534")
    for name in ("adapter_address", "peer_address"):
        address = getattr(args, name)
        if not re.fullmatch(r"(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}", address):
            parser.error(f"invalid {name}")
        setattr(args, name, address.upper())
    for name in ("vm", "supervisor", "policy", "relay", "board_log"):
        path = getattr(args, name).resolve()
        if not path.is_file():
            parser.error(f"missing {name}: {path}")
        setattr(args, name, path)
    args.key_store = args.key_store.resolve()
    if args.local_irk:
        args.local_irk = args.local_irk.resolve()
        if args.local_irk == args.key_store:
            parser.error("local IRK and key store must be separate files")
    args.output = args.output.resolve()
    if args.output.exists():
        parser.error("output directory must be new")
    return args


def emit(**fields):
    print(json.dumps(fields), flush=True)


class LinuxHost(Host):
    async def reset(self, driver_factory=None):
        await super().reset(driver_factory=None)


class Numeric(PairingDelegate):
    def __init__(self, log, phase, reference_role):
        super().__init__(io_capability=self.IoCapability.DISPLAY_OUTPUT_AND_YES_NO_INPUT)
        self.log = log
        self.offset = log.stat().st_size
        self.confirmed = False
        self.phase = phase
        self.prefix = b"VHCI_PAIRING" if reference_role == "central" else b"AUTH_PERSIST"

    async def compare_numbers(self, number, digits):
        if self.phase != "pair" or self.confirmed:
            raise RuntimeError("Unexpected pairing approval")
        async with asyncio.timeout(10):
            while True:
                with self.log.open("rb") as log:
                    log.seek(self.offset)
                    fresh = log.read(16384)
                match = re.search(self.prefix + rb" NUMERIC value=(\d{1,6}) fixture-approval=true", fresh)
                if match:
                    if int(match[1]) != number:
                        raise RuntimeError("Numeric Comparison mismatch")
                    self.confirmed = True
                    emit(event="numeric-comparison", matched=True)
                    return True
                await asyncio.sleep(0.05)


async def run_central(args, device, keystore, numeric):
    identity = hci.Address(args.peer_address, hci.Address.PUBLIC_DEVICE_ADDRESS)
    target = identity
    if args.private and args.phase == "resume":
        async with asyncio.timeout(10):
            target = await device.find_peer_by_identity_address(identity)
        if not target.is_resolvable or device.address_resolver.resolve(target) != identity:
            raise RuntimeError("Peer did not use a resolvable private address")
        fresh = args.board_log.read_bytes()[-16384:]
        match = re.search(rb"BLE_BOND_RECONNECT RPA address=([0-9a-f]{12})", fresh)
        if not match or str(target).split("/")[0].replace(":", "").lower() != match[1].decode():
            raise RuntimeError("Resolved address differs from fresh board RPA")
        emit(event="private-peer-resolved", address=str(target), identity=args.peer_address,
             board_address_matched=True)
    connection = await device.connect(target,
        own_address_type=hci.OwnAddressType.PUBLIC, timeout=10)
    peer = Peer(connection)
    if args.phase == "pair":
        await connection.pair()
        if not numeric.confirmed or not connection.authenticated:
            raise RuntimeError("Missing authenticated pairing")
    else:
        await connection.encrypt()
    if not connection.is_encrypted:
        raise RuntimeError("Link is not encrypted")
    async with asyncio.timeout(10):
        while True:
            saved = await keystore.get(str(connection.peer_address))
            if saved and saved.ltk:
                break
            await asyncio.sleep(0.05)
    if not saved.ltk.authenticated or len(saved.ltk.value) != 16:
        raise RuntimeError("Invalid authenticated stored key")
    if args.private and (not saved.irk or len(saved.irk.value) != 16):
        raise RuntimeError("Missing persisted peer IRK")
    for handle, value in ((12, b"\x2a"), (14, b"\x2b"), (12, b"\x2a")):
        if bytes(await peer.read_value(handle)) != value:
            raise RuntimeError("Protected ATT value mismatch")
        emit(event="att-verified", handle=handle)
    emit(event="encrypted", resumed=args.phase == "resume", stored_authenticated=True,
         stored_key_bytes=16, authenticated_access=True)
    await connection.disconnect()
    if args.phase == "resume":
        await keystore.delete(str(connection.peer_address))
        if await keystore.get_all():
            raise RuntimeError("Independent fixture bond not deleted")
        emit(event="bond-deleted", independent_store_empty=True)


def load_local_irk(path, phase):
    if phase == "pair":
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(secrets.token_bytes(16))
    value = path.read_bytes()
    if len(value) != 16:
        raise RuntimeError("Invalid retained local IRK")
    return value


def resolved_private_addresses(device, connection, identity):
    rpa = connection.peer_resolvable_address
    if (not rpa or not rpa.is_resolvable or not device.address_resolver or
            device.address_resolver.resolve(rpa) != identity):
        raise RuntimeError("Central RPA not independently resolved")
    if not device.random_address.is_resolvable:
        raise RuntimeError("Peripheral did not use an RPA")
    return {"central": str(rpa).split("/")[0].replace(":", "").lower(),
            "peripheral": str(device.random_address).split("/")[0].replace(":", "").lower()}


def check_private_log(fresh, addresses):
    match = re.search(rb"AUTH_PERSIST PRIVATE local=([0-9a-f]{12}) peer=([0-9a-f]{12}) resolved=true", fresh)
    if (not match or match[1].decode() != addresses["central"] or
            match[2].decode() != addresses["peripheral"]):
        raise RuntimeError("Independent private addresses differ from Toit observations")


async def run_peripheral(args, device, keystore, numeric):
    identity = hci.Address(args.peer_address, hci.Address.PUBLIC_DEVICE_ADDRESS)
    disconnected = asyncio.get_running_loop().create_future()
    counts = {"reads": 0, "connections": 0}
    private_addresses = {}

    def connected(connection):
        counts["connections"] += 1
        if connection.peer_address != identity or counts["connections"] != 1:
            if not disconnected.done():
                disconnected.set_exception(RuntimeError("Unexpected central connection"))
            return
        if args.private and args.phase == "resume":
            try:
                private_addresses.update(resolved_private_addresses(device, connection, identity))
            except RuntimeError as error:
                if not disconnected.done():
                    disconnected.set_exception(error)
                return
        connection.on(connection.EVENT_DISCONNECTION,
                      lambda reason: disconnected.set_result(reason) if not disconnected.done() else None)

    device.on(device.EVENT_CONNECTION, connected)

    async def read_value(connection):
        # Bumble's live authenticated flag alone is not a MITM oracle.
        if not connection.is_encrypted:
            raise att.ATT_Error(att.ATT_INSUFFICIENT_ENCRYPTION_ERROR)
        async with asyncio.timeout(2):
            while True:
                saved = await keystore.get(str(connection.peer_address))
                if saved and saved.ltk:
                    break
                await asyncio.sleep(0.01)
        if not saved.ltk.authenticated or len(saved.ltk.value) != 16:
            raise att.ATT_Error(att.ATT_INSUFFICIENT_AUTHENTICATION_ERROR)
        if args.phase == "pair" and not numeric.confirmed:
            raise RuntimeError("Missing matched Numeric Comparison")
        counts["reads"] += 1
        return b"\x2b"

    characteristic = gatt.Characteristic(
        "FFF1", gatt.Characteristic.Properties.READ,
        gatt.Characteristic.Permissions.READABLE |
        gatt.Characteristic.Permissions.READ_REQUIRES_ENCRYPTION |
        gatt.Characteristic.Permissions.READ_REQUIRES_AUTHENTICATION,
        value=gatt.CharacteristicValue(read=read_value))
    device.add_service(gatt.Service("FFF0", [characteristic]))
    private_resume = args.private and args.phase == "resume"
    await device.start_advertising(own_address_type=(hci.OwnAddressType.RANDOM if private_resume else hci.OwnAddressType.PUBLIC),
                                  advertising_data=b"\x02\x01\x06\x03\x03\xf0\xff")
    emit(event="ready", role="peripheral", phase=args.phase, address=args.adapter_address,
         value_handle=characteristic.handle, authentication_guard="stored-ltk")
    reason = await disconnected
    if private_resume:
        with args.board_log.open("rb") as board_log:
            board_log.seek(numeric.offset)
            fresh = board_log.read(16384)
        check_private_log(fresh, private_addresses)
        emit(event="private-addresses", **private_addresses, independently_resolved=True, board_matched=True)
    if counts != {"reads": 11, "connections": 1}:
        raise RuntimeError("Unexpected protected read or connection counts")
    saved = await keystore.get(str(identity))
    if not saved or not saved.ltk or not saved.ltk.authenticated or len(saved.ltk.value) != 16:
        raise RuntimeError("Authenticated bond not retained")
    if args.private and (not saved.irk or len(saved.irk.value) != 16):
        raise RuntimeError("Peer IRK was not persisted")
    emit(event="protected-reads", reads=11, stored_authenticated=True,
         stored_key_bytes=16, disconnect_reason=reason, bond_retained=True,
         peer_irk_retained=args.private)


async def main(args):
    if importlib.metadata.version("bumble") != "0.0.234":
        raise RuntimeError("Expected Bumble 0.0.234; install the optional requirements")
    os.umask(0o077)
    logging.disable(logging.CRITICAL)
    args.output.mkdir(parents=True, exist_ok=False)
    metadata = {"phase": args.phase, "private": args.private, "cccd": args.cccd,
                "cccd_migration": args.cccd_migration,
                "reference_role": args.reference_role,
                "local_irk_path": str(args.local_irk) if args.local_irk else None,
                "adapter_index": args.adapter_index, "adapter_address": args.adapter_address,
                "peer_address": args.peer_address, "bumble": "0.0.234",
                "artifacts": {name: {"path": str(getattr(args, name)),
                    "sha256": hashlib.sha256(getattr(args, name).read_bytes()).hexdigest()}
                    for name in ("vm", "supervisor", "policy", "relay")}}
    metadata["sources"] = {name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
                           for name in ("radio-bond.py", "radio_transport.py", "cccd_persistence.py", "cccd_migration.py")}
    (args.output / "configuration.json").write_text(json.dumps(metadata, indent=2) + "\n")
    key_file = args.key_store
    if args.phase == "pair":
        descriptor = os.open(key_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as output:
            output.write("{}\n")
    elif not key_file.exists():
        raise RuntimeError("Missing retained independent bond")
    keystore = JsonKeyStore(namespace="toit-radio", filename=str(key_file))
    if bool(await keystore.get_all()) != (args.phase == "resume"):
        raise RuntimeError("Wrong independent bond phase")
    numeric = Numeric(args.board_log, args.phase, args.reference_role)
    if args.cccd:
        numeric.prefix = b"CCCD_PERSIST"
    configuration = DeviceConfiguration(name="Toit radio reference", classic_enabled=False)
    if args.local_irk:
        configuration.irk = load_local_irk(args.local_irk, args.phase)
        configuration.le_privacy_enabled = args.phase == "resume"
        configuration.le_rpa_timeout = 0  # Restart-based privacy, not periodic rotation.
    with (args.output / "supervisor.log").open("wb") as errors:
        process = await asyncio.create_subprocess_exec(
            args.supervisor, str(args.adapter_index), args.adapter_address,
            args.vm, args.policy, "--", args.vm, args.relay, str(args.adapter_index),
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=errors, start_new_session=True)
        source = BaseSource()
        sink = Sink(process.stdin)
        host = LinuxHost(source, sink)
        device = Device(config=configuration, host=host)
        device.keystore = keystore
        def pairing_config(connection):
            if args.phase != "pair" or (args.cccd and numeric.phase != "pair"):
                raise RuntimeError("Fresh pairing forbidden during resumption")
            return PairingConfig(sc=True, mitm=True, bonding=True, delegate=numeric,
                                 identity_address_type=hci.Address.PUBLIC_DEVICE_ADDRESS)
        device.pairing_config_factory = pairing_config
        incoming = asyncio.create_task(packets(process.stdout, source))
        cccd_results = None
        try:
            async with asyncio.timeout(60):
                await device.power_on()
                if str(device.public_address).split("/")[0].upper() != args.adapter_address:
                    raise RuntimeError("Controller identity mismatch")
                if args.cccd_migration:
                    cccd_results = await cccd_migration.run_central(args, device, keystore, numeric, emit)
                elif args.cccd:
                    cccd_results = await cccd_persistence.run_central(args, device, keystore, numeric, emit)
                elif args.reference_role == "central":
                    await run_central(args, device, keystore, numeric)
                else:
                    await run_peripheral(args, device, keystore, numeric)
        finally:
            process.stdin.close()
            try:
                await asyncio.wait_for(process.wait(), 15)
            except TimeoutError:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    await asyncio.wait_for(process.wait(), 5)
                except TimeoutError:
                    os.killpg(process.pid, signal.SIGKILL)
                    await process.wait()
            received = await incoming
        if process.returncode != 0:
            raise RuntimeError(f"Supervisor exit {process.returncode}")
        if "restoration-verified=true" not in (args.output / "supervisor.log").read_text():
            raise RuntimeError("Missing supervisor restoration verdict")
        result = {"result": "PASS", "phase": args.phase, "private": args.private,
                  "reference_role": args.reference_role,
                  "bond_policy": "retained" if args.cccd or args.cccd_migration or args.reference_role == "peripheral" else "delete-on-resume",
                  "commands": sink.count, "received_packets": received,
                  "supervisor_exit": process.returncode}
        if args.cccd:
            result["cccd_cycles"] = cccd_results
        if args.cccd_migration:
            result["migration_cycles"] = cccd_results
        (args.output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        emit(**result)


if __name__ == "__main__":
    asyncio.run(main(parse_args()))
