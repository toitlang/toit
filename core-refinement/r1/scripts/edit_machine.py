import sys
p = sys.argv[1] + '/verified/core/src/machine.rs'
s = open(p).read()


def rep(old, new, cnt=1):
    global s
    assert s.count(old) == cnt, (old, s.count(old))
    s = s.replace(old, new)


rep("""//! is `mem[top..len]` (spec index `i` is array index `len - 1 - i`), the
//! frame records are `mem[0..ftop]`, `FRAME_WORDS` each.""",
"""//! is `mem[top..len]` (spec index `i` is array index `len - 1 - i`), the
//! frame records are `mem[0..ftop]`, `FRAME_WORDS` each, the finally records
//! `mem[ftop..rtop]`, `FIN_WORDS` each.""")
rep("""/// An unwinding in progress (`types::Unwind`). Words are object references
/// held across no GC point (see `enter_finally`).""", """/// An unwinding in progress (`types::Unwind`). Words are object references
/// held across no GC point.""")
rep("""const UNWIND_THROW: usize = 0;
const UNWIND_RETURN: usize = 1;
const UNWIND_BRANCH: usize = 2;
const TOKEN_LENGTH: usize = 5;
""", """/// The kinds of a finally record's resume word (`abs::resume_word`).
const UNWIND_THROW: usize = 0;
const UNWIND_RETURN: usize = 1;
const UNWIND_BRANCH: usize = 2;
""")
rep("""        let top = self.mem.header(STACK_TOP_WORD);
        let ftop = self.mem.header(STACK_FRAME_TOP_WORD);
        let bci = self.mem.header(STACK_BCI_WORD);
        if top > len || ftop > top || ftop % FRAME_WORDS != 0 || len >= (1 << BLOCK_SLOT_BITS) {
            return false;
        }
        self.len = len;
        self.top = top;
        self.ftop = ftop;
        self.bci = bci;""", """        let top = self.mem.header(STACK_TOP_WORD);
        let rtop = self.mem.header(STACK_RECORD_TOP_WORD);
        let word = self.mem.header(STACK_BCI_WORD);
        let bci = word & ((1 << STACK_FIN_COUNT_SHIFT) - 1);
        let fins = word >> STACK_FIN_COUNT_SHIFT;
        if top > len || rtop > top || rtop % FRAME_WORDS != 0 || len >= (1 << BLOCK_SLOT_BITS)
            || fins > rtop / FIN_WORDS {
            return false;
        }
        self.len = len;
        self.top = top;
        self.rtop = rtop;
        self.ftop = rtop - fins * FIN_WORDS;
        self.bci = bci;""")
rep("""        let needed = FRAME_WORDS + env.p.max_height + STACK_RESERVE;
        if self.top - self.ftop >= needed { return None; }
        Some(self.grow(env, needed))""", """        let needed = FRAME_WORDS + env.p.max_height + STACK_RESERVE;
        if self.top - self.rtop >= needed { return None; }
        Some(self.grow(env, needed))""")
start = s.index("    #[inline(never)]\n    fn enter_finally_cold")
end = s.index("    /// `spec::unwind`.")
s = s[:start] + '''    #[inline(never)]
    fn enter_finally_cold(&mut self, env: &Env, handler: usize, u: Option<Unwinding>) -> Ctl {
        let p = env.p;
        let height = handler & 0xffff_ffff;
        let hbci = handler >> 32;
        if !(self.base <= height && height <= self.len - self.top) {
            return Ctl::Stuck(stuck::STACK_RANGE);
        }
        self.top = self.len - height;
        let r = self.ftop - FRAME_WORDS;
        self.mem.write(r + FRAME_HANDLER, 0);
        self.bci = hbci;
        let null = p.null;
        match u {
            None => {
                if !self.push(null) || !self.push(null) || !self.push(smi(-1)) {
                    return Ctl::Stuck(stuck::LIMIT);
                }
                Ctl::Next
            }
            Some(w) => {
                // A finally record takes the handler's place (format note
                // 17); the token is its index.
                let (value, reason, resume, target) = match w {
                    Unwinding::Throw(v) => (v, -2, UNWIND_THROW, 0),
                    Unwinding::Return(f, v) => (v, -1, UNWIND_RETURN + f * 4, 0),
                    Unwinding::Branch(f, bci, h) => (null, -1, UNWIND_BRANCH + f * 4, bci | (h << 32)),
                };
                if self.top - self.rtop < FIN_WORDS + 3 { return Ctl::Stuck(stuck::LIMIT); }
                let k = (self.rtop - self.ftop) / FIN_WORDS;
                let e = self.rtop;
                self.mem.write(e + FIN_FRAME, r / FRAME_WORDS);
                self.mem.write(e + FIN_HEIGHT, height);
                self.mem.write(e + FIN_RESUME, resume);
                self.mem.write(e + FIN_TARGET, target);
                self.rtop = e + FIN_WORDS;
                self.push(value);
                self.push(smi(k as i64));
                self.push(smi(reason));
                Ctl::Next
            }
        }
    }

    /// Drops the trailing finally records of frames above `g` and those of
    /// frame `g` at height `lim` or above (`spec::cut_fins`).
    #[inline(always)]
    pub fn cut_fins(&mut self, g: usize, lim: usize) {
        while self.rtop > self.ftop {
            let e = self.rtop - FIN_WORDS;
            let frame = self.mem.read(e + FIN_FRAME);
            if frame > g || (frame == g && self.mem.read(e + FIN_HEIGHT) >= lim) {
                self.rtop = e;
            } else {
                break;
            }
        }
    }

    /// Pops the top frame's record and its finally records (`fins_popped`);
    /// the other finally records move down over the frame record.
    #[inline(always)]
    pub fn pop_frame_record(&mut self) {
        let r = self.ftop - FRAME_WORDS;
        self.cut_fins(r / FRAME_WORDS, 0);
        let (f, e) = (self.ftop, self.rtop);
        if e > f {
            self.mem.copy_within(f, r, e - f);
        }
        self.ftop = r;
        self.rtop = e - FRAME_WORDS;
    }

''' + s[end:]
rep("""            // Pop the frame.
            self.top = self.len - self.base;
            self.ftop -= FRAME_WORDS;
            if !self.refresh_frame(env.p) { return Ctl::Stuck(stuck::FATAL); }""", """            // Pop the frame.
            self.top = self.len - self.base;
            self.pop_frame_record();
            if !self.refresh_frame(env.p) { return Ctl::Stuck(stuck::FATAL); }""")
rep("""        let ret = self.mem.read(r + FRAME_RET);
        self.top = self.len - self.base;
        self.ftop = r;
        if !self.refresh_frame(env.p) { return Ctl::Stuck(stuck::FATAL); }""", """        let ret = self.mem.read(r + FRAME_RET);
        self.top = self.len - self.base;
        self.pop_frame_record();
        if !self.refresh_frame(env.p) { return Ctl::Stuck(stuck::FATAL); }""")
rep("""        if self.ftop + FRAME_WORDS > self.top { return Ctl::Stuck(stuck::LIMIT); }
        let height = self.len - self.top;
        let base = height - arity;
        let f = self.ftop;""", """        if self.rtop + FRAME_WORDS > self.top { return Ctl::Stuck(stuck::LIMIT); }
        let height = self.len - self.top;
        let base = height - arity;
        let (f, e) = (self.ftop, self.rtop);
        if e > f {
            // The finally records move up over the new frame record.
            self.mem.copy_within(f, f + FRAME_WORDS, e - f);
        }
        self.rtop = e + FRAME_WORDS;""")
rep("""        let r = self.ftop - FRAME_WORDS;
        if self.mem.read(r + FRAME_HANDLER) != 0 { return Ctl::Stuck(stuck::BAD_FRAME); }
        // New object stack: stack[0..base] + args; args end at array index
        // len - base.
        let new_top = self.lim - n - extra;
        if new_top < self.ftop { return Ctl::Stuck(stuck::LIMIT); }""", """        let r = self.ftop - FRAME_WORDS;
        if self.mem.read(r + FRAME_HANDLER) != 0 { return Ctl::Stuck(stuck::BAD_FRAME); }
        // The frame's finally records go (`fins_popped`).
        self.cut_fins(r / FRAME_WORDS, 0);
        // New object stack: stack[0..base] + args; args end at array index
        // len - base.
        let new_top = self.lim - n - extra;
        if new_top < self.rtop { return Ctl::Stuck(stuck::LIMIT); }""")
rep("""        len: 0, top: 0, ftop: 0, bci: 0, base: 0, lim: 0, method: 0,""", """        len: 0, top: 0, ftop: 0, rtop: 0, bci: 0, base: 0, lim: 0, method: 0,""")
rep("""        &mut m.len as *mut usize, &mut m.ftop as *mut usize, &mut m.base as *mut usize,""", """        &mut m.len as *mut usize, &mut m.ftop as *mut usize, &mut m.rtop as *mut usize,
        &mut m.base as *mut usize,""")
rep("""                if self.top - self.ftop < n { return Ctl::Stuck(stuck::LIMIT); }""", """                if self.top - self.rtop < n { return Ctl::Stuck(stuck::LIMIT); }""")
rep("""        self.mem.write(r + FRAME_HANDLER, height | ((self.bci + 1) << 32));
        let slot = height - 1;
        let fi = self.ftop / FRAME_WORDS - 1;""", """        let fi = self.ftop / FRAME_WORDS - 1;
        // Stale finally records of the frame (left by a `break` out of
        // finally code) go first.
        self.cut_fins(fi, height - 1);
        self.mem.write(r + FRAME_HANDLER, height | ((self.bci + 1) << 32));
        let slot = height - 1;""")
start = s.index("    #[inline(never)]\n    fn op_unwind_cold")
end = s.index("    /// Cold path: runs out of line on a copy of the machine (see `cold!`).\n    #[inline(always)]\n    fn op_halt(")
s = s[:start] + '''    #[inline(never)]
    fn op_unwind_cold(&mut self, env: &Env) -> Ctl {
        let p = env.p;
        if !self.has_slot(2) { return Ctl::Stuck(stuck::STACK_RANGE); }
        let token = self.at(1);
        let value = self.at(2);
        if token == p.null {
            self.drop(3);
            self.bci += 1;
            return Ctl::Next;
        }
        // `fin_matches`: record k of the top frame, whose token slot this is.
        if !is_smi(token) { return Ctl::Stuck(stuck::NOT_UNWIND); }
        let k = smi_value(token);
        if k < 0 || k as usize >= (self.rtop - self.ftop) / FIN_WORDS { return Ctl::Stuck(stuck::NOT_UNWIND); }
        let e = self.ftop + k as usize * FIN_WORDS;
        let height = self.len - self.top;
        if self.mem.read(e + FIN_FRAME) != self.ftop / FRAME_WORDS - 1
            || self.mem.read(e + FIN_HEIGHT) != height - 3 {
            return Ctl::Stuck(stuck::NOT_UNWIND);
        }
        let resume = self.mem.read(e + FIN_RESUME);
        let target = self.mem.read(e + FIN_TARGET);
        let f = resume >> 2;
        let u = match resume & 3 {
            UNWIND_THROW => Unwinding::Throw(value),
            UNWIND_RETURN => Unwinding::Return(f, value),
            UNWIND_BRANCH => Unwinding::Branch(f, target & 0xffff_ffff, target >> 32),
            _ => return Ctl::Stuck(stuck::FATAL),
        };
        self.drop(3);
        // Records k and above go.
        self.rtop = e;
        self.unwind(env, u)
    }

''' + s[end:]
open(p, 'w').write(s)
