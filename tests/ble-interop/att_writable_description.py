# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Independent writable User Description assertions for the service fixture."""

from bumble import att


async def writable_description(client):
    assert await client.request_mtu(247) == 247
    services = await client.discover_services()
    fixture = [service for service in services if service.uuid.to_bytes() == b'\xf0\xff']
    assert len(fixture) == 1
    characteristics = await client.discover_characteristics([], service=fixture[0])
    assert len(characteristics) == 1
    characteristic = characteristics[0]
    assert characteristic.uuid.to_bytes() == b'\xf1\xff'
    assert int(characteristic.properties) == 0x82
    descriptors = await client.discover_descriptors(characteristic)
    assert len(descriptors) == 3
    handles = {descriptor.type.to_bytes(): descriptor.handle for descriptor in descriptors}
    vendor, extended, description = (handles[uuid] for uuid in (b'\xf2\xff', b'\x00\x29', b'\x01\x29'))

    def error(response, handle, opcode, code):
        assert isinstance(response, att.ATT_Error_Response)
        assert response.attribute_handle_in_error == handle
        assert response.request_opcode_in_error == opcode
        assert response.error_code == code

    async def prepare(handle, offset, value):
        response = await client.send_request(att.ATT_Prepare_Write_Request(
            attribute_handle=handle, value_offset=offset, part_attribute_value=value))
        assert isinstance(response, att.ATT_Prepare_Write_Response)
        assert response.attribute_handle == handle
        assert response.value_offset == offset
        assert response.part_attribute_value == value

    async def execute():
        return await client.send_request(att.ATT_Execute_Write_Request(flags=1))

    assert await client.read_value(extended) == b'\x02\x00'
    error(await client.send_request(att.ATT_Write_Request(
        attribute_handle=extended, attribute_value=b'\x00\x00')), extended, 0x12, 3)
    error(await client.send_request(att.ATT_Prepare_Write_Request(
        attribute_handle=extended, value_offset=0, part_attribute_value=b'\x00\x00')),
        extended, 0x16, 3)
    assert await client.read_value(extended) == b'\x02\x00'
    assert await client.read_value(characteristic.handle) == b'*'
    assert await client.read_value(vendor) == b'\x07'
    assert await client.read_value(description) == b'A'

    text = b'A' * 509 + '€'.encode()
    await client.write_value(description, text, with_response=True)
    assert await client.read_value(description) == text
    for malformed in (b'\xc3', b'\xc0\xaf', b'\xed\xa0\x80', b'\xf4\x90\x80\x80'):
        error(await client.send_request(att.ATT_Write_Request(
            attribute_handle=description, attribute_value=malformed)), description, 0x12, 0x13)
        assert await client.read_value(description) == text

    await prepare(vendor, 0, b'changed')
    await prepare(description, 0, b'\xc3')
    error(await execute(), description, 0x18, 0x13)
    assert await client.read_value(vendor) == b'\x07'
    assert await client.read_value(description) == text
    # A rejected transaction must also discard its prepared fragments.
    assert isinstance(await execute(), att.ATT_Execute_Write_Response)
    assert await client.read_value(vendor) == b'\x07'
    assert await client.read_value(description) == text

    await prepare(description, 0, b'\xe2')
    await prepare(description, 1, b'\x82\xac')
    assert isinstance(await execute(), att.ATT_Execute_Write_Response)
    assert await client.read_value(description) == '€'.encode()
    await client.write_value(description, b'', with_response=True)
    assert await client.read_value(description) == b''
