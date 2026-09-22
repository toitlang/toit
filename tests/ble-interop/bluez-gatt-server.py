#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Independent BlueZ server for Toit MTU, long-write, and indication client fixtures.

Requires dbus-fast. BlueZ owns ATT, MTU negotiation, and prepared-write handling;
this application exposes only a bounded value through the documented GATT API.
With --indications, Confirm gates each of 100 sequential 512-byte values.
"""

import argparse
import asyncio
import importlib.util
import json
from pathlib import Path
import re
import signal

from dbus_fast import DBusError, Message, Variant
from dbus_fast.aio import MessageBus
from dbus_fast.constants import BusType, MessageType, PropertyAccess
from dbus_fast.service import ServiceInterface, dbus_property, method

ROOT = "/org/toit/ble_reference"
SERVICE_PATH = ROOT + "/service0"
VALUE_PATH = SERVICE_PATH + "/value0"
ADV_PATH = ROOT + "/advertisement"
SERVICE = "9f6c3000-8e2a-4b13-9e97-94f353eeb001"
VALUE = "9f6c3001-8e2a-4b13-9e97-94f353eeb001"
AGENT_PATH = ROOT + "/agent"


class Agent(ServiceInterface):
    def __init__(self, peer):
        super().__init__("org.bluez.Agent1")
        self.peer = peer

    @method()
    def Release(self):
        pass

    @method()
    def Cancel(self):
        emit(event="agent-cancel")

    @method()
    def RequestAuthorization(self, device: "o"):
        if device != self.peer:
            raise DBusError("org.bluez.Error.Rejected", "Unexpected peer")

    @method()
    def RequestConfirmation(self, device: "o", passkey: "u"):
        raise DBusError("org.bluez.Error.Rejected", "No numeric approval in Just Works fixture")


class ResumeObserver(Agent):
    def reject(self, method_name, device):
        emit(event="resume-agent-request", method=method_name,
             expected_peer=device == self.peer, rejected=True)
        raise DBusError("org.bluez.Error.Rejected", "Resume diagnostic never approves authorization or pairing")

    @method()
    def RequestAuthorization(self, device: "o"):
        self.reject("RequestAuthorization", device)

    @method()
    def RequestConfirmation(self, device: "o", passkey: "u"):
        self.reject("RequestConfirmation", device)

    @method()
    def AuthorizeService(self, device: "o", uuid: "s"):
        self.reject("AuthorizeService", device)

    @method()
    def RequestPasskey(self, device: "o") -> "u":
        self.reject("RequestPasskey", device)

    @method()
    def RequestPinCode(self, device: "o") -> "s":
        self.reject("RequestPinCode", device)


class NumericAgent(Agent):
    def __init__(self, peer, board_log, reject=False):
        super().__init__(peer)
        self.board_log = Path(board_log)
        self.offset = self.board_log.stat().st_size
        self.confirmed = False
        self.reject = reject
        self.rejected = False

    @method()
    async def RequestConfirmation(self, device: "o", passkey: "u"):
        if device != self.peer or self.confirmed or self.rejected:
            raise DBusError("org.bluez.Error.Rejected", "Unexpected confirmation")
        try:
            async with asyncio.timeout(10):
                while True:
                    with self.board_log.open("rb") as log:
                        log.seek(self.offset)
                        fresh = log.read(65536)
                    match = re.search(rb"CENTRAL_PAIRING NUMERIC value=(\d{1,6}) fixture-approval=true", fresh)
                    if match:
                        if int(match[1]) != passkey:
                            raise DBusError("org.bluez.Error.Rejected", "Numeric Comparison mismatch")
                        if self.reject:
                            self.rejected = True
                            emit(event="numeric-comparison", matched=True, rejected=True)
                            raise DBusError("org.bluez.Error.Rejected", "Fixture rejected matching number")
                        self.confirmed = True
                        emit(event="numeric-comparison", matched=True)
                        return
                    await asyncio.sleep(0.05)
        except TimeoutError:
            raise DBusError("org.bluez.Error.Rejected", "No fresh board comparison")


def emit(**record):
    print(json.dumps(record), flush=True)


class Service(ServiceInterface):
    def __init__(self):
        super().__init__("org.bluez.GattService1")

    @dbus_property(access=PropertyAccess.READ)
    def UUID(self) -> "s":
        return SERVICE

    @dbus_property(access=PropertyAccess.READ)
    def Primary(self) -> "b":
        return True


class Value(ServiceInterface):
    def __init__(self, peer_path, mtu, indications=False, pairing=False, numeric=False, commands=False):
        super().__init__("org.bluez.GattCharacteristic1")
        self.peer_path = peer_path
        self.expected_mtu = mtu
        self.value = b"\x07"
        self.writes = 0
        self.reads = 0
        self.final_read = False
        self.indications = indications
        self.confirmed = 0
        self.notifying = False
        self.stopped = False
        self.pending = False
        self.pairing = pairing
        self.numeric = numeric
        self.commands = commands

    @dbus_property(access=PropertyAccess.READ)
    def UUID(self) -> "s":
        return VALUE

    @dbus_property(access=PropertyAccess.READ)
    def Service(self) -> "o":
        return SERVICE_PATH

    @dbus_property(access=PropertyAccess.READ)
    def Flags(self) -> "as":
        flags = ["read", "indicate"] if self.indications else ["read", "write", "reliable-write"]
        if self.commands:
            flags = ["read", "write-without-response"]
        if self.pairing:
            flags += ["encrypt-authenticated-read" if self.numeric else "encrypt-read"]
            if not self.indications:
                flags += ["encrypt-authenticated-write" if self.numeric else "encrypt-write"]
        return flags

    @dbus_property(access=PropertyAccess.READ)
    def Value(self) -> "ay":
        return self.value

    @method()
    def StartNotify(self):
        if not self.indications or self.notifying or self.confirmed != 0 or self.reads == 0:
            raise DBusError("org.bluez.Error.NotPermitted", "Unexpected subscription")
        self.notifying = True
        asyncio.get_running_loop().call_soon(self.publish)

    def publish(self):
        if not self.notifying or self.pending or self.confirmed >= 100:
            return
        self.value = bytes((self.confirmed + i) % 251 for i in range(512))
        self.pending = True
        self.emit_properties_changed({"Value": self.value})

    @method()
    def Confirm(self):
        if not self.notifying or not self.pending:
            raise DBusError("org.bluez.Error.Failed", "Unexpected confirmation")
        self.pending = False
        self.confirmed += 1
        if self.confirmed % 20 == 0:
            emit(event="confirmed", count=self.confirmed)
        asyncio.get_running_loop().call_soon(self.publish)

    @method()
    def StopNotify(self):
        self.notifying = False
        self.stopped = True
        emit(event="stopped", confirmed=self.confirmed)

    def options(self, options):
        fields = {key: value.value for key, value in options.items()}
        if fields.get("device") != self.peer_path or fields.get("mtu") != self.expected_mtu:
            raise DBusError("org.bluez.Error.NotAuthorized", "Unexpected peer or MTU")
        return fields

    @method()
    def ReadValue(self, options: "a{sv}") -> "ay":
        fields = self.options(options)
        offset = fields.get("offset", 0)
        if self.indications:
            if offset > 1:
                raise DBusError("org.bluez.Error.InvalidOffset", "Past counter end")
            self.reads += 1
            self.final_read = self.confirmed == 100
            return bytes([self.confirmed])[offset:]
        if offset > len(self.value):
            raise DBusError("org.bluez.Error.InvalidOffset", "Past value end")
        self.reads += 1
        self.final_read = self.writes == 2 and not self.value
        emit(event="read", offset=offset, bytes=len(self.value) - offset, mtu=fields["mtu"])
        return self.value[offset:]

    @method()
    def WriteValue(self, value: "ay", options: "a{sv}"):
        fields = self.options(options)
        # BlueZ 5.87's server callback omits the client-side "type" option.
        # Preserve the check if a later implementation supplies it.
        if self.commands and (fields.get("type", "command") != "command" or fields.get("prepare-authorize", False)):
            raise DBusError("org.bluez.Error.NotPermitted", "Expected Write Command")
        if self.indications:
            raise DBusError("org.bluez.Error.NotPermitted", "Read-only indication fixture")
        expected = bytes(i % 251 for i in range(512)) if self.writes == 0 else b""
        if self.writes >= 2 or fields.get("offset", 0) != 0 or bytes(value) != expected:
            raise DBusError("org.bluez.Error.InvalidValueLength", "Unexpected fixture write")
        if fields.get("prepare-authorize", False):
            emit(event="prepare", bytes=len(value), mtu=fields["mtu"])
            return
        self.value = bytes(value)
        self.writes += 1
        emit(event="commit", sequence=self.writes, bytes=len(value), mtu=fields["mtu"],
             write_type=fields.get("type"))


class Application(ServiceInterface):
    def __init__(self, flags):
        super().__init__("org.freedesktop.DBus.ObjectManager")
        self.flags = flags

    @method()
    def GetManagedObjects(self) -> "a{oa{sa{sv}}}":
        return {
            SERVICE_PATH: {"org.bluez.GattService1": {
                "UUID": Variant("s", SERVICE), "Primary": Variant("b", True)}},
            VALUE_PATH: {"org.bluez.GattCharacteristic1": {
                "UUID": Variant("s", VALUE), "Service": Variant("o", SERVICE_PATH),
                "Flags": Variant("as", self.flags)}}
        }


class Advertisement(ServiceInterface):
    def __init__(self):
        super().__init__("org.bluez.LEAdvertisement1")

    @dbus_property(access=PropertyAccess.READ)
    def Type(self) -> "s":
        return "peripheral"

    @dbus_property(access=PropertyAccess.READ)
    def ServiceUUIDs(self) -> "as":
        return [SERVICE]

    @dbus_property(access=PropertyAccess.READ)
    def LocalName(self) -> "s":
        return "Toit reference"

    @method()
    def Release(self):
        emit(event="advertisement-released")


async def call(bus, path, interface, member, signature="", body=None, destination="org.bluez"):
    reply = await asyncio.wait_for(bus.call(Message(
        destination=destination, path=path, interface=interface, member=member,
        signature=signature, body=body or [])), timeout=10)
    if reply.message_type == MessageType.ERROR:
        raise RuntimeError(f"{member}: {reply.error_name}: {reply.body}")
    return reply.body


async def run(args):
    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    path = f"/org/bluez/{args.adapter}"
    peer_path = path + "/dev_" + args.peer_address.upper().replace(":", "_")
    value = Value(peer_path, args.mtu, args.indications, args.pairing, args.numeric, args.commands)
    disconnected = asyncio.Event()
    registered = []
    agent_registered = False
    task = asyncio.current_task()
    asyncio.get_running_loop().add_signal_handler(signal.SIGTERM, task.cancel)

    def signal_received(message):
        if (message.message_type == MessageType.SIGNAL and message.path == peer_path
                and message.interface == "org.freedesktop.DBus.Properties"
                and message.member == "PropertiesChanged"
                and message.body[0] == "org.bluez.Device1"):
            connected = message.body[1].get("Connected")
            if connected is not None and connected.value is False:
                disconnected.set()

    try:
        properties = (await call(bus, path, "org.freedesktop.DBus.Properties", "GetAll",
                                 "s", ["org.bluez.Adapter1"]))[0]
        if properties["Address"].value.lower() != args.address.lower() or not properties["Powered"].value:
            raise RuntimeError("Expected adapter unavailable or not powered")
        if args.pairing:
            objects = (await call(bus, "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects"))[0]
            existing = objects.get(peer_path, {}).get("org.bluez.Device1", {})
            if args.resume_bond:
                if not existing.get("Paired") or not existing["Paired"].value:
                    raise RuntimeError("Expected the bond retained by the prior fixture phase")
                if any(existing.get(key) and existing[key].value for key in ("Connected", "Trusted")):
                    raise RuntimeError("Existing target connection or trust")
                if args.observe_resume_agent:
                    bus.export(AGENT_PATH, ResumeObserver(peer_path))
                    await call(bus, "/org/bluez", "org.bluez.AgentManager1", "RegisterAgent", "os",
                               [AGENT_PATH, "NoInputNoOutput"])
                    agent_registered = True
                    await call(bus, "/org/bluez", "org.bluez.AgentManager1", "RequestDefaultAgent", "o", [AGENT_PATH])
                    emit(event="resume-agent-observer", rejects_all=True)
            else:
                if any(existing.get(key) and existing[key].value for key in ("Connected", "Paired", "Trusted")):
                    raise RuntimeError("Refusing existing target connection, pairing or trust")
                agent = NumericAgent(peer_path, args.board_log, args.reject_numeric) if args.numeric else Agent(peer_path)
                bus.export(AGENT_PATH, agent)
                await call(bus, "/org/bluez", "org.bluez.AgentManager1", "RegisterAgent", "os",
                           [AGENT_PATH, "DisplayYesNo" if args.numeric else "NoInputNoOutput"])
                agent_registered = True
                # Incoming pairing has no application-local Device.Pair caller.
                await call(bus, "/org/bluez", "org.bluez.AgentManager1", "RequestDefaultAgent", "o", [AGENT_PATH])
        bus.add_message_handler(signal_received)
        await call(bus, "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", "s", [
            "type='signal',sender='org.bluez',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'"
        ], destination="org.freedesktop.DBus")
        bus.export(ROOT, Application(value.Flags))
        bus.export(SERVICE_PATH, Service())
        bus.export(VALUE_PATH, value)
        bus.export(ADV_PATH, Advertisement())
        await call(bus, path, "org.bluez.GattManager1", "RegisterApplication", "oa{sv}", [ROOT, {}])
        registered.append(("org.bluez.GattManager1", "UnregisterApplication", ROOT))
        await call(bus, path, "org.bluez.LEAdvertisingManager1", "RegisterAdvertisement", "oa{sv}", [ADV_PATH, {}])
        registered.append(("org.bluez.LEAdvertisingManager1", "UnregisterAdvertisement", ADV_PATH))
        emit(event="ready", adapter=args.adapter, address=args.address, expected_mtu=args.mtu)
        await asyncio.wait_for(disconnected.wait(), timeout=90)
        if args.reject_numeric:
            if not agent.rejected or agent.confirmed or value.reads or value.writes or value.confirmed:
                raise RuntimeError("Rejected comparison did not prevent all value access")
            emit(event="passed", rejected=True, reads=0, commits=0, disconnected=True)
            return
        if args.numeric and not agent.confirmed:
            raise RuntimeError("Numeric Comparison was not verified")
        if args.indications:
            if value.confirmed != 100 or not value.stopped or not value.final_read:
                raise RuntimeError("Indication fixture incomplete")
            emit(event="passed", indications=100, confirmations=100, mtu=args.mtu,
                 stopped=True, disconnected=True)
        else:
            if value.writes != 2 or value.reads < 3 or not value.final_read:
                raise RuntimeError("Peer disconnected before completing the fixture")
            emit(event="passed", commits=value.writes, reads=value.reads, mtu=args.mtu,
                 commands=args.commands, disconnected=True)
    finally:
        errors = []
        for interface, member, object_path in reversed(registered):
            try:
                await call(bus, path, interface, member, "o", [object_path])
            except Exception as error:
                errors.append(str(error))
        if agent_registered:
            try:
                await call(bus, "/org/bluez", "org.bluez.AgentManager1", "UnregisterAgent", "o", [AGENT_PATH])
            except Exception as error:
                errors.append(str(error))
        bus.disconnect()
        if errors:
            raise RuntimeError(f"Fixture cleanup failed: {errors}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--indications", action="store_true", help="Send 100 confirmed 512-byte indications")
    parser.add_argument("--commands", action="store_true", help="Expose a command-only writable value and require Write Commands")
    parser.add_argument("--pairing", action="store_true", help="Require encrypted values; temporarily register a peer-restricted default Just Works agent")
    parser.add_argument("--numeric", action="store_true", help="Require authenticated values and compare fresh fixture numbers")
    parser.add_argument("--reject-numeric", action="store_true", help="Reject the matching number and require disconnect without value access")
    parser.add_argument("--resume-bond", action="store_true", help="Require a retained Just Works bond; do not register a pairing agent or initiate pairing")
    parser.add_argument("--observe-resume-agent", action="store_true", help="With --resume-bond, temporarily log and reject all incoming agent authorization requests")
    parser.add_argument("--board-log", help="Fresh ESP32 monitor log used for Numeric Comparison")
    parser.add_argument("--adapter", required=True)
    parser.add_argument("--address", required=True, help="Authorized controller address")
    parser.add_argument("--peer-address", required=True)
    parser.add_argument("--mtu", type=int, choices=[517], default=517,
                        help="The fixtures require a 512-byte value to fit one ATT PDU")
    args = parser.parse_args()
    if args.commands and (args.indications or args.pairing or args.numeric or args.resume_bond):
        parser.error("--commands currently requires unbonded value mode")
    if args.observe_resume_agent and not args.resume_bond:
        parser.error("--observe-resume-agent requires --resume-bond")
    if args.resume_bond:
        if args.numeric:
            parser.error("--resume-bond currently supports Just Works records only")
        args.pairing = True
    if args.reject_numeric and not args.numeric:
        parser.error("--reject-numeric requires --numeric")
    if args.numeric:
        if not args.board_log:
            parser.error("--numeric requires --board-log")
        args.pairing = True
    if (not re.fullmatch(r"hci\d+", args.adapter) or not 23 <= args.mtu <= 517
            or any(not re.fullmatch(r"(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}", address)
                   for address in (args.address, args.peer_address))):
        parser.error("Invalid adapter, address, or MTU")
    helper = Path(__file__).resolve().parent / "ble-hci-run.py"
    spec = importlib.util.spec_from_file_location("hci_runner", helper)
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    with runner.adapter_lock(f"/tmp/toit-hci-{args.address.replace(':', '').lower()}.lock"):
        asyncio.run(run(args))
