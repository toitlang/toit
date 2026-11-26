// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

//! Unverified executable step of the revised bytecode format (format 2).
//! Each `op2_*` mirrors the spec function of the same name in
//! `v2/spec.rs`; the opcodes covered by `v2/exec.rs` (verified) are
//! dispatched there instead (see `Machine::step`).

use super::*;
use crate::types::Stuck::*;
use crate::v2::bytecodes::*;

type R = Result<Step, Stuck>;

/// `v2::spec::Probe`.
pub enum Probe2 {
    Cand(Value, i64, i64, i64, i64),
    Miss(i64),
}

/// The exceptions the format-2 machine raises itself. Their values are the
/// literals 2..6 (src/compiler/bytecode_format.h).
pub const LOOKUP_FAILED: usize = 0;
pub const AS_CHECK_FAILED: usize = 1;
pub const CODE_INVOCATION_FAILED: usize = 2;
pub const INVALID_PROGRAM: usize = 3;
pub const PRIMITIVE_LOOKUP_FAILED: usize = 4;

pub const KIND_METHOD: u8 = 0;
pub const KIND_FIELD_ACCESSOR: u8 = 1;
pub const KIND_LAMBDA: u8 = 2;
pub const KIND_BLOCK: u8 = 3;

impl Machine {
    /// The initial state of a format-2 process (`v2::prim::initial_state`):
    /// the main task's stack holds the task, the frame stack one frame for
    /// `__entry__main`.
    pub fn new2(loaded: loader::Loaded, args: Vec<String>) -> Machine {
        let loader::Loaded { program, mut heap, globals, names, .. } = loaded;
        assert!(program.word_bits == 32 || program.word_bits == 64);
        assert!(program.method_start.len() == program.bytecodes.len());
        assert!(program.roots.len() == 35 && program.invoke_offsets.len() == 19);
        assert!(program.builtin.len() == 23 && program.entry_points.len() == 9);
        let stack_id = heap.len();
        heap.push(ExecObj {
            class_id: program.builtin[STACK_CLASS],
            ro: false,
            body: ExecBody::Stack2(Vec::new(), Vec::new(), Vec::new(), Vec::new(), 0),
        });
        let task_class = program.builtin[TASK_CLASS] as usize;
        let field_count = ((program.class_bits[task_class] >> 5) & 0x7ff) as usize - 1;
        let null = program.roots[0];
        let mut fields = vec![null; field_count];
        fields[0] = Value::Obj(stack_id);
        fields[1] = Value::Smi(0);
        heap.push(ExecObj { class_id: task_class as u16, ro: false, body: ExecBody::Instance(fields) });
        let task = stack_id + 1;
        let mut m = Machine {
            format: 2,
            p: program,
            s: ExecState {
                heap, globals, stack: Vec::new(), try_h: 0, bci: 0, task, next_task_id: 1,
                frames: Vec::new(), tries: Vec::new(), fins: Vec::new(),
            },
            names,
            world: system::World::new(args),
            steps: 0,
            verified_steps: 0,
            trace: false,
            trace_throw: false,
            trace_bci: false,
            histogram: vec![0; 256],
            use_verified: true,
        };
        let entry = m.entry_method2(ENTRY_MAIN).expect("no entry point");
        let info = m.p.methods[entry];
        m.s.stack = vec![Value::Obj(task)];
        m.s.frames = vec![Frame { method: entry, ret: info.entry, base: 0 }];
        m.s.bci = info.entry;
        m
    }

    // -----------------------------------------------------------------------
    // Frames and the object stack. Every access stays within the top frame.

    pub fn top_frame(&self) -> Result<Frame, Stuck> {
        self.s.frames.last().copied().ok_or(BadFrame)
    }

    pub fn base2(&self) -> usize {
        self.s.frames.last().map(|f| f.base).unwrap_or(0)
    }

    /// Number of slots of the top frame (parameters, locals, expressions).
    pub fn frame_height(&self) -> usize {
        self.s.stack.len().saturating_sub(self.base2())
    }

    pub fn at2(&self, n: usize) -> Result<Value, Stuck> {
        if n < self.frame_height() {
            Ok(self.s.stack[self.s.stack.len() - 1 - n])
        } else {
            Err(StackRange)
        }
    }

    pub fn drop2(&mut self, n: usize) -> Result<(), Stuck> {
        if n > self.frame_height() { return Err(StackRange); }
        let len = self.s.stack.len();
        self.s.stack.truncate(len - n);
        Ok(())
    }

    pub fn info(&self, m: usize) -> Result<MethodInfo, Stuck> {
        self.p.methods.get(m).copied().ok_or(NotMethod)
    }

    pub fn entry_method2(&self, k: usize) -> Option<usize> {
        let d = self.p.entry_points[k] as i64;
        if 0 <= d && (d as usize) < self.p.dispatch.len() {
            let t = self.p.dispatch[d as usize];
            if t >= 0 && (t as usize) < self.p.methods.len() { return Some(t as usize); }
        }
        None
    }

    /// `ref_ok`: a block reference to a slot of a live frame.
    pub fn ref_ok(&self, f: usize, slot: usize) -> bool {
        if f >= self.s.frames.len() { return false; }
        let limit = if f + 1 < self.s.frames.len() { self.s.frames[f + 1].base } else { self.s.stack.len() };
        self.s.frames[f].base <= slot && slot < limit
    }

    fn block_ref(&self, v: Value) -> Result<(usize, usize), Stuck> {
        match v {
            Value::BlockRef(f, slot) if self.ref_ok(f, slot) => Ok((f, slot)),
            Value::BlockRef(_, _) => Err(StackRange),
            _ => Err(NotBlock),
        }
    }

    fn next2(&mut self, len: usize) -> R {
        self.s.bci += len;
        Ok(Step::Next)
    }

    /// Pushes a frame for `target`, whose arguments are the top `arity`
    /// slots, and continues at its entry.
    pub fn call2(&mut self, target: usize, ret: usize) -> R {
        let info = self.info(target)?;
        let arity = info.arity as usize;
        if arity > self.frame_height() { return Err(StackRange); }
        let base = self.s.stack.len() - arity;
        self.s.frames.push(Frame { method: target, ret, base });
        self.s.bci = info.entry;
        Ok(Step::Next)
    }

    /// The receiver check of a statically called method with a declared
    /// receiver range: `None` if it passes.
    fn receiver_fails(&self, info: &MethodInfo, receiver: Value) -> Result<bool, Stuck> {
        if info.recv_start == 0xffff { return Ok(false); }
        let cid = self.class_id_of(receiver)?;
        Ok(!(info.recv_start as i64 <= cid && cid < info.recv_end as i64))
    }

    /// INVOKE_STATIC and the calls of entry points.
    pub fn call_static2(&mut self, target: usize, len: usize) -> R {
        let info = self.info(target)?;
        let arity = info.arity as usize;
        if arity > self.frame_height() { return Err(StackRange); }
        if info.recv_start != 0xffff {
            if arity == 0 { return Err(NotObject); }
            let receiver = self.at2(arity - 1)?;
            if self.receiver_fails(&info, receiver)? {
                return self.raise(AS_CHECK_FAILED);
            }
        }
        let ret = self.s.bci + len;
        self.call2(target, ret)
    }

    /// Returns `result` from the top frame.
    pub fn return2(&mut self, result: Value) -> R {
        let f = self.top_frame()?;
        let fi = self.s.frames.len() - 1;
        if self.s.tries.last().map(|h| h.frame == fi).unwrap_or(false) { return Err(BadFrame); }
        if fi == 0 { return Ok(Step::Halt(Halt::TaskReturned)); }
        if f.base > self.s.stack.len() { return Err(StackRange); }
        self.cut_fins(fi, 0);
        self.s.stack.truncate(f.base);
        self.s.stack.push(result);
        self.s.frames.pop();
        self.s.bci = f.ret;
        // The try block returned normally: run the finally code.
        if let Some(h) = self.s.tries.last().copied() {
            if h.frame == fi - 1 {
                return self.enter_finally(h, None);
            }
        }
        Ok(Step::Next)
    }

    /// Drops the trailing finally records of frames above `g` and those
    /// of frame `g` at height `lim` or above (`v2::spec::cut_fins`).
    fn cut_fins(&mut self, g: usize, lim: usize) {
        while let Some(f) = self.s.fins.last() {
            if f.frame > g || (f.frame == g && f.height >= lim) {
                self.s.fins.pop();
            } else {
                break;
            }
        }
    }

    /// Enters the finally code of handler `h` (the last one, of the top
    /// frame) for a normal completion (`None`) or an unwinding, whose
    /// record takes the handler's place (`v2::spec::enter_finally`).
    fn enter_finally(&mut self, h: Handler, u: Option<Unwind>) -> R {
        if h.height > self.s.stack.len() || h.height < self.base2() { return Err(StackRange); }
        self.s.tries.pop();
        self.s.stack.truncate(h.height);
        let (value, token, reason) = match u {
            None => (self.null(), self.null(), Value::Smi(-1)),
            Some(u) => {
                let token = Value::Smi(self.s.fins.len() as i64);
                let (value, reason, resume) = match u {
                    Unwind::Throw(v) => (v, -2, Resume::Throw),
                    Unwind::Return(f, v) => (v, -1, Resume::Return(f)),
                    Unwind::Branch(f, bci, hb) => (self.null(), -1, Resume::Branch(f, bci, hb)),
                };
                self.s.fins.push(Fin { frame: h.frame, height: h.height, resume });
                (value, token, Value::Smi(reason))
            }
        };
        self.s.stack.push(value);
        self.s.stack.push(token);
        self.s.stack.push(reason);
        self.s.bci = h.bci;
        Ok(Step::Next)
    }

    /// Unwinds the frame stack (`v2::spec::unwind`).
    pub fn unwind2(&mut self, u: Unwind) -> R {
        loop {
            if self.s.frames.is_empty() {
                return match u {
                    Unwind::Throw(v) => Ok(Step::Halt(Halt::Uncaught(v))),
                    _ => Err(BadFrame),
                };
            }
            let fi = self.s.frames.len() - 1;
            if let Some(h) = self.s.tries.last().copied() {
                if h.frame == fi {
                    return self.enter_finally(h, Some(u));
                }
            }
            if self.s.frames[fi].base > self.s.stack.len() { return Err(StackRange); }
            match u {
                Unwind::Return(f, v) if f == fi => return self.return2(v),
                Unwind::Branch(f, bci, height) if f == fi => {
                    let base = self.s.frames[fi].base;
                    if !(base <= height && height <= self.s.stack.len()) { return Err(StackRange); }
                    self.s.stack.truncate(height);
                    self.s.bci = bci;
                    return Ok(Step::Next);
                }
                _ => {
                    let base = self.s.frames[fi].base;
                    self.cut_fins(fi, 0);
                    self.s.stack.truncate(base);
                    self.s.frames.pop();
                }
            }
        }
    }

    /// Raises one of the machine's own exceptions: an `Exception_` with the
    /// failure string as value and no trace.
    pub fn raise(&mut self, k: usize) -> R {
        let cid = self.builtin(EXCEPTION_CLASS) as usize;
        let bits = *self.p.class_bits.get(cid).ok_or(Fatal)?;
        let count = ((bits >> 5) & 0x7ff) as i64 - 1;
        if count < 2 { return Err(Fatal); }
        let null = self.null();
        let mut fields = vec![null; count as usize];
        fields[0] = self.p.literals[2 + k];
        let e = self.alloc(ExecObj { class_id: cid as u16, ro: false, body: ExecBody::Instance(fields) });
        if self.trace_throw {
            eprintln!("[spec] raise {} at\n  {}", self.describe(self.p.literals[2 + k]), self.backtrace());
        }
        self.unwind2(Unwind::Throw(e))
    }

    pub fn find_method2(&self, recv: Value, sel: i64) -> Result<Option<usize>, Stuck> {
        if sel < 0 { return Ok(None); }
        let index = self.class_id_of(recv)? + sel;
        if !(0 <= index && (index as usize) < self.p.dispatch.len()) { return Err(TableRange); }
        let entry = self.p.dispatch[index as usize] as i64;
        if entry == -1 { return Ok(None); }
        let info = self.info(entry as usize)?;
        if info.selector as i64 != sel { return Ok(None); }
        Ok(Some(entry as usize))
    }

    /// A virtual call of selector `sel` with `arity` arguments (receiver
    /// included) on the stack.
    fn invoke_virtual2(&mut self, sel: i64, arity: usize, len: usize) -> R {
        let recv = self.at2(arity - 1)?;
        match self.find_method2(recv, sel)? {
            None => self.raise(LOOKUP_FAILED),
            Some(t) => {
                if self.info(t)?.arity as usize != arity { return Err(BadArity); }
                let ret = self.s.bci + len;
                self.call2(t, ret)
            }
        }
    }

    fn operator_fallback(&mut self, op: u8) -> R {
        let arity = if op == INVOKE_AT_PUT { 3 } else { 2 };
        let sel = self.p.invoke_offsets[(op - INVOKE_EQ) as usize] as i64;
        self.invoke_virtual2(sel, arity, 1)
    }

    fn binary2(&mut self, r: Value) -> R {
        self.drop2(2)?;
        self.s.stack.push(r);
        self.next2(1)
    }

    fn checked_field(&self, inst: Value, f: usize) -> bool {
        matches!(self.fields(inst), Some(fs) if f < fs.len())
    }

    /// `v2::spec::is_task_obj`.
    fn is_task2(&self, inst: Value) -> bool {
        self.fields(inst).is_some() && self.is_class(inst, TASK_CLASS)
    }

    /// `v2::spec::field_readable`: a task's stack field is not readable.
    fn readable_field(&self, inst: Value, f: usize) -> bool {
        self.checked_field(inst, f) && !(f == 0 && self.is_task2(inst))
    }

    /// `v2::spec::field_writable`: not read-only, not a task's stack or id.
    fn writable_field(&self, inst: Value, f: usize) -> bool {
        self.checked_field(inst, f) && !self.obj(inst).unwrap().ro && !(f <= 1 && self.is_task2(inst))
    }

    fn set_field2(&mut self, inst: Value, f: usize, v: Value) {
        if let Some(ExecObj { body: ExecBody::Instance(fs), .. }) = self.obj_mut(inst) {
            fs[f] = v;
        }
    }

    /// The `this` of the top frame for LOAD_FIELD_THIS/STORE_FIELD_THIS.
    fn this2(&self, f: usize) -> Result<Value, Stuck> {
        let frame = self.top_frame()?;
        let info = self.info(frame.method)?;
        if info.recv_start == 0xffff || info.arity == 0 || frame.base >= self.s.stack.len() { return Err(NotInstance); }
        let this = self.s.stack[frame.base];
        if !self.checked_field(this, f) { return Err(NotInstance); }
        Ok(this)
    }

    fn branch_target(&self, target: i64) -> Result<usize, Stuck> {
        let info = self.info(self.top_frame()?.method)?;
        if !(info.entry as i64 <= target && target < info.end as i64) { return Err(BadBranch); }
        Ok(target as usize)
    }

    // -----------------------------------------------------------------------
    // HASH_FIND (`v2::spec::hf_find`, proposal note 19).

    fn hf_at(&mut self, a: Value, i: i64) -> Option<Value> {
        match self.fast_at(a, Value::Smi(i), false, Value::Smi(0), 8) {
            Ok(FastAt::Get(v)) => Some(v),
            _ => None,
        }
    }

    fn hf_probe(&mut self, index: Value, backing: Value, hash: i64, mask: i64, start: i64,
            mut slot: i64, mut step: i64, mut d: i64, mut fuel: i64) -> Probe2 {
        let tombstone = self.builtin(TOMBSTONE_CLASS) as usize;
        loop {
            if fuel == 0 { return Probe2::Miss(-2); }
            let hap = match self.hf_at(index, slot) { Some(Value::Smi(h)) => h, _ => return Probe2::Miss(-2) };
            if hap == 0 {
                return Probe2::Miss(if d > 0 { 2 * (d - 1) } else { 2 * slot + 1 });
            }
            let pos = hap.div_euclid(4096) - 1;
            let k = match self.hf_at(backing, pos) { Some(k) => k, None => return Probe2::Miss(-2) };
            let tomb = matches!(k, Value::Obj(id) if self.s.heap[id].class_id as usize == tombstone);
            if d == 0 && tomb { d = slot + 1; }
            if (hap & 0xfff) == (hash & 0xfff) && !tomb {
                return Probe2::Cand(k, pos, slot, step, d);
            }
            let slot2 = (slot + step) & mask;
            if slot2 == start { return Probe2::Miss(-1); }
            slot = slot2;
            step += 1;
            fuel -= 1;
        }
    }

    pub fn hf_find(&mut self, coll: Value, hashv: Value, slotv: Value, stepv: Value, dv: Value) -> Probe2 {
        let f = match self.fields(coll) { Some(f) if f.len() >= 4 => f.clone(), _ => return Probe2::Miss(-2) };
        let (hash, slot, step, d) = match (hashv, slotv, stepv, dv) {
            (Value::Smi(a), Value::Smi(b), Value::Smi(c), Value::Smi(e)) => (a, b, c, e),
            _ => return Probe2::Miss(-2),
        };
        let (index, backing) = (f[2], f[3]);
        let size = match self.fast_size(index) { Ok(Some(n)) => n, _ => return Probe2::Miss(-2) };
        if !(1 <= size && size <= 0x100_0000 && size & (size - 1) == 0
            && 0 <= slot && slot < size && 0 <= step && step <= 2 * size && 0 <= d && d <= size) {
            return Probe2::Miss(-2);
        }
        let mask = size - 1;
        let start = hash & mask;
        if step == 0 {
            self.hf_probe(index, backing, hash, mask, start, start, 1, d, 2 * size)
        } else {
            let slot2 = (slot + step) & mask;
            if slot2 == start { return Probe2::Miss(-1); }
            self.hf_probe(index, backing, hash, mask, start, slot2, step + 1, d, 2 * size)
        }
    }

    // -----------------------------------------------------------------------
    // The step.

    pub fn step2_unverified(&mut self) -> R {
        let bci = self.s.bci;
        let frame = self.top_frame()?;
        let info = self.info(frame.method)?;
        if !(info.entry <= bci && bci < info.end) { return Err(BadInstruction); }
        let raw = self.p.bytecodes[bci];
        if raw >= OPCODE_COUNT2 { return Err(BadInstruction); }
        // An unchecked twin (format note 20) runs as its base instruction,
        // with the check (where the spec is stuck, this interpreter raises).
        let op = crate::v2::bytecodes::exec_base_op(raw);
        let len = OPCODE_LENGTHS2[op as usize] as usize;
        if bci + len > info.end { return Err(BadInstruction); }
        let b1 = if len >= 2 { self.byte(bci + 1) } else { 0 };
        let w1 = if len >= 3 { self.u16_at(bci + 1) } else { 0 };
        match op {
            LOAD_LOCAL => self.op2_load_local(b1, len),
            LOAD_LOCAL_WIDE => self.op2_load_local(w1, len),
            LOAD_LOCAL_0..=LOAD_LOCAL_5 => self.op2_load_local((op - LOAD_LOCAL_0) as usize, len),
            POP_LOAD_LOCAL => {
                let v = self.at2(b1 + 1)?;
                self.at2(0)?;
                self.put(0, v);
                self.next2(2)
            }
            STORE_LOCAL => {
                self.at2(b1)?;
                let v = self.at2(0)?;
                self.put(b1, v);
                self.next2(2)
            }
            STORE_LOCAL_POP => {
                if b1 < 1 { return Err(StackRange); }
                self.at2(b1)?;
                let v = self.at2(0)?;
                self.drop2(1)?;
                self.put(b1 - 1, v);
                self.next2(2)
            }
            LOAD_OUTER => {
                let (f, slot) = self.block_ref(self.at2(0)?)?;
                if b1 > slot || slot - b1 < self.s.frames[f].base { return Err(StackRange); }
                let v = self.s.stack[slot - b1];
                self.drop2(1)?;
                self.s.stack.push(v);
                self.next2(2)
            }
            STORE_OUTER => {
                let v = self.at2(0)?;
                let (f, slot) = self.block_ref(self.at2(1)?)?;
                if b1 > slot || slot - b1 < self.s.frames[f].base { return Err(StackRange); }
                self.drop2(2)?;
                if slot - b1 >= self.s.stack.len() { return Err(StackRange); }
                self.s.stack[slot - b1] = v;
                self.s.stack.push(v);
                self.next2(2)
            }
            LOAD_FIELD => self.op2_load_field(b1, len),
            LOAD_FIELD_WIDE => self.op2_load_field(w1, len),
            LOAD_FIELD_LOCAL | POP_LOAD_FIELD_LOCAL => {
                let pop = op == POP_LOAD_FIELD_LOCAL;
                let (local, f) = (b1 % 16, b1 / 16);
                let inst = self.at2(if pop { local + 1 } else { local })?;
                if pop { self.at2(0)?; }
                if !self.readable_field(inst, f) { return self.raise(INVALID_PROGRAM); }
                let v = self.fields(inst).unwrap()[f];
                if pop { self.put(0, v) } else { self.s.stack.push(v) }
                self.next2(2)
            }
            STORE_FIELD => self.op2_store_field(b1, len, true),
            STORE_FIELD_WIDE => self.op2_store_field(w1, len, true),
            STORE_FIELD_POP => self.op2_store_field(b1, len, false),
            LOAD_LITERAL | LOAD_LITERAL_WIDE => {
                let i = if op == LOAD_LITERAL { b1 } else { w1 };
                let v = *self.p.literals.get(i).ok_or(TableRange)?;
                self.s.stack.push(v);
                self.next2(len)
            }
            LOAD_NULL => { let n = self.null(); self.s.stack.push(n); self.next2(len) }
            LOAD_SMI_0 => { self.s.stack.push(Value::Smi(0)); self.next2(len) }
            LOAD_SMIS_0 => {
                for _ in 0..b1 { self.s.stack.push(Value::Smi(0)); }
                self.next2(len)
            }
            LOAD_SMI_1 => { self.s.stack.push(Value::Smi(1)); self.next2(len) }
            LOAD_SMI_U8 => { self.s.stack.push(Value::Smi(b1 as i64)); self.next2(len) }
            LOAD_SMI_U16 => { self.s.stack.push(Value::Smi(w1 as i64)); self.next2(len) }
            LOAD_SMI_U32 => {
                let v = self.u32_at(bci + 1) as i128;
                if !self.smi_ok(v) { return Err(SmiRange); }
                self.s.stack.push(Value::Smi(v as i64));
                self.next2(len)
            }
            LOAD_METHOD => {
                let m = self.u32_at(bci + 1);
                if m >= self.p.methods.len() { return Err(NotMethod); }
                self.s.stack.push(Value::Smi(m as i64));
                self.next2(len)
            }
            LOAD_GLOBAL_VAR | LOAD_GLOBAL_VAR_WIDE => {
                let g = if op == LOAD_GLOBAL_VAR { b1 } else { w1 };
                let v = *self.s.globals.get(g).ok_or(TableRange)?;
                self.s.stack.push(v);
                self.next2(len)
            }
            LOAD_GLOBAL_VAR_LAZY | LOAD_GLOBAL_VAR_LAZY_WIDE => {
                let g = if op == LOAD_GLOBAL_VAR_LAZY { b1 } else { w1 };
                let v = *self.s.globals.get(g).ok_or(TableRange)?;
                self.s.stack.push(v);
                if self.fields(v).is_some() && self.is_class(v, LAZY_INITIALIZER_CLASS) {
                    // run_global_initializer(g, initializer).
                    self.put(0, Value::Smi(g as i64));
                    self.s.stack.push(v);
                    let t = self.entry_method2(RUN_GLOBAL_INITIALIZER).ok_or(NotMethod)?;
                    self.call_static2(t, len)
                } else {
                    self.next2(len)
                }
            }
            LOAD_GLOBAL_VAR_DYNAMIC => {
                let g = self.at2(0)?;
                match g {
                    Value::Smi(i) if 0 <= i && (i as usize) < self.s.globals.len() => {
                        let v = self.s.globals[i as usize];
                        self.put(0, v);
                        self.next2(1)
                    }
                    _ => self.raise(INVALID_PROGRAM),
                }
            }
            STORE_GLOBAL_VAR | STORE_GLOBAL_VAR_WIDE => {
                let g = if op == STORE_GLOBAL_VAR { b1 } else { w1 };
                if g >= self.s.globals.len() { return Err(TableRange); }
                let v = self.at2(0)?;
                self.s.globals[g] = v;
                self.next2(len)
            }
            STORE_GLOBAL_VAR_DYNAMIC => {
                let v = self.at2(0)?;
                let g = self.at2(1)?;
                match g {
                    Value::Smi(i) if 0 <= i && (i as usize) < self.s.globals.len() => {
                        self.drop2(2)?;
                        self.s.globals[i as usize] = v;
                        self.next2(1)
                    }
                    _ => self.raise(INVALID_PROGRAM),
                }
            }
            LOAD_BLOCK => {
                if b1 >= self.frame_height() { return Err(StackRange); }
                let slot = self.s.stack.len() - 1 - b1;
                let fi = self.s.frames.len() - 1;
                self.s.stack.push(Value::BlockRef(fi, slot));
                self.next2(2)
            }
            LOAD_OUTER_BLOCK => {
                let (f, slot) = self.block_ref(self.at2(0)?)?;
                if b1 > slot || slot - b1 < self.s.frames[f].base { return Err(StackRange); }
                self.put(0, Value::BlockRef(f, slot - b1));
                self.next2(2)
            }
            POP => { self.drop2(b1)?; self.next2(len) }
            POP_1 => { self.drop2(1)?; self.next2(len) }
            ALLOCATE | ALLOCATE_WIDE => {
                let c = if op == ALLOCATE { b1 } else { w1 };
                let bits = *self.p.class_bits.get(c).ok_or(TableRange)?;
                let words = ((bits >> 5) & 0x7ff) as i64;
                if bits & 0xf != 2 || words < 1 { return Err(NotInstantiable); }
                let null = self.null();
                let o = ExecObj { class_id: c as u16, ro: false, body: ExecBody::Instance(vec![null; (words - 1) as usize]) };
                let r = self.alloc(o);
                self.s.stack.push(r);
                self.next2(len)
            }
            IS_CLASS | IS_CLASS_WIDE | IS_INTERFACE | IS_INTERFACE_WIDE
            | AS_CLASS | AS_CLASS_WIDE | AS_INTERFACE | AS_INTERFACE_WIDE => {
                let enc = if len == 2 { b1 } else { w1 };
                let interface = matches!(op, IS_INTERFACE | IS_INTERFACE_WIDE | AS_INTERFACE | AS_INTERFACE_WIDE);
                let is_as = op >= AS_CLASS;
                let v = self.at2(0)?;
                let ok = self.typecheck2(v, enc / 2, enc % 2 == 1, interface)?;
                if is_as {
                    if ok { self.next2(len) } else { self.raise(AS_CHECK_FAILED) }
                } else {
                    let b = self.boolean(ok);
                    self.put(0, b);
                    self.next2(len)
                }
            }
            AS_LOCAL => {
                let v = self.at2(b1 / 32)?;
                if self.typecheck2(v, b1 % 32, false, false)? { self.next2(2) } else { self.raise(AS_CHECK_FAILED) }
            }
            INVOKE_STATIC => {
                let t = self.dispatch_target2(w1)?;
                self.call_static2(t, 3)
            }
            INVOKE_STATIC_TAIL => {
                let t = self.dispatch_target2(w1)?;
                self.tail_call2(t)
            }
            INVOKE_BLOCK => self.op2_invoke_block(b1),
            INVOKE_LAMBDA_TAIL => self.op2_invoke_lambda_tail(),
            INVOKE_INITIALIZER_TAIL => {
                let m = self.at2(0)?;
                let target = match m {
                    Value::Smi(m) if 0 <= m && (m as usize) < self.p.methods.len() => m as usize,
                    _ => return self.raise(INVALID_PROGRAM),
                };
                let info = self.info(target)?;
                if info.kind != KIND_METHOD || info.arity != 0 { return self.raise(INVALID_PROGRAM); }
                self.replace_frame(target, 0)
            }
            INVOKE_VIRTUAL => self.invoke_virtual2(self.u16_at(bci + 2) as i64, b1 + 1, len),
            INVOKE_VIRTUAL_WIDE => self.invoke_virtual2(self.u16_at(bci + 3) as i64, w1 + 1, len),
            INVOKE_VIRTUAL_GET => self.op2_invoke_virtual_get(w1 as i64),
            INVOKE_VIRTUAL_SET => self.op2_invoke_virtual_set(w1 as i64),
            INVOKE_EQ..=INVOKE_MOD => {
                let a0 = self.at2(1)?;
                let a1 = self.at2(0)?;
                self.op2_operator(op, a0, a1)
            }
            INVOKE_AT => {
                let a0 = self.at2(1)?;
                let a1 = self.at2(0)?;
                match self.fast_at(a0, a1, false, Value::Smi(0), 8) {
                    Ok(FastAt::Get(v)) => self.binary2(v),
                    _ => self.operator_fallback(INVOKE_AT),
                }
            }
            INVOKE_AT_PUT => {
                let v = self.at2(0)?;
                let arg = self.at2(1)?;
                let recv = self.at2(2)?;
                match self.fast_at(recv, arg, true, v, 8) {
                    Ok(FastAt::Put(r)) => {
                        self.drop2(3)?;
                        self.s.stack.push(r);
                        self.next2(1)
                    }
                    _ => self.operator_fallback(INVOKE_AT_PUT),
                }
            }
            INVOKE_SIZE => {
                let recv = self.at2(0)?;
                match self.fast_size(recv) {
                    Ok(Some(n)) => {
                        self.put(0, Value::Smi(n));
                        self.next2(3)
                    }
                    _ => self.op2_invoke_virtual_get(w1 as i64),
                }
            }
            BRANCH | BRANCH_IF_TRUE | BRANCH_IF_FALSE | BRANCH_IF_NOT_NULL => {
                if w1 == 0 { return Err(BadBranch); }
                self.op2_branch(op - BRANCH, bci as i64 + w1 as i64, len)
            }
            BRANCH_BACK | BRANCH_BACK_IF_TRUE | BRANCH_BACK_IF_FALSE | BRANCH_BACK_IF_NOT_NULL => {
                self.op2_branch(op - BRANCH_BACK, bci as i64 - w1 as i64, len)
            }
            // The short branches (format note 22): a one-byte distance.
            BRANCH_S | BRANCH_IF_TRUE_S | BRANCH_IF_FALSE_S | BRANCH_IF_NOT_NULL_S => {
                if b1 == 0 { return Err(BadBranch); }
                self.op2_branch(op - BRANCH_S, bci as i64 + b1 as i64, len)
            }
            BRANCH_BACK_S => self.op2_branch(0, bci as i64 - b1 as i64, len),
            PRIMITIVE => {
                if self.frame_height() != info.arity as usize { return Err(StackRange); }
                Ok(Step::Primitive(self.p.bytecodes[bci + 1], self.u16_at(bci + 2) as u16))
            }
            THROW => {
                let v = self.at2(0)?;
                self.unwind2(Unwind::Throw(v))
            }
            RETURN => {
                let v = self.at2(0)?;
                self.return2(v)
            }
            RETURN_NULL => {
                let n = self.null();
                self.return2(n)
            }
            NON_LOCAL_RETURN => {
                let (f, _) = self.block_ref(self.at2(0)?)?;
                let v = self.at2(1)?;
                if f + 1 >= self.s.frames.len() { return Err(BadFrame); }
                self.unwind2(Unwind::Return(f, v))
            }
            NON_LOCAL_BRANCH => {
                let (f, slot) = self.block_ref(self.at2(0)?)?;
                if f + 1 >= self.s.frames.len() { return Err(BadFrame); }
                let height = slot as i64 + 1 - b1 as i64;
                if height < self.s.frames[f].base as i64 { return Err(StackRange); }
                let target_info = self.info(self.s.frames[f].method)?;
                let target = target_info.entry + self.u32_at(bci + 2);
                if target >= target_info.end { return Err(BadBranch); }
                self.unwind2(Unwind::Branch(f, target, height as usize))
            }
            IDENTICAL => {
                let a0 = self.at2(1)?;
                let a1 = self.at2(0)?;
                let r = self.boolean(self.identical(a0, a1));
                self.binary2(r)
            }
            TRY => self.op2_try(),
            LOAD_FIELD_THIS => {
                let this = self.this2(b1)?;
                if b1 == 0 && self.is_task2(this) { return Err(NotInstance); }
                let v = self.fields(this).unwrap()[b1];
                self.s.stack.push(v);
                self.next2(2)
            }
            STORE_FIELD_THIS => {
                let v = self.at2(0)?;
                let this = self.this2(b1)?;
                if b1 <= 1 && self.is_task2(this) { return Err(NotInstance); }
                if self.obj(this).unwrap().ro { return self.raise(INVALID_PROGRAM); }
                self.set_field2(this, b1, v);
                self.next2(2)
            }
            UNWIND => {
                let token = self.at2(1)?;
                let value = self.at2(2)?;
                self.drop2(3)?;
                if token == self.null() { return self.next2(1); }
                let fi = self.s.frames.len() - 1;
                let height = self.s.stack.len();
                match token {
                    Value::Smi(k) if 0 <= k && (k as usize) < self.s.fins.len()
                        && self.s.fins[k as usize].frame == fi && self.s.fins[k as usize].height == height => {
                        let u = match self.s.fins[k as usize].resume {
                            Resume::Throw => Unwind::Throw(value),
                            Resume::Return(f) => Unwind::Return(f, value),
                            Resume::Branch(f, bci, hb) => Unwind::Branch(f, bci, hb),
                        };
                        self.s.fins.truncate(k as usize);
                        self.unwind2(u)
                    }
                    _ => Err(NotUnwind),
                }
            }
            HALT => self.op2_halt(b1),
            LOOP_REPEAT => {
                // `v2::spec::op_loop_repeat`: counter b1, block b1 + 1, limit b1 + 2.
                let n = self.byte(bci + 3);
                if n < 1 { return Err(StackRange); }
                let (vc, vb, vl) = (self.at2(n)?, self.at2(n + 1)?, self.at2(n + 2)?);
                match (vc, vl) {
                    (Value::Smi(i), Value::Smi(l)) if i < l => {
                        let target = self.branch_target(bci as i64 - w1 as i64)?;
                        self.put(n, Value::Smi(i + 1));
                        self.drop2(1)?;
                        self.s.stack.push(vb);
                        self.s.stack.push(vc);
                        self.s.bci = target;
                        Ok(Step::Next)
                    }
                    _ => {
                        self.drop2(1)?;
                        self.next2(len)
                    }
                }
            }
            HASH_FIND => {
                // `v2::spec::op_hash_find`: state b1, b1 + 1, b1 + 2; hash m, collection m + 2.
                let n = self.byte(bci + 3);
                let m = self.byte(bci + 4);
                let (vs, vt, vd) = (self.at2(n)?, self.at2(n + 1)?, self.at2(n + 2)?);
                let (vh, vc) = (self.at2(m)?, self.at2(m + 2)?);
                match self.hf_find(vc, vh, vs, vt, vd) {
                    Probe2::Cand(k, pos, slot, step, d) => {
                        self.put(n, Value::Smi(slot));
                        self.put(n + 1, Value::Smi(step));
                        self.put(n + 2, Value::Smi(d));
                        self.s.stack.push(k);
                        self.s.stack.push(Value::Smi(pos));
                        self.next2(len)
                    }
                    Probe2::Miss(code) => {
                        let target = self.branch_target(bci as i64 + w1 as i64)?;
                        self.s.stack.push(Value::Smi(code));
                        self.s.bci = target;
                        Ok(Step::Next)
                    }
                }
            }
            LOOP_ARRAY => {
                // `v2::spec::op_loop_array`: counter b1, block b1 + 1, end
                // b1 + 2, array b1 + 3.
                let n = self.byte(bci + 3);
                if n < 1 { return Err(StackRange); }
                let (vc, vb, ve, va) = (self.at2(n)?, self.at2(n + 1)?, self.at2(n + 2)?, self.at2(n + 3)?);
                let element = match (vc, ve, va) {
                    (Value::Smi(i), Value::Smi(e), Value::Obj(id)) if 0 <= i && i < e && id < self.s.heap.len() => {
                        match &self.s.heap[id].body {
                            ExecBody::Array(elems) if (i as u64) < elems.len() as u64 => Some((i, elems[i as usize])),
                            _ => None,
                        }
                    }
                    _ => None,
                };
                match element {
                    Some((i, v)) => {
                        let target = self.branch_target(bci as i64 - w1 as i64)?;
                        self.put(n, Value::Smi(i + 1));
                        self.drop2(1)?;
                        self.s.stack.push(vb);
                        self.s.stack.push(v);
                        self.s.bci = target;
                        Ok(Step::Next)
                    }
                    None => {
                        self.drop2(1)?;
                        self.next2(len)
                    }
                }
            }
            _ => Err(BadInstruction),
        }
    }

    fn op2_load_local(&mut self, n: usize, len: usize) -> R {
        let v = self.at2(n)?;
        self.s.stack.push(v);
        self.next2(len)
    }

    fn op2_load_field(&mut self, f: usize, len: usize) -> R {
        let inst = self.at2(0)?;
        if !self.readable_field(inst, f) { return self.raise(INVALID_PROGRAM); }
        let v = self.fields(inst).unwrap()[f];
        self.put(0, v);
        self.next2(len)
    }

    fn op2_store_field(&mut self, f: usize, len: usize, keep: bool) -> R {
        let v = self.at2(0)?;
        let inst = self.at2(1)?;
        if !self.writable_field(inst, f) { return self.raise(INVALID_PROGRAM); }
        self.drop2(2)?;
        self.set_field2(inst, f, v);
        if keep { self.s.stack.push(v); }
        self.next2(len)
    }

    fn typecheck2(&self, v: Value, index: usize, nullable: bool, interface: bool) -> Result<bool, Stuck> {
        if nullable && v == self.null() { return Ok(true); }
        if interface {
            let sel = *self.p.interface_check_offsets.get(index).ok_or(TableRange)? as i64;
            Ok(self.find_method2(v, sel)?.is_some())
        } else {
            let cid = self.class_id_of(v)?;
            if 2 * index + 1 >= self.p.class_check_ids.len() { return Err(TableRange); }
            Ok(self.p.class_check_ids[2 * index] as i64 <= cid && cid < self.p.class_check_ids[2 * index + 1] as i64)
        }
    }

    fn dispatch_target2(&self, d: usize) -> Result<usize, Stuck> {
        match self.p.dispatch.get(d) {
            Some(&t) if t >= 0 && (t as usize) < self.p.methods.len() => Ok(t as usize),
            _ => Err(NotMethod),
        }
    }

    /// Replaces the top frame's method by `target`, keeping its return
    /// address; the top `nargs` slots become the new frame's parameters.
    fn replace_frame(&mut self, target: usize, nargs: usize) -> R {
        let fi = self.s.frames.len() - 1;
        if self.s.tries.last().map(|h| h.frame == fi).unwrap_or(false) { return Err(BadFrame); }
        if nargs > self.frame_height() { return Err(StackRange); }
        let info = self.info(target)?;
        let len = self.s.stack.len();
        let base = self.s.frames[fi].base;
        let args: Vec<Value> = self.s.stack[len - nargs..].to_vec();
        self.cut_fins(fi, 0);
        self.s.stack.truncate(base);
        self.s.stack.extend(args);
        self.s.frames[fi].method = target;
        self.s.bci = info.entry;
        Ok(Step::Next)
    }

    fn tail_call2(&mut self, target: usize) -> R {
        let info = self.info(target)?;
        let arity = info.arity as usize;
        if arity > self.frame_height() { return Err(StackRange); }
        if info.recv_start != 0xffff {
            if arity == 0 { return Err(NotObject); }
            let receiver = self.at2(arity - 1)?;
            if self.receiver_fails(&info, receiver)? { return self.raise(AS_CHECK_FAILED); }
        }
        self.replace_frame(target, arity)
    }

    /// The method of a block reference's slot, checked at run time.
    fn block_target(&self, slot: usize) -> Option<usize> {
        match self.s.stack[slot] {
            Value::Smi(m) if 0 <= m && (m as usize) < self.p.methods.len()
                && self.p.methods[m as usize].kind == KIND_BLOCK => Some(m as usize),
            _ => None,
        }
    }

    fn op2_invoke_block(&mut self, n: usize) -> R {
        if n < 1 { return Err(StackRange); }
        let (_, slot) = self.block_ref(self.at2(n - 1)?)?;
        let target = match self.block_target(slot) {
            Some(t) => t,
            None => return self.raise(INVALID_PROGRAM),
        };
        let arity = self.p.methods[target].arity as usize;
        if n < arity { return self.raise(CODE_INVOCATION_FAILED); }
        self.drop2(n - arity)?;
        let ret = self.s.bci + 2;
        self.call2(target, ret)
    }

    fn op2_invoke_lambda_tail(&mut self) -> R {
        let frame = self.top_frame()?;
        let cur = self.info(frame.method)?;
        let a = cur.arity as usize;
        if a < 1 || self.frame_height() != a { return Err(StackRange); }
        let k = a - 1;
        let recv = self.s.stack[frame.base];
        let fs = match self.fields(recv) {
            Some(fs) if fs.len() >= 2 => fs.clone(),
            _ => return self.raise(INVALID_PROGRAM),
        };
        let target = match fs[0] {
            Value::Smi(m) if 0 <= m && (m as usize) < self.p.methods.len()
                && self.p.methods[m as usize].kind == KIND_LAMBDA => m as usize,
            _ => return self.raise(INVALID_PROGRAM),
        };
        let info = self.p.methods[target];
        let c = info.aux as usize;
        // The captured values: an array of the declared count, or a single
        // non-array value if the lambda captures one (`lambda__` wraps a
        // single captured array in an array).
        let captured: Vec<Value> = match self.obj(fs[1]) {
            Some(ExecObj { body: ExecBody::Array(e), .. }) => {
                if e.len() != c { return self.raise(INVALID_PROGRAM); }
                e.clone()
            }
            _ => {
                if c != 1 { return self.raise(INVALID_PROGRAM); }
                vec![fs[1]]
            }
        };
        if (info.arity as usize) < c { return self.raise(INVALID_PROGRAM); }
        let user = info.arity as usize - c;
        if k < user { return self.raise(CODE_INVOCATION_FAILED); }
        let args: Vec<Value> = self.s.stack[frame.base + 1..frame.base + 1 + user].to_vec();
        self.s.stack.truncate(frame.base);
        self.s.stack.extend(args);
        self.s.stack.extend(captured);
        let fi = self.s.frames.len() - 1;
        self.s.frames[fi].method = target;
        self.s.bci = info.entry;
        Ok(Step::Next)
    }

    fn op2_invoke_virtual_get(&mut self, sel: i64) -> R {
        let recv = self.at2(0)?;
        match self.find_method2(recv, sel)? {
            None => self.raise(LOOKUP_FAILED),
            Some(t) => {
                let info = self.info(t)?;
                if info.arity != 1 { return Err(BadArity); }
                let f = info.aux as usize;
                if info.kind == KIND_FIELD_ACCESSOR && self.readable_field(recv, f) {
                    let v = self.fields(recv).unwrap()[f];
                    self.put(0, v);
                    self.next2(3)
                } else {
                    let ret = self.s.bci + 3;
                    self.call2(t, ret)
                }
            }
        }
    }

    fn op2_invoke_virtual_set(&mut self, sel: i64) -> R {
        let recv = self.at2(1)?;
        let v = self.at2(0)?;
        match self.find_method2(recv, sel)? {
            None => self.raise(LOOKUP_FAILED),
            Some(t) => {
                let info = self.info(t)?;
                if info.arity != 2 { return Err(BadArity); }
                let f = info.aux as usize;
                if info.kind == KIND_FIELD_ACCESSOR && self.writable_field(recv, f) {
                    self.set_field2(recv, f, v);
                    self.drop2(2)?;
                    self.s.stack.push(v);
                    self.next2(3)
                } else {
                    let ret = self.s.bci + 3;
                    self.call2(t, ret)
                }
            }
        }
    }

    fn op2_operator(&mut self, op: u8, a0: Value, a1: Value) -> R {
        if op == INVOKE_EQ {
            if a0 == a1 {
                let nan = self.double_bits(a0).map(|b| f64::from_bits(b).is_nan()).unwrap_or(false);
                return self.binary2(self.boolean(!nan));
            }
            if a0 == self.null() || a1 == self.null() { return self.binary2(self.false_v()); }
            if let (Value::Smi(x), Value::Smi(y)) = (a0, a1) { return self.binary2(self.boolean(x == y)); }
            let c = self.compare_numbers(a0, a1);
            if c != 0 { return self.binary2(self.boolean(c & 32 != 0)); }
            return self.operator_fallback(op);
        }
        if (INVOKE_LT..=INVOKE_GTE).contains(&op) {
            if let (Value::Smi(x), Value::Smi(y)) = (a0, a1) {
                let r = match op { INVOKE_LT => x < y, INVOKE_LTE => x <= y, INVOKE_GT => x > y, _ => x >= y };
                return self.binary2(self.boolean(r));
            }
            let c = self.compare_numbers(a0, a1);
            if c != 0 {
                let flag = match op { INVOKE_LT => 8, INVOKE_LTE => 16, INVOKE_GT => 128, _ => 64 };
                return self.binary2(self.boolean(c & flag != 0));
            }
            return self.operator_fallback(op);
        }
        if let (Value::Smi(x), Value::Smi(y)) = (a0, a1) {
            if let Some(r) = self.smi_arith(op, x, y) {
                return self.binary2(Value::Smi(r));
            }
        }
        if matches!(op, INVOKE_ADD | INVOKE_SUB | INVOKE_MUL) {
            if let (Some(x), Some(y)) = (self.double_bits(a0), self.double_bits(a1)) {
                let bits = super::exec::float_arith(op, x, y);
                let d = ExecObj { class_id: self.builtin(DOUBLE_CLASS), ro: false, body: ExecBody::Double(bits) };
                let r = self.alloc(d);
                return self.binary2(r);
            }
        }
        self.operator_fallback(op)
    }

    fn op2_branch(&mut self, kind: u8, target: i64, len: usize) -> R {
        let taken = if kind == 0 {
            true
        } else {
            let v = self.at2(0)?;
            self.drop2(1)?;
            match kind { 1 => self.truthy(v), 2 => !self.truthy(v), _ => v != self.null() }
        };
        if taken {
            self.s.bci = self.branch_target(target)?;
            Ok(Step::Next)
        } else {
            self.next2(len)
        }
    }

    fn op2_try(&mut self) -> R {
        if self.frame_height() == 0 { return Err(StackRange); }
        let height = self.s.stack.len();
        let fi = self.s.frames.len() - 1;
        let bci = self.s.bci;
        self.cut_fins(fi, height - 1);
        self.s.tries.push(Handler { frame: fi, height, bci: bci + 1 });
        let target = match self.block_target(height - 1) {
            Some(t) => t,
            None => return self.raise(INVALID_PROGRAM),
        };
        if self.p.methods[target].arity != 1 { return self.raise(CODE_INVOCATION_FAILED); }
        self.s.stack.push(Value::BlockRef(fi, height - 1));
        self.call2(target, bci + 1)
    }

    fn op2_halt(&mut self, code: usize) -> R {
        match code {
            0 => {
                self.s.stack.push(Value::Smi(91));
                self.s.bci += 2;
                Ok(Step::Halt(Halt::Yield))
            }
            1 => match self.at2(0)? {
                Value::Smi(v) => {
                    self.drop2(1)?;
                    self.s.bci += 2;
                    Ok(Step::Halt(Halt::Exit(v)))
                }
                _ => self.raise(INVALID_PROGRAM),
            },
            2 => {
                self.drop2(1)?;
                self.s.bci += 2;
                Ok(Step::Halt(Halt::DeepSleep))
            }
            _ => {
                self.s.bci += 2;
                Ok(Step::Halt(Halt::Reset))
            }
        }
    }
}
