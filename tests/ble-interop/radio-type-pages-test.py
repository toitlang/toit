# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Optional harness failure regression; no hardware or board files are used."""

import asyncio
import importlib.util
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "radio_type_pages", Path(__file__).with_name("radio-type-pages.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


async def check(primary, board_fails, mode):
    markers = []
    events = []

    class Connection:
        peer_address = "01:02:03:04:05:06"
        handle = 1
        EVENT_DISCONNECTION = "disconnection"

        def on(self, event, callback):
            pass

        async def disconnect(self):
            raise RuntimeError("cleanup failed")

    class Device:
        async def connect(self, *args, **kwargs):
            return Connection()

    async def exchange(client, *args):
        raise primary

    async def marker(board, text, seconds=25):
        markers.append((text, seconds))
        if board_fails and len(markers) == 2:
            raise TimeoutError("board did not finish")

    with patch.object(runner, "type_pages", exchange), \
         patch.object(runner, "transactions", exchange), \
         patch.object(runner, "command_bursts", exchange), \
         patch.object(runner, "writable_description", exchange), \
         patch.object(runner, "Peer", lambda connection: SimpleNamespace(gatt_client=None)), \
         patch.object(runner, "board_marker", marker), \
         patch.object(runner, "emit", lambda **fields: events.append(fields)):
        try:
            await runner.exercise(SimpleNamespace(peer_address="01:02:03:04:05:06", board_log=None,
                                                  transactions=mode == 'transactions',
                                                  command_bursts=mode == 'command-bursts',
                                                  writable_description=mode == 'writable-description',
                                                  connectable_updates=False,
                                                  accept_update_cancel=False, accept_update_exit=False,
                                                  mixed_connectable_updates=False, mixed_update_exit=False,
                                                  mixed_update_win=False,
                                                  mixed_update_lost=None,
                                                  command_overload=False), Device())
        except BaseException as error:
            assert error is primary
        else:
            raise AssertionError("Primary failure was swallowed")
    ready = ('WRITABLE_DESCRIPTION_APP ADVERTISING' if mode == 'writable-description' else
             'COMMAND_BURSTS_APP ADVERTISING' if mode == 'command-bursts' else 'TYPE_PAGES READY')
    assert markers == [(ready, 25),
                       ("entering deep sleep without wakeup time", 35)]
    assert any(event["event"] == "cleanup-failed" for event in events)
    assert any(event["event"] == "board-terminal-missing" for event in events) == board_fails
    assert not any(event.get("result") == "PASS" for event in events)


async def main():
    for mode in ('type-pages', 'transactions', 'command-bursts', 'writable-description'):
        for board_fails in (False, True):
            await check(ValueError("exchange failed"), board_fails, mode)
            await check(asyncio.CancelledError(), board_fails, mode)
    print("RADIO_TYPE_PAGES_HARNESS PASS cases=16")


if __name__ == "__main__":
    if not __debug__:
        raise RuntimeError("Assertions must be enabled")
    asyncio.run(main())
