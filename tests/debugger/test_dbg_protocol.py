import os

from tools.debug.dbg_protocol import parse_line, format_methods, FifoChannel

def test_parse_paused_break():
    assert parse_line("dbg:paused break 2 0") == {"kind": "paused", "mode": "break", "id": 2, "off": 0}

def test_parse_stack():
    p = parse_line("dbg:stack off=295 r0=0 r1=6")
    assert p == {"kind": "stack", "off": 295, "regs": {0: "0", 1: "6"}}

def test_parse_app_output_passthrough():
    assert parse_line("result=10") == {"kind": "app", "text": "result=10"}

def test_parse_stack_malformed_falls_through():
    # Missing off= value: must not raise, falls through to "other".
    assert parse_line("dbg:stack r0=0") == {"kind": "other", "text": "dbg:stack r0=0"}

def test_format_methods():
    block = "\n".join([
        "1 100 0",
        "2 240 2",
        "5 999 1",
        "dbg:ok methods",
    ])
    assert format_methods(block) == {1: (100, 0), 2: (240, 2), 5: (999, 1)}

def test_format_methods_ignores_blank_and_nonmatching():
    block = "\n".join([
        "",
        "7 12 3",
        "garbage line",
        "dbg:ok methods",
    ])
    assert format_methods(block) == {7: (12, 3)}

def test_fifo_channel_roundtrip(tmp_path):
    path = str(tmp_path / "cmd.fifo")
    ch = FifoChannel(path)
    try:
        ch.send("dbg:continue")
        assert next(ch.lines()) == "dbg:continue"
    finally:
        ch.close()
    assert not os.path.exists(path)
