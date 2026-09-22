# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Independent controlled command bursts; readback is not an ATT command ACK."""


def payload(sequence):
    return sequence.to_bytes(4, 'little') + b'ToitHCI'


async def command_characteristic(client, service_uuid):
    services = await client.discover_services()
    service = next(service for service in services
                   if str(service.uuid).lower() == service_uuid)
    characteristics = await client.discover_characteristics([], service=service)
    value = next(value for value in characteristics
                 if str(value.uuid).lower() == '9f6c6201-8e2a-4b13-9e97-94f353eeb001')
    if value.properties & 0x0e != 0x06:
        raise RuntimeError('Expected readable command-only characteristic')
    if await client.read_value(value.handle) != b'\x07':
        raise RuntimeError('Unexpected initial value')
    return value


async def command_bursts(client):
    value = await command_characteristic(client, '9f6c6200-8e2a-4b13-9e97-94f353eeb001')
    for burst in range(64):
        for index in range(8):
            await client.write_value(value.handle, payload(burst * 8 + index), with_response=False)
        if await client.read_value(value.handle) != payload(burst * 8 + 7):
            raise RuntimeError('Command burst readback mismatch')
