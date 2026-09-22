# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Optional Bumble radio pairing rejection, retry refusal and recovery test.

Requires explicitly selected hardware and the pairing-retry provider/application
fixtures. Never flashes, resets or monitors a board. Start the board monitor only
after this command reports ready; the supplied board log must initially be empty.
"""
import argparse
import asyncio
import hashlib
import importlib.metadata
import json
import logging
import os
from pathlib import Path
import re
import signal
from bumble import hci
from bumble.device import Device, DeviceConfiguration, Peer
from bumble.host import Host
from bumble.pairing import PairingConfig, PairingDelegate
from bumble.transport.common import BaseSource
from radio_transport import Sink, packets

def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adapter-index', type=int, required=True)
    parser.add_argument('--adapter-address', required=True)
    parser.add_argument('--peer-address', required=True)
    parser.add_argument('--private', action='store_true',
                        help='Rotate the public-fixture IRK RPA before every connection; requires private-provider firmware')
    for name in ('vm', 'supervisor', 'policy', 'relay', 'board-log', 'output'):
        parser.add_argument(f'--{name}', type=Path, required=True)
    args = parser.parse_args()
    if not 0 <= args.adapter_index < 0xffff:
        parser.error('adapter index must be between 0 and 65534')
    for name in ('adapter_address', 'peer_address'):
        value = getattr(args, name)
        if not re.fullmatch(r'(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}', value):
            parser.error(f'invalid {name}')
        setattr(args, name, value.upper())
    for name in ('vm', 'supervisor', 'policy', 'relay', 'board_log'):
        path = getattr(args, name).resolve()
        if not path.is_file():
            parser.error(f'missing {name}: {path}')
        setattr(args, name, path)
    if args.board_log.stat().st_size:
        parser.error('board log must be empty; start monitor after ready')
    args.output = args.output.resolve()
    if args.output.exists():
        parser.error('output directory must be new')
    return args

def board_text(path):
    with path.open() as source:
        text = source.read(65537)
    if len(text) > 65536:
        raise RuntimeError('Board log exceeded bounded fixture size')
    return text

def emit(**fields):
    print(json.dumps(fields), flush=True)

async def board_marker(board, marker):
    async with asyncio.timeout(25):
        while marker not in board_text(board):
            await asyncio.sleep(0.05)

class LinuxHost(Host):
    async def reset(self, driver_factory=None):
        await super().reset(driver_factory=None)

class Numeric(PairingDelegate):
    def __init__(self, index, board):
        super().__init__(io_capability=self.IoCapability.DISPLAY_OUTPUT_AND_YES_NO_INPUT)
        self.index = index
        self.board = board
        self.confirmed = False
    async def compare_numbers(self, number, digits):
        if self.index == 1 or self.confirmed:
            raise RuntimeError('Unexpected Numeric Comparison')
        async with asyncio.timeout(10):
            while True:
                match = re.search(rf'RETRY_PROVIDER NUMERIC round={self.index} value=(\d+)', board_text(self.board))
                if match:
                    if int(match[1]) != number:
                        raise RuntimeError('Numeric Comparison mismatch')
                    self.confirmed = True
                    emit(event='numeric', round=self.index, value=number, matched=True)
                    return True
                await asyncio.sleep(0.05)

async def exercise(args, device):
    private_addresses = []
    for index in range(3):
        await board_marker(args.board_log, f'RETRY_APP READY round={index}')
        numeric = Numeric(index, args.board_log)
        device.pairing_config_factory = lambda connection: PairingConfig(sc=True, mitm=True, bonding=False, delegate=numeric)
        if args.private:
            # Public fixture IRK, converted from Toit's specification order.
            address = hci.Address.generate_private_address(bytes(range(1, 17))[::-1])
            if not address.is_resolvable or str(address) in private_addresses:
                raise RuntimeError('Private fixture address was invalid or repeated')
            # Submit exactly the address retained in the independent host state.
            await device.send_sync_command(hci.HCI_LE_Set_Random_Address_Command(random_address=address))
            device.random_address = address
            private_addresses.append(str(address))
        connection = await device.connect(hci.Address(args.peer_address, hci.Address.PUBLIC_DEVICE_ADDRESS),
                                          own_address_type=(hci.OwnAddressType.RANDOM if args.private else hci.OwnAddressType.PUBLIC),
                                          timeout=10)
        disconnected = asyncio.get_running_loop().create_future()
        reasons = []
        paired_keys = []
        connection.on(connection.EVENT_DISCONNECTION,
                      lambda reason, target=disconnected: target.set_result(reason) if not target.done() else None)
        connection.on(connection.EVENT_PAIRING_FAILURE, reasons.append)
        connection.on(connection.EVENT_PAIRING, paired_keys.append)
        failure = None
        try:
            async with asyncio.timeout(12):
                await connection.pair()
        except asyncio.CancelledError:
            # Bumble cancels its pairing future on link loss. Do not consume
            # cancellation of this test task or an unrelated canceled future.
            if asyncio.current_task().cancelling() or not disconnected.done():
                raise
            failure = 'disconnected during pairing'
        except Exception as error:
            failure = str(error)
        if index == 0:
            if failure is None or reasons != [12] or not numeric.confirmed or connection.is_encrypted:
                raise RuntimeError(f'Unexpected first rejection: {failure}, {reasons}')
        elif index == 1:
            if failure is None or numeric.confirmed or paired_keys or connection.is_encrypted:
                raise RuntimeError('Early retry was not refused')
        else:
            if failure or not numeric.confirmed or not connection.is_encrypted or len(paired_keys) != 1:
                raise RuntimeError(f'Pairing recovery failed: {failure}')
            key = paired_keys[0].ltk
            if not key or not key.authenticated or len(key.value) != 16:
                raise RuntimeError('Recovery key is not authenticated/full length')
            if bytes(await Peer(connection).read_value(12)) != b'\x2a':
                raise RuntimeError('Protected read mismatch')
            emit(event='protected-read', exact=True, authenticated=True)
            await connection.disconnect()
        async with asyncio.timeout(8):
            reason = await disconnected
        emit(event='round', round=index, failure=failure, pairing_reasons=reasons, disconnect_reason=reason)
    await board_marker(args.board_log, 'RETRY_APP COMPLETE')
    await board_marker(args.board_log, 'RETRY_PROVIDER COMPLETE confirmations=2')
    await board_marker(args.board_log, 'entering deep sleep without wakeup time')
    text = board_text(args.board_log)
    if args.private:
        mappings = re.findall(r'RETRY_PROVIDER IDENTITY round=(\d) peer=([0-9a-f]{12}) stable=([0-9a-f]{14})', text)
        expected_identity = '00' + bytes(hci.Address(args.adapter_address, hci.Address.PUBLIC_DEVICE_ADDRESS)).hex()
        if len(mappings) != 3 or len(set(private_addresses)) != 3:
            raise RuntimeError('Missing distinct private identity observations')
        for index, (observed_round, address, identity) in enumerate(mappings):
            expected_address = private_addresses[index].split('/')[0].replace(':', '').lower()
            if int(observed_round) != index or address != expected_address or identity != expected_identity:
                raise RuntimeError('Registry mapping differs from independent private address')
        emit(event='private-identities', addresses=private_addresses, stable_identity_matched=True)
    if 'RETRY_PROVIDER RESULT round=1 error=SMP_REPEATED_ATTEMPTS encrypted=false smp=0' not in text:
        raise RuntimeError('Missing provider admission verdict')
    diagnostics = re.findall(r'RETRY_PROVIDER FAILURE round=(\d) reason=(\S+) retained=true', text)
    if diagnostics != [('0', '12'), ('1', 'null'), ('2', 'null')]:
        raise RuntimeError(f'Unexpected retained SMP failure diagnostics: {diagnostics}')
    emit(event='failure_diagnostics', reasons=[12, None, None], retained=True)
    values = re.findall(r'RETRY_PROVIDER RESULT round=(\d).* awake=(\d+) finished=(\d+)', text)
    if len(values) != 3:
        raise RuntimeError('Missing timing observations')
    failed_at = int(values[0][2])
    early = (int(values[1][1]) - failed_at) / 1e6
    recovered = (int(values[2][1]) - failed_at) / 1e6
    if not 0 < early < 10 or recovered < 10:
        raise RuntimeError('Retry timing requirement not met')
    emit(event='timing', early_seconds=early, recovery_seconds=recovered)

async def main(args):
    if importlib.metadata.version('bumble') != '0.0.234':
        raise RuntimeError('Expected Bumble 0.0.234; install the optional requirements')
    logging.disable(logging.CRITICAL)
    args.output.mkdir(parents=True, exist_ok=False)
    configuration = {'adapter_index': args.adapter_index, 'adapter_address': args.adapter_address,
                     'peer_address': args.peer_address, 'private': args.private, 'bumble': '0.0.234',
                     'artifacts': {name: {'path': str(getattr(args, name)),
                         'sha256': hashlib.sha256(getattr(args, name).read_bytes()).hexdigest()}
                         for name in ('vm', 'supervisor', 'policy', 'relay')},
                     'sources': {name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
                         for name in ('radio-retry.py', 'radio_transport.py')}}
    (args.output / 'configuration.json').write_text(json.dumps(configuration, indent=2) + '\n')
    with (args.output / 'supervisor.log').open('wb') as errors:
        process = await asyncio.create_subprocess_exec(
            args.supervisor, str(args.adapter_index), args.adapter_address,
            args.vm, args.policy, '--', args.vm, args.relay, str(args.adapter_index), '180',
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=errors, start_new_session=True)
        source = BaseSource()
        sink = Sink(process.stdin)
        device = Device(config=DeviceConfiguration(name='Toit retry reference', classic_enabled=False),
                        host=LinuxHost(source, sink))
        incoming = asyncio.create_task(packets(process.stdout, source))
        try:
            async with asyncio.timeout(100):
                await device.power_on()
                if str(device.public_address).split('/')[0].upper() != args.adapter_address:
                    raise RuntimeError('Wrong adapter identity')
                emit(event='ready')
                await exercise(args, device)
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
        if process.returncode != 0 or 'restoration-verified=true' not in (args.output / 'supervisor.log').read_text():
            raise RuntimeError('Supervisor/restoration failed')
        result = {'result': 'PASS', 'supervisor_exit': process.returncode,
                  'outgoing': sink.count, 'incoming': received}
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        emit(**result)

if __name__ == '__main__':
    asyncio.run(main(parse_args()))
