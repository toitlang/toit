# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Shared independent ATT assertions for pipe and radio regression tests."""

from bumble import att
from bumble.core import UUID


async def type_pages(client):
    assert await client.request_mtu(517) == 517
    services = await client.discover_services()
    assert len(services) == 1
    characteristics = await client.discover_characteristics([], service=services[0])
    assert len(characteristics) == 2
    first, second = (characteristic.handle for characteristic in characteristics)
    # Find By Type Value uses characteristic group ends, even when the
    # requested handle range includes only the declaration itself.
    for characteristic, group_end in zip(characteristics, (second - 2, second)):
        declaration = characteristic.handle - 1
        value = (bytes([int(characteristic.properties)]) +
                 characteristic.handle.to_bytes(2, 'little') + b'\xf1\xff')
        response = await client.send_request(att.ATT_Find_By_Type_Value_Request(
            starting_handle=declaration, ending_handle=declaration,
            attribute_type=UUID(0x2803), attribute_value=value))
        assert isinstance(response, att.ATT_Find_By_Type_Value_Response)
        assert response.handles_information == [(declaration, group_end)]
        assert len(bytes(response)) == 5
    for first_size in (253, 254, 255, 512):
        for second_size in (253, 254, 255, 512):
            first_value = bytes([17]) * first_size
            second_value = bytes([34]) * second_size
            await client.write_value(first, first_value, with_response=True)
            await client.write_value(second, second_value, with_response=True)
            response = await client.send_request(att.ATT_Read_By_Type_Request(
                starting_handle=1, ending_handle=0xFFFF, attribute_type=UUID(0xFFF1)))
            assert isinstance(response, att.ATT_Read_By_Type_Response)
            expected = [(first, first_value[:253])]
            if first_size == second_size:
                expected.append((second, second_value[:253]))
            assert response.length == 255
            assert response.attributes == expected
            assert len(bytes(response)) == 2 + 255 * len(expected)
            response = await client.send_request(att.ATT_Read_By_Type_Request(
                starting_handle=first + 1, ending_handle=0xFFFF,
                attribute_type=UUID(0xFFF1)))
            assert isinstance(response, att.ATT_Read_By_Type_Response)
            assert response.attributes == [(second, second_value[:253])]
            # Truncated discovery must not alter either full stored value.
            assert await client.read_value(first) == first_value
            assert await client.read_value(second) == second_value
