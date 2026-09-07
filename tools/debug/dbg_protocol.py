import os, re, subprocess, threading, time

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


def _inner_toit_run(toit_path: str) -> str:
    """Locate the inner ``toit.run`` executable next to the ``toit`` launcher.

    ``<sdk>/bin/toit`` is the multiplexer CLI; the actual snapshot runner is
    ``<sdk>/lib/toit/bin/toit.run``. We launch the inner runner directly so the
    debugger activates in exactly one VM (the application's). Going through the
    multiplexer would activate the debugger in the *launcher* VM too, since the
    activation condition is inherited via the environment.
    """
    sdk = os.path.dirname(os.path.dirname(os.path.abspath(toit_path)))
    inner = os.path.join(sdk, "lib", "toit", "bin", "toit.run")
    if os.name == "nt":
        inner += ".exe"
    return inner


class _Reader:
    """Background thread that drains a process' stdout into a line buffer.

    Synchronization strategy: a single reader thread blocks on ``readline`` and
    appends each decoded line to a shared list under a lock, pulsing a condition
    variable. The driver thread paces commands by waiting for the buffer to go
    *quiet* (no new line for ``quiet`` seconds) after each send, which lets the
    VM settle (re-park on a breakpoint or run to completion) before the next
    command is issued. This avoids racing the controller thread with a flood of
    commands while staying robust to the interleaving of app output and ``dbg:``
    responses on the shared stdout.
    """

    def __init__(self, stream):
        self._stream = stream
        self.lines = []
        self._cond = threading.Condition()
        self.eof = False
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self):
        for raw in self._stream:
            with self._cond:
                self.lines.append(raw.rstrip("\n"))
                self._cond.notify_all()
        with self._cond:
            self.eof = True
            self._cond.notify_all()

    def wait_for(self, pred, timeout):
        """Block until ``pred(lines)`` is true or timeout/EOF; return success."""
        deadline = time.monotonic() + timeout
        with self._cond:
            while True:
                if pred(self.lines):
                    return True
                if self.eof:
                    return pred(self.lines)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return pred(self.lines)
                self._cond.wait(remaining)

    def settle(self, quiet=0.4, maxwait=5.0):
        """Wait until no new output has arrived for ``quiet`` seconds."""
        deadline = time.monotonic() + maxwait
        with self._cond:
            while time.monotonic() < deadline:
                n = len(self.lines)
                if self.eof:
                    return
                self._cond.wait(quiet)
                if len(self.lines) == n:
                    return


def build_name_map(toit: str, snap: str) -> tuple:
    """Build name↔entry_bci maps by parsing ``toit tool snapshot bytecodes``.

    Returns ``(name_to_entry, entry_to_name)`` where *entry_bci* is the
    absolute bytecode position of the first instruction of each method.

    Approach: ``toit tool snapshot bytecodes <snap>`` (no filter) emits one
    method block per method.  Each block starts with a header line:

        <dispatch_idx>: <name> <file>:<line>:<col>

    followed immediately by bytecode lines indented with spaces:

        <space>+<offset>/ <absolute_bci> [<opcode>] - …

    The first bytecode (offset 0) carries the entry bci.  Because header
    lines start with a digit while bytecode lines are indented, the two
    patterns are unambiguous.

    This is Approach 1 from the plan (CLI tooling); no snapshot-bundle
    binary parsing is needed.  The entry_bci values produced here can be
    cross-checked with the numeric method registry from ``dbg:methods`` by
    matching on entry_bci (the pinned COUNT_TO_ENTRY_BCI=285 sanity anchor
    confirms the cross-check works).
    """
    result = subprocess.run(
        [toit, "tool", "snapshot", "bytecodes", snap],
        capture_output=True, text=True, check=True)
    name_to_entry: dict = {}
    entry_to_name: dict = {}
    current_name = None
    for line in result.stdout.splitlines():
        # Method-header lines start with "<idx>: " (no leading whitespace).
        # Bytecode lines are indented, so this guard is unambiguous.
        if re.match(r'^\d+: ', line):
            # The trailing source-location token (<path>:<line>:<col>) is the
            # last whitespace-separated field.  Strip it and parse the name.
            parts = line.rsplit(None, 1)
            if len(parts) == 2 and re.match(r'.+:\d+:\d+$', parts[1]):
                m = re.match(r'^\d+: (.+)$', parts[0])
                if m:
                    current_name = m.group(1).strip()
                    continue
        # First bytecode of the current method: "  0/ <entry_bci> [...]"
        if current_name is not None:
            bm = re.match(r'^\s+0/\s*(\d+)\s+\[', line)
            if bm:
                entry_bci = int(bm.group(1))
                name_to_entry[current_name] = entry_bci
                entry_to_name[entry_bci] = current_name
                current_name = None
    return name_to_entry, entry_to_name


def run_session(toit, snap, script_after_methods, timeout=20.0,
                method_picker=lambda methods: min(methods) if methods else 1):
    """Drive a full debug session against a snapshot and return parsed lines.

    Launches ``toit.run --debug <snap>`` with stdin wired to a pipe and stdout
    captured, waits for ``dbg:ready``, sends ``dbg:methods`` and parses the
    method registry to find the target method id, then issues the scripted
    follow-up commands (pacing each so the VM settles), and finally returns the
    list of parsed VM stdout lines (via :func:`parse_line`).

    ``method_picker`` selects which method id is handed to ``script_after_methods``
    from the parsed ``{id: (entry_bci, arity)}`` registry. It defaults to the
    smallest id (a stable library method), but a test that must break inside a
    specific method passes its own picker (e.g. look the id up by entry bci).
    """
    inner = _inner_toit_run(toit)
    proc = subprocess.Popen(
        [inner, "--debug", snap],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1)
    reader = _Reader(proc.stdout)

    def send(cmd):
        # The VM may have already finished and exited (e.g. surplus `continue`
        # commands after the program ran to completion); tolerate a closed pipe.
        try:
            proc.stdin.write(cmd.rstrip("\n") + "\n")
            proc.stdin.flush()
        except (BrokenPipeError, ValueError):
            pass

    try:
        reader.wait_for(
            lambda ls: any(parse_line(l)["kind"] == "ready" for l in ls),
            timeout)

        send("dbg:methods")
        reader.wait_for(
            lambda ls: any(parse_line(l) == {"kind": "ok", "verb": "methods"} for l in ls),
            timeout)
        reader.settle()

        methods = format_methods("\n".join(reader.lines))
        mid = method_picker(methods)

        for cmd in script_after_methods(mid):
            send(cmd)
            reader.settle()

        # Give the program a chance to run to completion after the last resume.
        reader.wait_for(
            lambda ls: any(parse_line(l).get("text") == "result=10" for l in ls),
            timeout)
    finally:
        try:
            proc.stdin.close()
        except Exception:
            pass
        try:
            proc.wait(timeout=timeout)
        except Exception:
            proc.kill()

    return [parse_line(l) for l in reader.lines]

