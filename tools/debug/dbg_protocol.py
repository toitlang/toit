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
        # Guard against a malformed stack line: fall through to "other" rather
        # than raising AttributeError on .group() of a failed search.
        off_match = re.search(r"off=(\d+)", s)
        if off_match:
            off = int(off_match.group(1))
            regs = {int(k): v for k, v in re.findall(r"r(\d+)=(\S+)", s)}
            return {"kind": "stack", "off": off, "regs": regs}
    if s.startswith("dbg:ok "):
        return {"kind": "ok", "verb": s[len("dbg:ok "):]}
    if s.startswith("dbg:error "):
        return {"kind": "error", "msg": s[len("dbg:error "):]}
    return {"kind": "other", "text": s}


def format_methods(block: str) -> dict[int, tuple[int, int]]:
    """Parse a method-registry text block into {id: (entry_bci, arity)}.

    The VM emits one ``<id> <entry_bci> <arity>`` line per method, followed by
    a ``dbg:ok methods`` terminator. Parsing is tolerant: any line that is not
    exactly three whitespace-separated integers (blank lines, the ``dbg:ok``
    terminator, etc.) is skipped.
    """
    methods: dict[int, tuple[int, int]] = {}
    for line in block.splitlines():
        m = re.match(r"^\s*(\d+)\s+(\d+)\s+(\d+)\s*$", line)
        if m:
            mid, entry_bci, arity = int(m.group(1)), int(m.group(2)), int(m.group(3))
            methods[mid] = (entry_bci, arity)
    return methods


class FifoChannel:
    """A held-open FIFO used to push commands to the VM.

    The fd is opened ``O_RDWR`` so the reader (the VM) never sees EOF between
    commands. ``O_NONBLOCK`` makes both the open and subsequent reads/writes
    non-blocking, so ``lines()`` can drain whatever is currently buffered and
    return instead of hanging when no data is available.
    """

    def __init__(self, path: str):
        os.mkfifo(path)
        # O_RDWR: hold the write end open so the VM reader never gets EOF.
        # O_NONBLOCK: non-blocking reads let lines() stop at end-of-buffer.
        self._fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
        self.path = path
        self._buf = b""

    def send(self, cmd: str):
        os.write(self._fd, (cmd.rstrip("\n") + "\n").encode())

    def lines(self):
        """Yield decoded, newline-stripped lines currently readable on the fd.

        Because the fd is O_RDWR, this is a loopback over the FIFO: it yields
        back the lines written via send(). Later tasks replace this with the
        real VM-stdout transport; the line-buffering contract stays the same.
        Reads are non-blocking, so the generator stops once the buffer is
        drained (read returns empty or would block).
        """
        while True:
            try:
                chunk = os.read(self._fd, 4096)
            except BlockingIOError:
                chunk = b""
            if not chunk:
                break
            self._buf += chunk
            while b"\n" in self._buf:
                raw, self._buf = self._buf.split(b"\n", 1)
                yield raw.decode()

    def close(self):
        os.close(self._fd)
        os.unlink(self.path)
