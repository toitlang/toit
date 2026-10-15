# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Independent multi-attribute prepared-write assertions, usable on any bearer."""

from bumble import att


async def transactions(client, mtu):
    assert await client.request_mtu(mtu) == mtu
    services = await client.discover_services()
    assert len(services) == 1
    characteristics = await client.discover_characteristics([], service=services[0])
    assert len(characteristics) == 2
    first, second = (characteristic.handle for characteristic in characteristics)
    originals = (b'\x07', b'\x08')

    async def values(expected):
        for handle, value in zip((first, second), expected):
            assert await client.read_value(handle) == value

    async def prepare(handle, offset, value):
        response = await client.send_request(att.ATT_Prepare_Write_Request(
            attribute_handle=handle, value_offset=offset, part_attribute_value=value))
        assert isinstance(response, att.ATT_Prepare_Write_Response)
        assert response.attribute_handle == handle
        assert response.value_offset == offset
        assert response.part_attribute_value == value

    async def execute(flags):
        return await client.send_request(att.ATT_Execute_Write_Request(flags=flags))

    await values(originals)
    # Cancelling discards both handles, and a later empty execute cannot revive them.
    await prepare(first, 0, b'cancel-first')
    await prepare(second, 0, b'cancel-second')
    await values(originals)
    assert isinstance(await execute(0), att.ATT_Execute_Write_Response)
    await values(originals)
    assert isinstance(await execute(1), att.ATT_Execute_Write_Response)
    await values(originals)

    # A late invalid offset on the second handle rolls back the first as well.
    await prepare(first, 0, b'first')
    await prepare(second, 0, b'second')
    await prepare(second, 10, b'gap')
    response = await execute(1)
    assert isinstance(response, att.ATT_Error_Response)
    assert response.request_opcode_in_error == 0x18
    assert response.attribute_handle_in_error == second
    assert response.error_code == att.ATT_INVALID_OFFSET_ERROR
    await values(originals)
    assert isinstance(await execute(1), att.ATT_Execute_Write_Response)
    await values(originals)

    # Interleave fragments for both handles and commit on the same bearer.
    # Twenty fragments at MTU23 stay below the server's 32-fragment queue limit.
    expected = (bytes(i % 251 for i in range(180)),
                bytes((i + 37) % 251 for i in range(180)))
    width = min(mtu - 5, 64)
    for offset in range(0, 180, width):
        for handle, value in zip((first, second), expected):
            await prepare(handle, offset, value[offset:offset + width])
    await values(originals)
    assert isinstance(await execute(1), att.ATT_Execute_Write_Response)
    await values(expected)
    assert isinstance(await execute(1), att.ATT_Execute_Write_Response)
    await values(expected)
