from tools.debug.dbg_protocol import parse_line

def test_parse_paused_break():
    assert parse_line("dbg:paused break 2 0") == {"kind": "paused", "mode": "break", "id": 2, "off": 0}

def test_parse_stack():
    p = parse_line("dbg:stack off=295 r0=0 r1=6")
    assert p == {"kind": "stack", "off": 295, "regs": {0: "0", 1: "6"}}

def test_parse_app_output_passthrough():
    assert parse_line("result=10") == {"kind": "app", "text": "result=10"}
