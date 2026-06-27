import os, re

def parse_line(line: str) -> dict:
    s = line.rstrip("\n")
    if not s.startswith("dbg:"):
        return {"kind": "app", "text": s}
    if s == "dbg:ready":
        return {"kind": "ready"}
    m = re.match(r"dbg:paused (break|step) (-?\d+) (\d+)$", s)
    if m:
        return {"kind": "paused", "mode": m.group(1), "id": int(m.group(2)), "off": int(m.group(3))}
    if s.startswith("dbg:stack off="):
        off = int(re.search(r"off=(\d+)", s).group(1))
        regs = {int(k): v for k, v in re.findall(r"r(\d+)=(\S+)", s)}
        return {"kind": "stack", "off": off, "regs": regs}
    if s.startswith("dbg:ok "):
        return {"kind": "ok", "verb": s[len("dbg:ok "):]}
    if s.startswith("dbg:error "):
        return {"kind": "error", "msg": s[len("dbg:error "):]}
    return {"kind": "other", "text": s}


class FifoChannel:
    def __init__(self, path: str):
        os.mkfifo(path)
        # Hold a read/write fd so the reader (VM) never gets EOF between commands.
        self._fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
        self.path = path

    def send(self, cmd: str):
        os.write(self._fd, (cmd.rstrip("\n") + "\n").encode())

    def close(self):
        os.close(self._fd)
        os.unlink(self.path)
