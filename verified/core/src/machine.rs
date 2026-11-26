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

//! The run loop of format-2 processes and the opcodes that are not (yet)
//! verified. The verified handlers live in `exec.rs` (inside `verus!`);
//! this module dispatches to them. Every opcode follows the spec function
//! of the same name in `verified/spec/src/v2/spec.rs`; every stuck state of
//! the spec is a run-time check here (the process is terminated), so the
//! core is memory safe for every program, verified or not.
//!
//! State of the running task (DESIGN.md, "Stack layout"): the object stack
//! is `mem[top..len]` (spec index `i` is array index `len - 1 - i`), the
//! frame records are `mem[0..ftop]`, `FRAME_WORDS` each, the finally records
//! `mem[ftop..rtop]`, `FIN_WORDS` each.

use crate::layout::*;
use vstd::prelude::Ghost;
use crate::ffi::Runtime;
use crate::view::*;
use crate::exec::*;

/// Opcode numbers (verified/spec/src/v2/bytecodes.rs).
pub mod op {
    pub const LOAD_LOCAL: u8 = 0;
    pub const LOAD_LOCAL_WIDE: u8 = 1;
    pub const POP_LOAD_LOCAL: u8 = 2;
    pub const STORE_LOCAL: u8 = 3;
    pub const STORE_LOCAL_POP: u8 = 4;
    pub const LOAD_OUTER: u8 = 5;
    pub const STORE_OUTER: u8 = 6;
    pub const LOAD_FIELD: u8 = 7;
    pub const LOAD_FIELD_WIDE: u8 = 8;
    pub const LOAD_FIELD_LOCAL: u8 = 9;
    pub const POP_LOAD_FIELD_LOCAL: u8 = 10;
    pub const STORE_FIELD: u8 = 11;
    pub const STORE_FIELD_WIDE: u8 = 12;
    pub const STORE_FIELD_POP: u8 = 13;
    pub const LOAD_LOCAL_0: u8 = 14;
    pub const LOAD_LOCAL_5: u8 = 19;
    pub const LOAD_LITERAL: u8 = 20;
    pub const LOAD_LITERAL_WIDE: u8 = 21;
    pub const LOAD_NULL: u8 = 22;
    pub const LOAD_SMI_0: u8 = 23;
    pub const LOAD_SMIS_0: u8 = 24;
    pub const LOAD_SMI_1: u8 = 25;
    pub const LOAD_SMI_U8: u8 = 26;
    pub const LOAD_SMI_U16: u8 = 27;
    pub const LOAD_SMI_U32: u8 = 28;
    pub const LOAD_METHOD: u8 = 29;
    pub const LOAD_GLOBAL_VAR: u8 = 30;
    pub const LOAD_GLOBAL_VAR_WIDE: u8 = 31;
    pub const LOAD_GLOBAL_VAR_LAZY: u8 = 32;
    pub const LOAD_GLOBAL_VAR_LAZY_WIDE: u8 = 33;
    pub const LOAD_GLOBAL_VAR_DYNAMIC: u8 = 34;
    pub const STORE_GLOBAL_VAR: u8 = 35;
    pub const STORE_GLOBAL_VAR_WIDE: u8 = 36;
    pub const STORE_GLOBAL_VAR_DYNAMIC: u8 = 37;
    pub const LOAD_BLOCK: u8 = 38;
    pub const LOAD_OUTER_BLOCK: u8 = 39;
    pub const POP: u8 = 40;
    pub const POP_1: u8 = 41;
    pub const ALLOCATE: u8 = 42;
    pub const ALLOCATE_WIDE: u8 = 43;
    pub const IS_CLASS: u8 = 44;
    pub const IS_CLASS_WIDE: u8 = 45;
    pub const IS_INTERFACE: u8 = 46;
    pub const IS_INTERFACE_WIDE: u8 = 47;
    pub const AS_CLASS: u8 = 48;
    pub const AS_CLASS_WIDE: u8 = 49;
    pub const AS_INTERFACE: u8 = 50;
    pub const AS_INTERFACE_WIDE: u8 = 51;
    pub const AS_LOCAL: u8 = 52;
    pub const INVOKE_STATIC: u8 = 53;
    pub const INVOKE_STATIC_TAIL: u8 = 54;
    pub const INVOKE_BLOCK: u8 = 55;
    pub const INVOKE_LAMBDA_TAIL: u8 = 56;
    pub const INVOKE_INITIALIZER_TAIL: u8 = 57;
    pub const INVOKE_VIRTUAL: u8 = 58;
    pub const INVOKE_VIRTUAL_WIDE: u8 = 59;
    pub const INVOKE_VIRTUAL_GET: u8 = 60;
    pub const INVOKE_VIRTUAL_SET: u8 = 61;
    pub const INVOKE_EQ: u8 = 62;
    pub const INVOKE_LT: u8 = 63;
    pub const INVOKE_GT: u8 = 64;
    pub const INVOKE_LTE: u8 = 65;
    pub const INVOKE_GTE: u8 = 66;
    pub const INVOKE_BIT_OR: u8 = 67;
    pub const INVOKE_BIT_XOR: u8 = 68;
    pub const INVOKE_BIT_AND: u8 = 69;
    pub const INVOKE_BIT_SHL: u8 = 70;
    pub const INVOKE_BIT_SHR: u8 = 71;
    pub const INVOKE_BIT_USHR: u8 = 72;
    pub const INVOKE_ADD: u8 = 73;
    pub const INVOKE_SUB: u8 = 74;
    pub const INVOKE_MUL: u8 = 75;
    pub const INVOKE_DIV: u8 = 76;
    pub const INVOKE_MOD: u8 = 77;
    pub const INVOKE_AT: u8 = 78;
    pub const INVOKE_AT_PUT: u8 = 79;
    pub const INVOKE_SIZE: u8 = 80;
    pub const BRANCH: u8 = 81;
    pub const BRANCH_IF_TRUE: u8 = 82;
    pub const BRANCH_IF_FALSE: u8 = 83;
    pub const BRANCH_IF_NOT_NULL: u8 = 84;
    pub const BRANCH_BACK: u8 = 85;
    pub const BRANCH_BACK_IF_TRUE: u8 = 86;
    pub const BRANCH_BACK_IF_FALSE: u8 = 87;
    pub const BRANCH_BACK_IF_NOT_NULL: u8 = 88;
    pub const PRIMITIVE: u8 = 89;
    pub const THROW: u8 = 90;
    pub const RETURN: u8 = 91;
    pub const RETURN_NULL: u8 = 92;
    pub const NON_LOCAL_RETURN: u8 = 93;
    pub const STORE_FIELD_THIS: u8 = 94;
    pub const NON_LOCAL_BRANCH: u8 = 95;
    pub const IDENTICAL: u8 = 96;
    pub const TRY: u8 = 97;
    pub const LOAD_FIELD_THIS: u8 = 98;
    pub const UNWIND: u8 = 99;
    pub const HALT: u8 = 100;
    /// Proposal (verified/spec/format/19-builtins-proposal.md).
    pub const LOOP_REPEAT: u8 = 101;
    pub const LOOP_ARRAY: u8 = 102;
    pub const HASH_FIND: u8 = 103;
}

/// Instruction lengths in opcode order (OPCODE_LENGTHS2).
pub const OPCODE_LENGTHS: [u8; 114] = [
    2, 3, 2, 2, 2, 2, 2, 2, 3, 2, 2, 2, 3, 2,
    1, 1, 1, 1, 1, 1,
    2, 3, 1, 1, 2, 1, 2, 3, 5, 5,
    2, 3, 2, 3, 1, 2, 3, 1, 2, 2,
    2, 1,
    2, 3,
    2, 3, 2, 3, 2, 3, 2, 3, 2,
    3, 3, 2, 1, 1,
    4, 5, 3, 3,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3,
    3, 3, 3, 3, 3, 3, 3, 3,
    4, 1, 1, 1, 1, 2, 6, 1, 1, 2, 1, 2,
    4, 4, 5,
    2, 3, 2, 2, 2, 3, 2, 3, 3, 2,
];

pub fn opcode_length(op: u8) -> usize {
    OPCODE_LENGTHS[op as usize] as usize
}

/// The failures the machine raises (`literals[2 + k]`).
pub const LOOKUP_FAILED: usize = 0;
pub const AS_CHECK_FAILED: usize = 1;
pub const CODE_INVOCATION_FAILED: usize = 2;
pub const INVALID_PROGRAM: usize = 3;
pub const PRIMITIVE_LOOKUP_FAILED: usize = 4;

/// An unwinding in progress (`types::Unwind`). Words are object references
/// held across no GC point.
#[derive(Clone, Copy)]
pub enum Unwinding {
    Throw(usize),
    Return(usize, usize),
    Branch(usize, usize, usize),
}

/// The kinds of a finally record's resume word (`abs::resume_word`).
const UNWIND_THROW: usize = 0;
const UNWIND_RETURN: usize = 1;
const UNWIND_BRANCH: usize = 2;

/// The message of a raised failure (`TOIT_V2_MESSAGE_*`). Its words may be
/// object references: they are passed to C++ only by value and read there
/// before the first GC point.
pub struct Msg {
    pub kind: usize,
    pub words: [usize; V2_MESSAGE_MAX_WORDS],
    pub count: usize,
}

impl Msg {
    pub fn none() -> Msg {
        Msg { kind: V2_MESSAGE_NONE, words: [0; V2_MESSAGE_MAX_WORDS], count: 0 }
    }

    pub fn word(w: usize) -> Msg {
        Msg { kind: V2_MESSAGE_WORD, words: [w, 0, 0, 0], count: 1 }
    }

    pub fn array(ws: &[usize]) -> Msg {
        let mut words = [0; V2_MESSAGE_MAX_WORDS];
        let count = if ws.len() <= V2_MESSAGE_MAX_WORDS { ws.len() } else { V2_MESSAGE_MAX_WORDS };
        let mut i = 0;
        while i < count {
            words[i] = ws[i];
            i += 1;
        }
        Msg { kind: V2_MESSAGE_ARRAY, words, count }
    }

    /// Raw (untagged) module and index.
    pub fn primitive(module: usize, index: usize) -> Msg {
        Msg { kind: V2_MESSAGE_PRIMITIVE, words: [module, index, 0, 0], count: 2 }
    }
}

/// Runs `f` on the machine, out of line (the calls into C++ and the cold
/// paths of the checked loop). The run loops keep the machine behind a
/// pointer (the verified loop its hot part in registers, `regs.rs`), so
/// the machine is passed by reference.
#[inline(never)]
#[cold]
fn cold_run<R, F: FnOnce(&mut Machine) -> R>(m: &mut Machine, f: F) -> R {
    f(m)
}

/// `cold!(self, |m| expr)`: evaluates `expr` with `m` the machine, out of
/// line (see `cold_run`).
macro_rules! cold {
    ($s:expr, |$m:ident| $e:expr) => {{
        cold_run($s, |$m: &mut Machine| $e)
    }};
}

#[inline(always)]
pub fn smi(v: i64) -> usize {
    (v << 1) as usize
}

#[inline(always)]
pub fn is_smi(w: usize) -> bool {
    w & SMI_TAG_MASK == SMI_TAG
}

#[inline(always)]
pub fn smi_value(w: usize) -> i64 {
    ((w as isize) >> 1) as i64
}

#[inline(always)]
pub fn is_heap(w: usize) -> bool {
    w & NON_SMI_TAG_MASK == HEAP_TAG
}

#[inline(always)]
fn smi_ok(v: i64) -> bool {
    MIN_SMI <= v && v <= MAX_SMI
}

impl Machine {
    // -----------------------------------------------------------------------
    // Saving and reloading the task state.

    /// Re-derives the cached state from the (possibly new) stack view.
    /// Returns false if the stack object is malformed.
    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    pub fn reload(&mut self, p: &Program) -> bool {
        cold!(self, |m| m.reload_cold(p))
    }

    #[inline(never)]
    fn reload_cold(&mut self, p: &Program) -> bool {
        let len = self.mem.len();
        let top = self.mem.header(STACK_TOP_WORD);
        let word = self.mem.header(STACK_RECORD_TOP_WORD);
        let rtop = word & (MAX_STACK_LENGTH - 1);
        let ftop = word >> STACK_FRAME_TOP_SHIFT;
        let bci = self.mem.header(STACK_BCI_WORD);
        if top > len || rtop > top || rtop % FRAME_WORDS != 0 || len >= MAX_STACK_LENGTH
            || ftop > rtop || ftop % FRAME_WORDS != 0 {
            return false;
        }
        self.len = len;
        self.top = top;
        self.rtop = rtop;
        self.ftop = ftop;
        self.bci = bci;
        self.refresh_frame(p)
    }

    /// Caches the top frame's method, base and bounds.
    #[inline(always)]
    pub fn refresh_frame(&mut self, p: &Program) -> bool {
        if self.ftop < FRAME_WORDS {
            self.method = 0;
            self.base = 0;
            self.lim = self.len;
            return self.ftop == 0;
        }
        let r = self.ftop - FRAME_WORDS;
        let method = self.mem.read(r + FRAME_METHOD);
        let base = self.mem.read(r + FRAME_BASE);
        if method >= p.methods.len() || base > self.len {
            return false;
        }
        self.method = method;
        self.base = base;
        self.lim = self.len - base;
        true
    }

    // -----------------------------------------------------------------------
    // Checked stack helpers of the unverified handlers (the verified ones in
    // exec.rs rely on the invariant instead of checks).

    #[inline(always)]
    pub fn has_slot(&self, n: usize) -> bool {
        n < self.lim - self.top
    }

    /// Pushes `v` and continues after an instruction of length `len`.
    #[inline(always)]
    pub fn push_next_u(&mut self, v: usize, len: usize) -> Ctl {
        if !self.push(v) {
            return Ctl::Stuck(stuck::LIMIT);
        }
        self.bci = self.bci + len;
        Ctl::Next
    }

    /// Replaces the two operands by `v` (`binary_result`).
    #[inline(always)]
    pub fn binary_result(&mut self, v: usize) -> Ctl {
        self.put(1, v);
        self.drop(1);
        self.bci = self.bci + 1;
        Ctl::Next
    }

    // -----------------------------------------------------------------------
    // GC points.

    /// Allocates an instance (MAY GC).
    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    pub fn alloc_instance(&mut self, env: &Env, class_id: usize) -> Option<usize> {
        cold!(self, |m| m.alloc_instance_cold(env, class_id))
    }

    #[inline(never)]
    fn alloc_instance_cold(&mut self, env: &Env, class_id: usize) -> Option<usize> {
        self.save();
        let (r, _) = env.rt.allocate_instance(&mut self.mem, class_id);
        if !self.reload(&env.p) { return None; }
        if r == 0 { None } else { Some(r) }
    }

    /// Allocates an instance (MAY GC), without saving or reloading the
    /// task state: the verified ALLOCATE does both around it
    /// (`alloc::gc_allocate_instance`). 0 if out of memory.
    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    pub fn allocate_instance_raw(&mut self, env: &Env, class_id: usize) -> (usize, bool) {
        env.rt.allocate_instance(&mut self.mem, class_id)
    }

    /// Calls a C++ primitive (MAY GC, may switch the task) without saving
    /// or reloading the task state (`primitive::gc_call_primitive`); the
    /// stack view is replaced only if the heap's epoch changed.
    #[inline(always)]
    pub fn call_primitive_raw(&mut self, env: &Env, module: u8, index: u16, arity: usize, first: usize) -> (usize, usize, bool) {
        env.rt.call_primitive(&mut self.mem, module as usize, index as usize, arity, first)
    }

    /// Grows the stack (MAY GC) without saving or reloading the task state
    /// (`step::gc_grow_stack`).
    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    pub fn grow_stack_raw(&mut self, env: &Env, needed: usize) -> usize {
        cold!(self, |m| env.rt.grow_stack(&mut m.mem, needed))
    }

    /// Allocates an exception (MAY GC) without saving or reloading the task
    /// state (`raise::gc_allocate_exception`). 0 if out of memory.
    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    pub fn allocate_exception_raw(&mut self, env: &Env, value: usize, kind: usize,
                                  ws: &[usize; V2_MESSAGE_MAX_WORDS], count: usize) -> usize {
        cold!(self, |m| env.rt.allocate_exception(&mut m.mem, value, kind, ws, count))
    }

    /// Allocates a double (MAY GC) without saving or reloading the task
    /// state (`alloc::gc_allocate_double`). 0 if out of memory.
    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    pub fn allocate_double_raw(&mut self, env: &Env, bits: u64) -> (usize, bool) {
        env.rt.allocate_double(&mut self.mem, bits)
    }

    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    pub fn alloc_double(&mut self, env: &Env, bits: u64) -> Option<usize> {
        cold!(self, |m| m.alloc_double_cold(env, bits))
    }

    #[inline(never)]
    fn alloc_double_cold(&mut self, env: &Env, bits: u64) -> Option<usize> {
        self.save();
        let (r, _) = env.rt.allocate_double(&mut self.mem, bits);
        if !self.reload(&env.p) { return None; }
        if r == 0 { None } else { Some(r) }
    }

    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    pub fn alloc_array(&mut self, env: &Env, length: usize, filler: usize) -> Option<usize> {
        cold!(self, |m| m.alloc_array_cold(env, length, filler))
    }

    #[inline(never)]
    fn alloc_array_cold(&mut self, env: &Env, length: usize, filler: usize) -> Option<usize> {
        self.save();
        let r = env.rt.allocate_array(&mut self.mem, length, filler);
        if !self.reload(&env.p) { return None; }
        if r == 0 { None } else { Some(r) }
    }

    /// After a call has set up the new frame (as format 1, which checks at
    /// the target's entry, so the profiler sees the callee): leave the run
    /// loop if preemption is requested; the task continues at the entry.
    #[inline(always)]
    pub fn preempt_point(env: &Env) -> Ctl {
        if env.pre.requested() {
            env.pre.clear();
            return Ctl::Exit(RESULT_PREEMPTED as u32, 0);
        }
        Ctl::Next
    }

    /// Before a call: room for a frame of any method.
    /// `None` means proceed; otherwise the instruction is not executed
    /// (it runs again after the preemption or the stack growth).
    #[inline(always)]
    pub fn ensure_room(&mut self, env: &Env) -> Option<Ctl> {
        let needed = FRAME_WORDS + env.p.max_height + STACK_RESERVE;
        if self.top - self.rtop >= needed { return None; }
        Some(self.grow(env, needed))
    }

    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    pub fn grow(&mut self, env: &Env, needed: usize) -> Ctl {
        cold!(self, |m| m.grow_cold(env, needed))
    }

    #[inline(never)]
    fn grow_cold(&mut self, env: &Env, needed: usize) -> Ctl {
        self.save();
        let status = env.rt.grow_stack(&mut self.mem, needed);
        if !self.reload(&env.p) { return Ctl::Stuck(stuck::FATAL); }
        if status == V2_OK { return Ctl::Next; }
        let error = if status == V2_STACK_OVERFLOW {
            env.p.roots.at(ROOT_STACK_OVERFLOW)
        } else {
            env.p.roots.at(ROOT_OUT_OF_MEMORY_ERROR)
        };
        if status == V2_STACK_OVERFLOW {
            self.raise_value(env, error)
        } else {
            self.unwind(env, Unwinding::Throw(error))
        }
    }

    // -----------------------------------------------------------------------
    // Exceptions and unwinding.

    /// Raises failure `k` (`spec::raise`). `INVALID_PROGRAM` carries the
    /// bci of the failing instruction as message, as in format 1.
    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    pub fn raise(&mut self, env: &Env, k: usize) -> Ctl {
        cold!(self, |m| m.raise_cold(env, k))
    }

    #[inline(never)]
    fn raise_cold(&mut self, env: &Env, k: usize) -> Ctl {
        let msg = if k == INVALID_PROGRAM { Msg::word(smi(self.bci as i64)) } else { Msg::none() };
        self.raise_msg(env, k, msg)
    }

    /// Raises failure `k` with the message the format-1 failure entry point
    /// would have encoded (diagnostics only: the message is part of the
    /// trace, which the spec leaves null).
    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    pub fn raise_msg(&mut self, env: &Env, k: usize, msg: Msg) -> Ctl {
        cold!(self, |m| m.raise_msg_cold(env, k, msg))
    }

    #[inline(never)]
    fn raise_msg_cold(&mut self, env: &Env, k: usize, msg: Msg) -> Ctl {
        if env.p.literals.len() < FAILURE_LITERALS { return Ctl::Stuck(stuck::FATAL); }
        let value = env.p.literals.at(2 + k);
        self.raise_value_msg(env, value, msg)
    }

    /// `LOOKUP_FAILED` with `[selector offset, class id, receiver]`.
    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    pub fn raise_lookup(&mut self, env: &Env, receiver: usize, sel: i64) -> Ctl {
        cold!(self, |m| m.raise_lookup_cold(env, receiver, sel))
    }

    #[inline(never)]
    fn raise_lookup_cold(&mut self, env: &Env, receiver: usize, sel: i64) -> Ctl {
        let cid = match self.class_id(&env.p, receiver) { Some(c) => c, None => -1 };
        self.raise_msg(env, LOOKUP_FAILED, Msg::array(&[smi(sel), smi(cid), receiver]))
    }

    /// `AS_CHECK_FAILED` with `[value, absolute bci after the check]` (the
    /// compiler records the class name of the check at that bci).
    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    pub fn raise_as(&mut self, env: &Env, value: usize, len: usize) -> Ctl {
        cold!(self, |m| m.raise_as_cold(env, value, len))
    }

    #[inline(never)]
    fn raise_as_cold(&mut self, env: &Env, value: usize, len: usize) -> Ctl {
        let after = self.bci + len;
        self.raise_msg(env, AS_CHECK_FAILED, Msg::array(&[value, smi(after as i64)]))
    }

    /// `CODE_INVOCATION_FAILED` with `[is block, expected, provided, entry
    /// bci of the target]`.
    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    pub fn raise_code(&mut self, env: &Env, is_block: bool, expected: usize, provided: usize, target: usize) -> Ctl {
        cold!(self, |m| m.raise_code_cold(env, is_block, expected, provided, target))
    }

    #[inline(never)]
    fn raise_code_cold(&mut self, env: &Env, is_block: bool, expected: usize, provided: usize, target: usize) -> Ctl {
        let p = &env.p;
        let entry = if target < p.methods.len() { p.method(target).entry as i64 } else { -1 };
        let words = [p.boolean(is_block), smi(expected as i64), smi(provided as i64), smi(entry)];
        self.raise_msg(env, CODE_INVOCATION_FAILED, Msg::array(&words))
    }

    /// Throws an `Exception_` with the given value (a program-heap object:
    /// it survives the allocation) and an empty message.
    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    pub fn raise_value(&mut self, env: &Env, value: usize) -> Ctl {
        cold!(self, |m| m.raise_value_cold(env, value))
    }

    #[inline(never)]
    fn raise_value_cold(&mut self, env: &Env, value: usize) -> Ctl {
        self.raise_value_msg(env, value, Msg::none())
    }

    /// Throws an `Exception_` with the given value (a program-heap object:
    /// it survives the allocation). The spec's trace is null; the VM
    /// encodes the stack trace and the message, as format 1 does
    /// (verified/spec/format/PHASE4-REQUESTS.md).
    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    pub fn raise_value_msg(&mut self, env: &Env, value: usize, msg: Msg) -> Ctl {
        cold!(self, |m| m.raise_value_msg_cold(env, value, msg))
    }

    #[inline(never)]
    fn raise_value_msg_cold(&mut self, env: &Env, value: usize, msg: Msg) -> Ctl {
        let p = &env.p;
        let cid = p.builtin.at(BUILTIN_EXCEPTION);
        if !is_smi(cid) { return Ctl::Stuck(stuck::FATAL); }
        let cid = smi_value(cid);
        if cid < 0 || cid as usize >= p.class_bits.len() || p.instance_field_count(cid as usize) < 2 {
            return Ctl::Stuck(stuck::FATAL);
        }
        self.save();
        let exception = env.rt.allocate_exception(&mut self.mem, value, msg.kind, &msg.words, msg.count);
        if !self.reload(p) { return Ctl::Stuck(stuck::FATAL); }
        if exception == 0 {
            let oom = p.roots.at(ROOT_OUT_OF_MEMORY_ERROR);
            return self.unwind(env, Unwinding::Throw(oom));
        }
        self.unwind(env, Unwinding::Throw(exception))
    }

    /// Enters the finally code of the top frame's handler (`enter_finally`).
    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    pub fn enter_finally(&mut self, env: &Env, handler: usize, u: Option<Unwinding>) -> Ctl {
        cold!(self, |m| m.enter_finally_cold(env, handler, u))
    }

    #[inline(never)]
    fn enter_finally_cold(&mut self, env: &Env, handler: usize, u: Option<Unwinding>) -> Ctl {
        let p = &env.p;
        let height = handler;
        if !(self.base <= height && height <= self.len - self.top) {
            return Ctl::Stuck(stuck::STACK_RANGE);
        }
        self.top = self.len - height;
        let r = self.ftop - FRAME_WORDS;
        let hbci = self.mem.read(r + FRAME_HANDLER_BCI);
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
                let (value, reason, resume, target, target_height) = match w {
                    Unwinding::Throw(v) => (v, -2, UNWIND_THROW, 0, 0),
                    Unwinding::Return(f, v) => (v, -1, UNWIND_RETURN + f * 4, 0, 0),
                    Unwinding::Branch(f, bci, h) => (null, -1, UNWIND_BRANCH + f * 4, bci, h),
                };
                if self.top - self.rtop < FIN_WORDS + 3 { return Ctl::Stuck(stuck::LIMIT); }
                let k = (self.rtop - self.ftop) / FIN_WORDS;
                let e = self.rtop;
                self.mem.write(e + FIN_FRAME, r / FRAME_WORDS);
                self.mem.write(e + FIN_HEIGHT, height);
                self.mem.write(e + FIN_RESUME, resume);
                self.mem.write(e + FIN_TARGET, target);
                self.mem.write(e + FIN_TARGET_HEIGHT, target_height);
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

    /// `spec::unwind`.
    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    pub fn unwind(&mut self, env: &Env, u: Unwinding) -> Ctl {
        cold!(self, |m| m.unwind_cold(env, u))
    }

    #[inline(never)]
    fn unwind_cold(&mut self, env: &Env, u: Unwinding) -> Ctl {
        loop {
            if self.ftop < FRAME_WORDS {
                return match u {
                    Unwinding::Throw(_) => {
                        env.rt.report(V2_REPORT_UNCAUGHT, self.bci, 0);
                        Ctl::Exit(RESULT_TERMINATED as u32, 1)
                    }
                    _ => Ctl::Stuck(stuck::BAD_FRAME),
                };
            }
            let r = self.ftop - FRAME_WORDS;
            let handler = self.mem.read(r + FRAME_HANDLER);
            if handler != 0 {
                return self.enter_finally(env, handler, Some(u));
            }
            let height = self.len - self.top;
            if self.base > height { return Ctl::Stuck(stuck::STACK_RANGE); }
            let fi = self.ftop / FRAME_WORDS - 1;
            match u {
                Unwinding::Return(f, v) if f == fi => return self.return_from(env, v),
                Unwinding::Branch(f, bci, h) if f == fi => {
                    if !(self.base <= h && h <= height) { return Ctl::Stuck(stuck::STACK_RANGE); }
                    self.top = self.len - h;
                    self.bci = bci;
                    return Ctl::Next;
                }
                _ => {}
            }
            // Pop the frame.
            self.top = self.len - self.base;
            self.pop_frame_record();
            if !self.refresh_frame(&env.p) { return Ctl::Stuck(stuck::FATAL); }
        }
    }

    /// `spec::return_from`.
    #[inline(always)]
    pub fn return_from(&mut self, env: &Env, result: usize) -> Ctl {
        if self.ftop < FRAME_WORDS { return Ctl::Stuck(stuck::BAD_FRAME); }
        let r = self.ftop - FRAME_WORDS;
        if self.mem.read(r + FRAME_HANDLER) != 0 { return Ctl::Stuck(stuck::BAD_FRAME); }
        if self.ftop == FRAME_WORDS {
            env.rt.report(V2_REPORT_TASK_RETURNED, self.bci, 0);
            return Ctl::Exit(RESULT_TERMINATED as u32, 1);
        }
        let height = self.len - self.top;
        if self.base > height { return Ctl::Stuck(stuck::STACK_RANGE); }
        let ret = self.mem.read(r + FRAME_RET);
        self.top = self.len - self.base;
        self.pop_frame_record();
        if !self.refresh_frame(&env.p) { return Ctl::Stuck(stuck::FATAL); }
        if !self.push(result) { return Ctl::Stuck(stuck::LIMIT); }
        self.bci = ret;
        let handler = self.mem.read(self.ftop - FRAME_WORDS + FRAME_HANDLER);
        if handler != 0 {
            return self.enter_finally(env, handler, None);
        }
        Ctl::Next
    }

    // -----------------------------------------------------------------------
    // Calls.

    /// `spec::call`: a frame for `target`, whose arguments are the top
    /// `arity` slots.
    #[inline(always)]
    pub fn call(&mut self, env: &Env, target: usize, ret: usize) -> Ctl {
        let p = &env.p;
        if target >= p.methods.len() { return Ctl::Stuck(stuck::NOT_METHOD); }
        let info = p.method(target);
        let arity = info.arity as usize;
        if arity > self.lim - self.top { return Ctl::Stuck(stuck::STACK_RANGE); }
        if self.rtop + FRAME_WORDS > self.top { return Ctl::Stuck(stuck::LIMIT); }
        let height = self.len - self.top;
        let base = height - arity;
        let (f, e) = (self.ftop, self.rtop);
        if e > f {
            // The finally records move up over the new frame record.
            self.mem.copy_within(f, f + FRAME_WORDS, e - f);
        }
        self.rtop = e + FRAME_WORDS;
        self.mem.write(f + FRAME_METHOD, target);
        self.mem.write(f + FRAME_RET, ret);
        self.mem.write(f + FRAME_BASE, base);
        self.mem.write(f + FRAME_HANDLER, 0);
        self.ftop = f + FRAME_WORDS;
        self.method = target;
        self.base = base;
        self.lim = self.len - base;
        self.bci = info.entry as usize;
        Self::preempt_point(env)
    }

    /// The class id of a value, if it has one (`class_id_ok`).
    #[inline(always)]
    pub fn class_id(&self, p: &Program, v: usize) -> Option<i64> {
        if is_smi(v) {
            Some((p.smi_class_id as i64))
        } else if is_heap(v) {
            Some(smi_value(self.heap.header(v)) >> CLASS_ID_OFFSET)
        } else {
            None
        }
    }

    /// `spec::call_static`.
    #[inline(always)]
    pub fn call_static(&mut self, env: &Env, target: i64, len: usize) -> Ctl {
        let p = &env.p;
        if target < 0 || target as usize >= p.methods.len() { return Ctl::Stuck(stuck::NOT_METHOD); }
        let info = p.method(target as usize);
        let arity = info.arity as usize;
        if arity > self.lim - self.top { return Ctl::Stuck(stuck::STACK_RANGE); }
        if info.recv_start != NO_VALUE {
            if arity == 0 { return Ctl::Stuck(stuck::NOT_OBJECT); }
            let receiver = self.mem.read(self.top + arity - 1);
            match self.class_id(p, receiver) {
                None => return Ctl::Stuck(stuck::NOT_OBJECT),
                Some(cid) => {
                    if !((info.recv_start as i64) <= cid && cid < info.recv_end as i64) {
                        return self.raise(env, AS_CHECK_FAILED);
                    }
                }
            }
        }
        let ret = self.bci + len;
        self.call(env, target as usize, ret)
    }

    /// `spec::replace_frame`: the top frame's method becomes `target`, whose
    /// arguments are the `n` words at array indices `from..from+n` followed
    /// by `extra` (lambda captures, copied by the caller afterwards).
    #[inline(always)]
    pub fn replace_frame(&mut self, env: &Env, target: usize, from: usize, n: usize, extra: usize) -> Ctl {
        let p = &env.p;
        let r = self.ftop - FRAME_WORDS;
        if self.mem.read(r + FRAME_HANDLER) != 0 { return Ctl::Stuck(stuck::BAD_FRAME); }
        // The frame's finally records go (`fins_popped`).
        self.cut_fins(r / FRAME_WORDS, 0);
        // New object stack: stack[0..base] + args; args end at array index
        // len - base.
        let new_top = self.lim - n - extra;
        if new_top < self.rtop { return Ctl::Stuck(stuck::LIMIT); }
        self.mem.copy_within(from, new_top + extra, n);
        self.top = new_top;
        let info = p.method(target);
        self.mem.write(r + FRAME_METHOD, target);
        self.method = target;
        self.bci = info.entry as usize;
        Self::preempt_point(env)
    }

    /// `spec::find_method`.
    #[inline(always)]
    pub fn find_method(&self, p: &Program, receiver: usize, sel: i64) -> Lookup {
        let cid = match self.class_id(p, receiver) {
            None => return Lookup::Stuck(stuck::NOT_OBJECT),
            Some(c) => c,
        };
        if sel < 0 { return Lookup::Missing; }
        let index = cid + sel;
        if index < 0 || index as usize >= p.dispatch.len() { return Lookup::Stuck(stuck::TABLE_RANGE); }
        let entry = p.dispatch.at(index as usize);
        if entry == -1 { return Lookup::Missing; }
        if entry < 0 || entry as usize >= p.methods.len() { return Lookup::Stuck(stuck::NOT_METHOD); }
        if p.method(entry as usize).selector as i64 != sel { return Lookup::Missing; }
        Lookup::Found(entry as usize)
    }

    /// `spec::invoke_virtual`.
    #[inline(always)]
    pub fn invoke_virtual(&mut self, env: &Env, sel: i64, n: usize, len: usize) -> Ctl {
        if n < 1 || !self.has_slot(n - 1) { return Ctl::Stuck(stuck::STACK_RANGE); }
        let receiver = self.at(n - 1);
        match self.find_method(&env.p, receiver, sel) {
            Lookup::Stuck(r) => Ctl::Stuck(r),
            Lookup::Missing => self.raise_lookup(env, receiver, sel),
            Lookup::Found(t) => {
                if env.p.method(t).arity as usize != n { return Ctl::Stuck(stuck::BAD_ARITY); }
                let ret = self.bci + len;
                self.call(env, t, ret)
            }
        }
    }

    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    fn operator_fallback(&mut self, env: &Env, opcode: u8) -> Ctl {
        cold!(self, |m| m.operator_fallback_cold(env, opcode))
    }

    #[inline(never)]
    fn operator_fallback_cold(&mut self, env: &Env, opcode: u8) -> Ctl {
        let n = if opcode == op::INVOKE_AT_PUT { 3 } else { 2 };
        let sel = env.p.invoke_offsets.at((opcode - op::INVOKE_EQ) as usize) as i64;
        self.invoke_virtual(env, sel, n, 1)
    }

    // -----------------------------------------------------------------------
    // Heap helpers.

    /// The class tag of a heap object.
    #[inline(always)]
    pub fn tag(&self, obj: usize) -> usize {
        (smi_value(self.heap.header(obj)) as usize) & CLASS_TAG_MASK
    }

    /// The fields of an instance (`is_instance`): the number of fields, or
    /// None.
    #[inline(always)]
    pub fn instance_fields(&self, p: &Program, v: usize) -> Option<usize> {
        if !is_heap(v) { return None; }
        let header = smi_value(self.heap.header(v));
        let tag = (header as usize) & CLASS_TAG_MASK;
        if tag != INSTANCE_TAG && tag != TASK_TAG { return None; }
        let cid = header >> CLASS_ID_OFFSET;
        if cid < 0 || cid as usize >= p.class_bits.len() { return None; }
        let n = p.instance_field_count(cid as usize);
        if n < 0 { None } else { Some(n as usize) }
    }

    /// Field `f` of `v` may be read. A task's field TASK_STACK_FIELD holds
    /// its Stack, which the VM owns: no program may read or write it
    /// (PHASE4-REQUESTS.md R5; found by the fuzz harness: a verified
    /// program overwrote it and the scheduler then used the value as a
    /// stack).
    #[inline(always)]
    pub fn field_ok(&self, p: &Program, v: usize, f: usize) -> bool {
        match self.instance_fields(p, v) {
            Some(n) => f < n && !(f == TASK_STACK_FIELD && self.tag(v) == TASK_TAG),
            None => false,
        }
    }

    /// Field `f` of `v` may be written: readable, and not a task's id
    /// (TASK_ID_FIELD, set by the VM).
    #[inline(always)]
    pub fn field_store_ok(&self, p: &Program, v: usize, f: usize) -> bool {
        self.field_ok(p, v, f) && !(f == TASK_ID_FIELD && self.tag(v) == TASK_TAG)
    }

    #[inline(always)]
    pub fn field(&self, v: usize, f: usize) -> usize {
        self.heap.word(v, INSTANCE_FIELDS_WORD + f)
    }

    #[inline(always)]
    pub fn is_ro(&self, p: &Program, v: usize) -> bool {
        v.wrapping_sub(p.ro_start) < p.ro_size
    }

    #[inline(always)]
    pub fn array_length(&self, v: usize) -> Option<usize> {
        if is_heap(v) && self.tag(v) == ARRAY_TAG {
            Some(self.heap.word(v, ARRAY_LENGTH_WORD))
        } else {
            None
        }
    }

    #[inline(always)]
    pub fn is_double(&self, v: usize) -> bool {
        is_heap(v) && self.tag(v) == DOUBLE_TAG
    }

    #[inline(always)]
    pub fn double_bits(&self, v: usize) -> u64 {
        self.heap.word64(v, DOUBLE_VALUE_WORD)
    }

    #[inline(always)]
    pub fn is_large_int(&self, v: usize) -> bool {
        is_heap(v) && self.tag(v) == LARGE_INTEGER_TAG
    }

    /// The bytes of a byte array the fast paths may access: (external
    /// address or 0 for inline content, length), or None.
    #[inline(always)]
    pub fn byte_array(&self, v: usize, is_put: bool) -> Option<(usize, usize)> {
        if !is_heap(v) || self.tag(v) != BYTE_ARRAY_TAG { return None; }
        let raw = self.heap.word(v, BYTE_ARRAY_LENGTH_WORD) as isize as i64;
        if raw >= 0 { return Some((0, raw as usize)); }
        let tag = self.heap.word(v, BYTE_ARRAY_EXTERNAL_TAG_WORD);
        if tag == RAW_BYTE_TAG || (!is_put && tag == MAPPED_FILE_TAG) {
            let address = self.heap.word(v, BYTE_ARRAY_EXTERNAL_ADDRESS_WORD);
            if address == 0 { return None; }
            Some((address, (-1 - raw) as usize))
        } else {
            None
        }
    }

    /// The bytes of a string: (external address or 0, length).
    #[inline(always)]
    pub fn string_bytes(&self, v: usize) -> Option<(usize, usize)> {
        if !is_heap(v) || self.tag(v) != STRING_TAG { return None; }
        let internal = self.heap.half_word_at(v, STRING_INTERNAL_LENGTH_BYTE);
        if internal != STRING_SENTINEL { return Some((0, internal)); }
        let length = self.heap.word(v, STRING_EXTERNAL_LENGTH_WORD);
        let address = self.heap.word(v, STRING_EXTERNAL_ADDRESS_WORD);
        Some((address, length))
    }

    /// `spec_helpers::num_of`: a smi, large integer or double.
    #[inline(always)]
    fn number(&self, v: usize) -> Option<Num> {
        if is_smi(v) {
            Some(Num::Int(smi_value(v)))
        } else if self.is_large_int(v) {
            Some(Num::Int(self.heap.word64(v, LARGE_INTEGER_VALUE_WORD) as i64))
        } else if self.is_double(v) {
            Some(Num::Dbl(f64::from_bits(self.double_bits(v))))
        } else {
            None
        }
    }

    /// `spec_helpers::compare_numbers`.
    #[inline(always)]
    pub fn compare_numbers(&self, a: usize, b: usize) -> u8 {
        match (self.number(a), self.number(b)) {
            (Some(x), Some(y)) => compare_num(x, y),
            _ => 0,
        }
    }

    /// `spec_helpers::identical`.
    #[inline(always)]
    pub fn identical(&self, a: usize, b: usize) -> bool {
        if a == b { return true; }
        if self.is_double(a) && self.is_double(b) {
            return self.double_bits(a) == self.double_bits(b);
        }
        if self.is_large_int(a) && self.is_large_int(b) {
            return self.heap.word64(a, LARGE_INTEGER_VALUE_WORD) == self.heap.word64(b, LARGE_INTEGER_VALUE_WORD);
        }
        match (self.string_bytes(a), self.string_bytes(b)) {
            (Some((aa, al)), Some((ba, bl))) => {
                if al != bl { return false; }
                let ao = if aa == 0 { STRING_CONTENT_BYTE } else { 0 };
                let bo = if ba == 0 { STRING_CONTENT_BYTE } else { 0 };
                let mut i = 0;
                while i < al {
                    if self.heap.byte(a, aa, ao + i) != self.heap.byte(b, ba, bo + i) { return false; }
                    i += 1;
                }
                true
            }
            _ => false,
        }
    }

    // -----------------------------------------------------------------------
    // Fast paths for INVOKE_AT, INVOKE_AT_PUT and INVOKE_SIZE
    // (`spec_helpers::fast_at`, `fast_size`).

    #[inline(always)]
    fn array_at(&mut self, p: &Program, arr: usize, length: usize, n: usize, is_put: bool, value: usize) -> FastAt {
        let elements = self.heap.word(arr, ARRAY_LENGTH_WORD);
        if n >= length || n >= elements { return FastAt::Fail; }
        if is_put {
            if self.is_ro(p, arr) { return FastAt::Fail; }
            self.heap.set_word(arr, ARRAY_ELEMENTS_WORD + n, value);
            FastAt::Done(value)
        } else {
            FastAt::Done(self.heap.word(arr, ARRAY_ELEMENTS_WORD + n))
        }
    }

    #[inline(always)]
    fn bytes_at(&mut self, p: &Program, ba: usize, n: usize, is_put: bool, value: usize) -> FastAt {
        let (address, length) = match self.byte_array(ba, is_put) {
            None => return FastAt::Fail,
            Some(x) => x,
        };
        if n >= length { return FastAt::Fail; }
        let offset = if address == 0 { BYTE_ARRAY_CONTENT_BYTE + n } else { n };
        if is_put {
            if !is_smi(value) || self.is_ro(p, ba) { return FastAt::Fail; }
            let b = smi_value(value) as u8;
            self.heap.set_byte(ba, address, offset, b);
            FastAt::Done(smi(b as i64))
        } else {
            FastAt::Done(smi(self.heap.byte(ba, address, offset) as i64))
        }
    }

    #[inline(always)]
    fn cow_at(&mut self, p: &Program, cow: usize, n: usize, is_put: bool, value: usize) -> FastAt {
        match self.instance_fields(p, cow) {
            Some(f) if f >= 2 => {}
            _ => return FastAt::Fail,
        }
        if is_put && self.field(cow, 1) == p.false_ { return FastAt::Fail; }
        let backing = self.field(cow, 0);
        self.bytes_at(p, backing, n, is_put, value)
    }

    #[inline(always)]
    pub fn fast_at(&mut self, p: &Program, recv: usize, arg: usize, is_put: bool, value: usize, fuel: usize) -> FastAt {
        if !is_smi(arg) { return FastAt::Fail; }
        let n = smi_value(arg);
        if n < 0 { return FastAt::Fail; }
        let n = n as usize;
        if !is_heap(recv) { return FastAt::Fail; }
        let tag = self.tag(recv);
        if tag == ARRAY_TAG {
            let length = self.heap.word(recv, ARRAY_LENGTH_WORD);
            return self.array_at(p, recv, length, n, is_put, value);
        }
        if tag == BYTE_ARRAY_TAG {
            return self.bytes_at(p, recv, n, is_put, value);
        }
        let fields = match self.instance_fields(p, recv) {
            None => return FastAt::Fail,
            Some(f) => f,
        };
        let cid = smi_value(self.heap.header(recv)) >> CLASS_ID_OFFSET;
        if cid == (p.list_class_id as i64) {
            if fields < 2 { return FastAt::Fail; }
            let backing = self.field(recv, 0);
            let size = self.field(recv, 1);
            if let Some(length) = self.array_length(backing) {
                if !is_smi(size) { return FastAt::Fail; }
                let size = smi_value(size);
                if size < 0 || size as usize > length { return FastAt::Fail; }
                return self.array_at(p, backing, size as usize, n, is_put, value);
            }
            // A list backed by a large array.
            return self.large_array_at(p, backing, size, n, is_put, value, fuel);
        }
        if cid == (p.byte_array_slice_class_id as i64) {
            if fields < 3 { return FastAt::Fail; }
            let data = self.field(recv, 0);
            let from = self.field(recv, 1);
            let to = self.field(recv, 2);
            if !is_smi(from) || !is_smi(to) { return FastAt::Fail; }
            let (from, to) = (smi_value(from), smi_value(to));
            if from < 0 { return FastAt::Fail; }
            let m = from + n as i64;
            if m >= to { return FastAt::Fail; }
            if is_heap(data) && self.tag(data) == BYTE_ARRAY_TAG {
                return self.bytes_at(p, data, m as usize, is_put, value);
            }
            if let Some(_) = self.instance_fields(p, data) {
                let dcid = smi_value(self.heap.header(data)) >> CLASS_ID_OFFSET;
                if dcid != (p.byte_array_cow_class_id as i64) { return FastAt::Fail; }
                return self.cow_at(p, data, m as usize, is_put, value);
            }
            return FastAt::Fail;
        }
        if cid == (p.large_array_class_id as i64) {
            if fields < 2 { return FastAt::Fail; }
            let size = self.field(recv, 0);
            return self.large_array_at(p, recv, size, n, is_put, value, fuel);
        }
        if cid == (p.byte_array_cow_class_id as i64) {
            return self.cow_at(p, recv, n, is_put, value);
        }
        FastAt::Fail
    }

    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    fn large_array_at(&mut self, p: &Program, la: usize, size: usize, n: usize, is_put: bool, value: usize, fuel: usize) -> FastAt {
        cold!(self, |m| m.large_array_at_cold(p, la, size, n, is_put, value, fuel))
    }

    #[inline(never)]
    fn large_array_at_cold(&mut self, p: &Program, la: usize, size: usize, n: usize, is_put: bool, value: usize, fuel: usize) -> FastAt {
        match self.instance_fields(p, la) {
            Some(f) if f >= 2 => {}
            _ => return FastAt::Fail,
        }
        let lcid = smi_value(self.heap.header(la)) >> CLASS_ID_OFFSET;
        if lcid != (p.large_array_class_id as i64) { return FastAt::Fail; }
        let vector = self.field(la, 1);
        if !is_smi(size) { return FastAt::Fail; }
        let size = smi_value(size);
        if n as i64 >= size { return FastAt::Fail; }
        let vector_ok = self.array_length(vector).is_some() || {
            match self.instance_fields(p, vector) {
                Some(vf) if vf >= 1 => {
                    let vcid = smi_value(self.heap.header(vector)) >> CLASS_ID_OFFSET;
                    let vsize = self.field(vector, 0);
                    vcid == (p.large_array_class_id as i64) && is_smi(vsize) && smi_value(vsize) < size
                }
                _ => false,
            }
        };
        if !vector_ok || fuel == 0 { return FastAt::Fail; }
        let null = p.null;
        match self.fast_at(p, vector, smi((n / ARRAYLET_SIZE) as i64), false, null, fuel - 1) {
            FastAt::Done(arraylet) => {
                if self.array_length(arraylet).is_none() { return FastAt::Fail; }
                self.fast_at(p, arraylet, smi((n % ARRAYLET_SIZE) as i64), is_put, value, fuel - 1)
            }
            _ => FastAt::Fail,
        }
    }

    #[inline(always)]
    pub fn fast_size(&self, p: &Program, recv: usize) -> Option<i64> {
        if !is_heap(recv) { return None; }
        let tag = self.tag(recv);
        if tag == ARRAY_TAG { return Some(self.heap.word(recv, ARRAY_LENGTH_WORD) as i64); }
        if tag == BYTE_ARRAY_TAG {
            return match self.byte_array(recv, false) {
                Some((_, length)) => Some(length as i64),
                None => None,
            };
        }
        let fields = self.instance_fields(p, recv)?;
        let cid = smi_value(self.heap.header(recv)) >> CLASS_ID_OFFSET;
        if cid == (p.list_class_id as i64) && fields >= 2 {
            let size = self.field(recv, 1);
            if is_smi(size) { Some(smi_value(size)) } else { None }
        } else if cid == (p.byte_array_slice_class_id as i64) && fields >= 3 {
            let from = self.field(recv, 1);
            let to = self.field(recv, 2);
            if is_smi(from) && is_smi(to) && 0 <= smi_value(from) && smi_value(from) <= smi_value(to) {
                Some(smi_value(to) - smi_value(from))
            } else {
                None
            }
        } else if cid == (p.large_array_class_id as i64) && fields >= 1 {
            let size = self.field(recv, 0);
            if is_smi(size) { Some(smi_value(size)) } else { None }
        } else if cid == (p.byte_array_cow_class_id as i64) && fields >= 1 {
            match self.byte_array(self.field(recv, 0), false) {
                Some((_, length)) => Some(length as i64),
                None => None,
            }
        } else {
            None
        }
    }

    // -----------------------------------------------------------------------
    // Type checks.

    #[inline(always)]
    pub fn typecheck_class(&self, p: &Program, v: usize, ci: usize, nullable: bool) -> Check {
        if nullable && v == p.null { return Check::Yes; }
        let cid = match self.class_id(p, v) {
            None => return Check::Stuck(stuck::NOT_OBJECT),
            Some(c) => c,
        };
        if 2 * ci + 1 >= p.class_check_ids.len() { return Check::Stuck(stuck::TABLE_RANGE); }
        let start = p.class_check_ids.at(2 * ci) as i64;
        let end = p.class_check_ids.at(2 * ci + 1) as i64;
        if start <= cid && cid < end { Check::Yes } else { Check::No }
    }

    #[inline(always)]
    pub fn typecheck(&self, p: &Program, v: usize, index: usize, nullable: bool, interface: bool) -> Check {
        if !interface { return self.typecheck_class(p, v, index, nullable); }
        if nullable && v == p.null { return Check::Yes; }
        if index >= p.interface_check_offsets.len() { return Check::Stuck(stuck::TABLE_RANGE); }
        let sel = p.interface_check_offsets.at(index) as i64;
        match self.find_method(p, v, sel) {
            Lookup::Found(_) => Check::Yes,
            Lookup::Missing => Check::No,
            Lookup::Stuck(r) => Check::Stuck(r),
        }
    }

    // -----------------------------------------------------------------------
    // Block references.

    /// The frame and slot of a valid block reference (`block_ref`).
    #[inline(always)]
    pub fn block_ref(&self, v: usize) -> Option<(usize, usize)> {
        if !is_smi(v) { return None; }
        let value = smi_value(v);
        if value < 0 { return None; }
        let value = value as usize;
        let f = value >> BLOCK_SLOT_BITS;
        let slot = value & ((1 << BLOCK_SLOT_BITS) - 1);
        let nframes = self.ftop / FRAME_WORDS;
        if f >= nframes { return None; }
        let height = self.len - self.top;
        if slot >= height { return None; }
        let fbase = self.mem.read(f * FRAME_WORDS + FRAME_BASE);
        if slot < fbase { return None; }
        let limit = if f + 1 < nframes { self.mem.read((f + 1) * FRAME_WORDS + FRAME_BASE) } else { height };
        if slot >= limit { return None; }
        Some((f, slot))
    }

    #[inline(always)]
    pub fn block_value(f: usize, slot: usize) -> usize {
        smi(((f << BLOCK_SLOT_BITS) | slot) as i64)
    }

    /// The word at object-stack position `i` (counted from the bottom).
    #[inline(always)]
    pub fn slot(&self, i: usize) -> usize {
        self.mem.read(self.len - 1 - i)
    }

    /// `block_target`: the block method in a block's slot.
    #[inline(always)]
    pub fn block_target(&self, p: &Program, slot: usize) -> Option<usize> {
        let v = self.slot(slot);
        if !is_smi(v) { return None; }
        let m = smi_value(v);
        if m < 0 || m as usize >= p.methods.len() { return None; }
        if p.method(m as usize).kind != KIND_BLOCK { return None; }
        Some(m as usize)
    }
}

pub enum Lookup {
    Found(usize),
    Missing,
    Stuck(usize),
}

pub enum Check {
    Yes,
    No,
    Stuck(usize),
}

pub enum FastAt {
    Fail,
    Done(usize),
}

#[derive(Clone, Copy)]
enum Num {
    Int(i64),
    Dbl(f64),
}

/// `Interpreter::compare_numbers` (src/interpreter_core.cc); the mixed
/// case is `spec_helpers::compare_mixed`.
fn compare_num(a: Num, b: Num) -> u8 {
    const SIMPLE_LESS: u8 = 29;
    const SIMPLE_EQUAL: u8 = 114;
    const SIMPLE_GREATER: u8 = 195;
    const RESULT_MINUS_1: u8 = 1;
    const RESULT_ZERO: u8 = 2;
    const RESULT_PLUS_1: u8 = 3;
    const FLAG_LESS_FOR_MIN: u8 = 4;
    const FLAG_LESS_EQUAL: u8 = 16;
    const FLAG_EQUAL: u8 = 32;
    const FLAG_GREATER_EQUAL: u8 = 64;
    let (lhs_is_int, lhs_int, lhs) = match a { Num::Int(i) => (true, i, i as f64), Num::Dbl(d) => (false, 0, d) };
    let (rhs_is_int, rhs_int, rhs) = match b { Num::Int(i) => (true, i, i as f64), Num::Dbl(d) => (false, 0, d) };
    if lhs_is_int && rhs_is_int {
        return if lhs_int < rhs_int { SIMPLE_LESS } else if lhs_int == rhs_int { SIMPLE_EQUAL } else { SIMPLE_GREATER };
    }
    if lhs < rhs { return SIMPLE_LESS; }
    if lhs > rhs { return SIMPLE_GREATER; }
    if lhs != rhs {
        if lhs.is_nan() {
            if rhs.is_nan() { return RESULT_ZERO | FLAG_LESS_FOR_MIN; }
            return RESULT_PLUS_1 | FLAG_LESS_FOR_MIN;
        }
        return RESULT_MINUS_1;
    }
    if lhs == 0.0 {
        if lhs.is_sign_negative() == rhs.is_sign_negative() {
            return SIMPLE_EQUAL;
        } else if lhs.is_sign_negative() {
            return RESULT_MINUS_1 | FLAG_LESS_EQUAL | FLAG_EQUAL | FLAG_GREATER_EQUAL | FLAG_LESS_FOR_MIN;
        } else {
            return RESULT_PLUS_1 | FLAG_LESS_EQUAL | FLAG_EQUAL | FLAG_GREATER_EQUAL;
        }
    }
    if !lhs_is_int && !rhs_is_int { return SIMPLE_EQUAL; }
    let the_int = if lhs_is_int { lhs_int } else { rhs_int };
    const SHORTCUT_LIMIT: i64 = 0x20000000000000;
    if -SHORTCUT_LIMIT <= the_int && the_int <= SHORTCUT_LIMIT { return SIMPLE_EQUAL; }
    let the_double = if lhs_is_int { rhs } else { lhs };
    if the_double <= -9223372036854778e3 {
        return if lhs_is_int { SIMPLE_GREATER } else { SIMPLE_LESS };
    }
    if the_double >= 9223372036854776e3 {
        return if lhs_is_int { SIMPLE_LESS } else { SIMPLE_GREATER };
    }
    let other_int = the_double as i64;
    let c = if the_int < other_int { SIMPLE_LESS } else if the_int == other_int { SIMPLE_EQUAL } else { SIMPLE_GREATER };
    if lhs_is_int { c } else {
        // Swap the direction.
        if c == SIMPLE_LESS { SIMPLE_GREATER } else if c == SIMPLE_GREATER { SIMPLE_LESS } else { c }
    }
}

/// Builds the machine for the current task and runs it: on the verified run
/// loop (`step::run_loop`) if the program was accepted by the launch
/// verification, else on the checked handlers (`run_checked`). TRUSTED glue:
/// the ghost state is the one the run loop's precondition names
/// (theorem.rs); `reload` checks the stack object.
pub fn run(p: Program, rt: Runtime, globals: Globals, heap: Heap, pre: Preemption,
           accepted: Option<crate::ffi::Accepted>) -> (usize, i64) {
    let mem = rt.stack();
    let bot = mem.slot(0);
    let mut m = Machine {
        mem, globals, heap,
        len: 0, top: 0, ftop: 0, rtop: 0, bci: 0, base: 0, lim: 0, method: 0,
        fw: 0, need: usize::MAX, bot, slow_k: crate::step::Slow::Op, slow_w: 0,
        g: Ghost::assume_new(),
    };
    let env = Env { p, rt, pre };
    if !m.reload(&env.p) || m.ftop < FRAME_WORDS {
        env.rt.report(V2_REPORT_STUCK, m.bci, stuck::FATAL);
        return (RESULT_TERMINATED, 1);
    }
    // Register allocation: the fields that change with every instruction
    // (top, bci) and the stack view stay in registers; the frame cache and
    // the other views, which change only on calls, returns and cold paths,
    // stay in memory (their addresses escape here, so LLVM does not
    // promote them). Promoting everything costs more in register shuffles
    // at the loop head than it saves in loads.
    core::hint::black_box((
        &mut m.len as *mut usize, &mut m.ftop as *mut usize, &mut m.rtop as *mut usize,
        &mut m.base as *mut usize,
        &mut m.lim as *mut usize, &mut m.method as *mut usize,
        &mut m.globals as *mut Globals, &mut m.heap as *mut Heap,
    ));
    match accepted {
        Some(token) => {
            let (state, value, _) = crate::step::run_loop(&mut m, &env, &token);
            (state, value)
        },
        #[cfg(feature = "checked-loop")]
        None => run_checked(&mut m, &env),
        // Without the checked loop (devices) a program the launch did not
        // verify never runs: the VM refuses it before (ProcessGroup::create,
        // V2MethodTable::checked_loop_linked); should one get here anyway,
        // it is terminated without executing an instruction.
        #[cfg(not(feature = "checked-loop"))]
        None => {
            env.rt.report(V2_REPORT_STUCK, m.bci, stuck::FATAL);
            (RESULT_TERMINATED, 1)
        }
    }
}

impl Machine {
    #[inline(always)]
    pub fn u16_at(p: &Program, i: usize) -> usize {
        p.code.at(i) as usize | (p.code.at(i + 1) as usize) << 8
    }

    #[inline(always)]
    pub fn u32_at(p: &Program, i: usize) -> usize {
        Self::u16_at(p, i) | Self::u16_at(p, i + 2) << 16
    }

    /// Executes an instruction of an opcode family whose refinement is not
    /// proven yet (`step::unverified_op`): every stuck state of the spec is
    /// a run-time check here. The instruction lies inside the method.
    #[inline(always)]
    pub fn dispatch_unverified(&mut self, env: &Env, bci: usize, opcode: u8) -> Ctl {
        let p = &env.p;
        // Operands are decoded in the arms (the opcode is a constant there,
        // so the length folds too).
        macro_rules! len { () => { OPCODE_LENGTHS[opcode as usize] as usize } }
        macro_rules! b1 { () => { p.code.at(bci + 1) as usize } }
        macro_rules! w1 { () => { Self::u16_at(p, bci + 1) } }
        match opcode {
            op::LOAD_OUTER => self.op_load_outer(b1!()),
            op::STORE_OUTER => self.op_store_outer(b1!()),
            op::LOAD_FIELD => self.op_load_field(env, b1!(), len!()),
            op::LOAD_FIELD_WIDE => self.op_load_field(env, w1!(), len!()),
            op::LOAD_FIELD_LOCAL => self.op_load_field_local(env, b1!(), false),
            op::POP_LOAD_FIELD_LOCAL => self.op_load_field_local(env, b1!(), true),
            op::STORE_FIELD => self.op_store_field(env, b1!(), len!(), true),
            op::STORE_FIELD_WIDE => self.op_store_field(env, w1!(), len!(), true),
            op::STORE_FIELD_POP => self.op_store_field(env, b1!(), len!(), false),
            op::LOAD_GLOBAL_VAR_LAZY => self.op_load_global_lazy(env, b1!(), len!()),
            op::LOAD_GLOBAL_VAR_LAZY_WIDE => self.op_load_global_lazy(env, w1!(), len!()),
            op::LOAD_GLOBAL_VAR_DYNAMIC => self.op_load_global_dynamic(env),
            op::STORE_GLOBAL_VAR_DYNAMIC => self.op_store_global_dynamic(env),
            op::LOAD_BLOCK => self.op_load_block(b1!()),
            op::LOAD_OUTER_BLOCK => self.op_load_outer_block(b1!()),
            op::ALLOCATE => self.op_allocate(env, b1!(), len!()),
            op::ALLOCATE_WIDE => self.op_allocate(env, w1!(), len!()),
            op::IS_CLASS => self.op_is(env, b1!(), false, len!()),
            op::IS_CLASS_WIDE => self.op_is(env, w1!(), false, len!()),
            op::IS_INTERFACE => self.op_is(env, b1!(), true, len!()),
            op::IS_INTERFACE_WIDE => self.op_is(env, w1!(), true, len!()),
            op::AS_CLASS => self.op_as(env, b1!(), false, len!()),
            op::AS_CLASS_WIDE => self.op_as(env, w1!(), false, len!()),
            op::AS_INTERFACE => self.op_as(env, b1!(), true, len!()),
            op::AS_INTERFACE_WIDE => self.op_as(env, w1!(), true, len!()),
            op::AS_LOCAL => self.op_as_local(env, b1!()),
            op::INVOKE_STATIC => {
                if let Some(c) = self.ensure_room(env) { return c; }
                let t = p.dispatch_target(w1!());
                self.call_static(env, t, 3)
            }
            op::INVOKE_STATIC_TAIL => {
                if let Some(c) = self.ensure_room(env) { return c; }
                self.op_invoke_static_tail(env, w1!())
            }
            op::INVOKE_BLOCK => {
                if let Some(c) = self.ensure_room(env) { return c; }
                self.op_invoke_block(env, b1!())
            }
            op::INVOKE_LAMBDA_TAIL => {
                if let Some(c) = self.ensure_room(env) { return c; }
                self.op_invoke_lambda_tail(env)
            }
            op::INVOKE_INITIALIZER_TAIL => {
                if let Some(c) = self.ensure_room(env) { return c; }
                self.op_invoke_initializer_tail(env)
            }
            op::INVOKE_VIRTUAL => {
                if let Some(c) = self.ensure_room(env) { return c; }
                self.invoke_virtual(env, Self::u16_at(p, bci + 2) as i64, b1!() + 1, len!())
            }
            op::INVOKE_VIRTUAL_WIDE => {
                if let Some(c) = self.ensure_room(env) { return c; }
                self.invoke_virtual(env, Self::u16_at(p, bci + 3) as i64, w1!() + 1, len!())
            }
            op::INVOKE_VIRTUAL_GET => self.op_invoke_virtual_get(env, w1!() as i64),
            op::INVOKE_VIRTUAL_SET => self.op_invoke_virtual_set(env, w1!() as i64),
            op::INVOKE_EQ..=op::INVOKE_AT_PUT => {
                if !self.has_slot(1) { return Ctl::Stuck(stuck::STACK_RANGE); }
                // Constant opcodes, so that the inlined fast paths fold.
                match opcode {
                    op::INVOKE_EQ => self.op_invoke_eq(env),
                    op::INVOKE_LT => self.op_invoke_relational(env, op::INVOKE_LT),
                    op::INVOKE_GT => self.op_invoke_relational(env, op::INVOKE_GT),
                    op::INVOKE_LTE => self.op_invoke_relational(env, op::INVOKE_LTE),
                    op::INVOKE_GTE => self.op_invoke_relational(env, op::INVOKE_GTE),
                    op::INVOKE_AT => self.op_invoke_at(env),
                    op::INVOKE_AT_PUT => self.op_invoke_at_put(env),
                    op::INVOKE_ADD => self.op_invoke_arith(env, op::INVOKE_ADD),
                    op::INVOKE_SUB => self.op_invoke_arith(env, op::INVOKE_SUB),
                    op::INVOKE_MUL => self.op_invoke_arith(env, op::INVOKE_MUL),
                    op::INVOKE_BIT_AND => self.op_invoke_arith(env, op::INVOKE_BIT_AND),
                    op::INVOKE_BIT_OR => self.op_invoke_arith(env, op::INVOKE_BIT_OR),
                    _ => self.op_invoke_arith(env, opcode),
                }
            }
            op::INVOKE_SIZE => self.op_invoke_size(env, w1!() as i64),
            op::PRIMITIVE => self.op_primitive(env),
            op::THROW => {
                if !self.has_slot(0) { return Ctl::Stuck(stuck::STACK_RANGE); }
                let v = self.at(0);
                self.unwind(env, Unwinding::Throw(v))
            }
            op::RETURN => {
                if !self.has_slot(0) { return Ctl::Stuck(stuck::STACK_RANGE); }
                let v = self.at(0);
                self.return_from(env, v)
            }
            op::RETURN_NULL => self.return_from(env, p.null),
            op::NON_LOCAL_RETURN => self.op_non_local_return(env),
            op::STORE_FIELD_THIS => self.op_store_field_this(env, b1!()),
            op::NON_LOCAL_BRANCH => self.op_non_local_branch(env, b1!(), Self::u32_at(p, bci + 2)),
            op::IDENTICAL => {
                if !self.has_slot(1) { return Ctl::Stuck(stuck::STACK_RANGE); }
                let r = self.identical(self.at(1), self.at(0));
                self.binary_result(p.boolean(r))
            }
            op::TRY => {
                if let Some(c) = self.ensure_room(env) { return c; }
                self.op_try(env)
            }
            op::LOAD_FIELD_THIS => self.op_load_field_this(p, b1!()),
            op::UNWIND => self.op_unwind(env),
            op::HALT => self.op_halt(env, b1!()),
            op::LOOP_REPEAT => self.c_loop_repeat(p, bci),
            op::LOOP_ARRAY => self.c_loop_array(p, bci),
            op::HASH_FIND => self.c_hash_find(p, bci),
            // Opcodes 104..255 (the length table covers only 0..103).
            _ => Ctl::Stuck(stuck::BAD_INSTRUCTION),
        }
    }

    // -----------------------------------------------------------------------
    // Opcodes not yet verified (see OBLIGATIONS.md).

    #[inline(always)]
    fn op_load_global_lazy(&mut self, env: &Env, g: usize, len: usize) -> Ctl {
        let p = &env.p;
        if g >= self.globals.len() { return Ctl::Stuck(stuck::TABLE_RANGE); }
        let v = self.globals.at(g);
        let lazy = is_heap(v) && self.tag(v) == INSTANCE_TAG
            && smi_value(self.heap.header(v)) >> CLASS_ID_OFFSET == (p.lazy_initializer_class_id as i64);
        if !lazy { return self.push_next_u(v, len); }
        if let Some(c) = self.ensure_room(env) { return c; }
        if !self.push(smi(g as i64)) || !self.push(v) { return Ctl::Stuck(stuck::LIMIT); }
        let t = p.entry_method(ENTRY_RUN_GLOBAL_INITIALIZER);
        self.call_static(env, t, len)
    }

    #[inline(always)]
    fn op_load_global_dynamic(&mut self, env: &Env) -> Ctl {
        if !self.has_slot(0) { return Ctl::Stuck(stuck::STACK_RANGE); }
        match self.global_index(self.at(0)) {
            None => self.raise(env, INVALID_PROGRAM),
            Some(g) => {
                let v = self.globals.at(g);
                self.put(0, v);
                self.bci += 1;
                Ctl::Next
            }
        }
    }

    #[inline(always)]
    fn op_store_global_dynamic(&mut self, env: &Env) -> Ctl {
        if !self.has_slot(1) { return Ctl::Stuck(stuck::STACK_RANGE); }
        match self.global_index(self.at(1)) {
            None => self.raise(env, INVALID_PROGRAM),
            Some(g) => {
                let v = self.at(0);
                self.drop(2);
                self.globals.set(g, v);
                self.bci += 1;
                Ctl::Next
            }
        }
    }

    #[inline(always)]
    fn global_index(&self, v: usize) -> Option<usize> {
        if !is_smi(v) { return None; }
        let g = smi_value(v);
        if g < 0 || g as usize >= self.globals.len() { None } else { Some(g as usize) }
    }

    #[inline(always)]
    fn op_allocate(&mut self, env: &Env, c: usize, len: usize) -> Ctl {
        let p = &env.p;
        if c >= p.class_bits.len() { return Ctl::Stuck(stuck::TABLE_RANGE); }
        let bits = p.class_bits.at(c);
        if (bits as usize) & CLASS_TAG_MASK != INSTANCE_TAG || p.instance_field_count(c) < 0 {
            return Ctl::Stuck(stuck::NOT_INSTANTIABLE);
        }
        match self.alloc_instance(env, c) {
            None => {
                let oom = p.roots.at(ROOT_OUT_OF_MEMORY_ERROR);
                self.unwind(env, Unwinding::Throw(oom))
            }
            Some(o) => self.push_next_u(o, len),
        }
    }

    #[inline(always)]
    fn op_is(&mut self, env: &Env, enc: usize, interface: bool, len: usize) -> Ctl {
        let p = &env.p;
        if !self.has_slot(0) { return Ctl::Stuck(stuck::STACK_RANGE); }
        match self.typecheck(p, self.at(0), enc / 2, enc % 2 == 1, interface) {
            Check::Stuck(r) => Ctl::Stuck(r),
            Check::Yes => { self.put(0, p.true_); self.bci += len; Ctl::Next }
            Check::No => { self.put(0, p.false_); self.bci += len; Ctl::Next }
        }
    }

    #[inline(always)]
    fn op_as(&mut self, env: &Env, enc: usize, interface: bool, len: usize) -> Ctl {
        let p = &env.p;
        if !self.has_slot(0) { return Ctl::Stuck(stuck::STACK_RANGE); }
        let v = self.at(0);
        match self.typecheck(p, v, enc / 2, enc % 2 == 1, interface) {
            Check::Stuck(r) => Ctl::Stuck(r),
            Check::Yes => { self.bci += len; Ctl::Next }
            Check::No => self.raise_as(env, v, len),
        }
    }

    #[inline(always)]
    fn op_as_local(&mut self, env: &Env, enc: usize) -> Ctl {
        let p = &env.p;
        if !self.has_slot(enc / 32) { return Ctl::Stuck(stuck::STACK_RANGE); }
        let v = self.at(enc / 32);
        match self.typecheck_class(p, v, enc % 32, false) {
            Check::Stuck(r) => Ctl::Stuck(r),
            Check::Yes => { self.bci += 2; Ctl::Next }
            Check::No => self.raise_as(env, v, 2),
        }
    }

    #[inline(always)]
    fn op_invoke_static_tail(&mut self, env: &Env, d: usize) -> Ctl {
        let p = &env.p;
        let t = p.dispatch_target(d);
        if t < 0 || t as usize >= p.methods.len() { return Ctl::Stuck(stuck::NOT_METHOD); }
        let info = p.method(t as usize);
        let arity = info.arity as usize;
        if arity > self.lim - self.top { return Ctl::Stuck(stuck::STACK_RANGE); }
        if info.recv_start != NO_VALUE {
            if arity == 0 { return Ctl::Stuck(stuck::NOT_OBJECT); }
            let receiver = self.at(arity - 1);
            match self.class_id(p, receiver) {
                None => return Ctl::Stuck(stuck::NOT_OBJECT),
                Some(cid) => {
                    if !((info.recv_start as i64) <= cid && cid < info.recv_end as i64) {
                        return self.raise(env, AS_CHECK_FAILED);
                    }
                }
            }
        }
        let from = self.top;
        self.replace_frame(env, t as usize, from, arity, 0)
    }

    #[inline(always)]
    fn op_invoke_block(&mut self, env: &Env, n: usize) -> Ctl {
        let p = &env.p;
        if n < 1 || !self.has_slot(n - 1) { return Ctl::Stuck(stuck::STACK_RANGE); }
        let (_, slot) = match self.block_ref(self.at(n - 1)) {
            None => return Ctl::Stuck(stuck::NOT_BLOCK),
            Some(r) => r,
        };
        match self.block_target(p, slot) {
            None => self.raise(env, INVALID_PROGRAM),
            Some(t) => {
                let arity = p.method(t).arity as usize;
                if n < arity { return self.raise_code(env, true, arity, n, t); }
                self.drop(n - arity);
                let ret = self.bci + 2;
                self.call(env, t, ret)
            }
        }
    }

    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    fn op_invoke_lambda_tail(&mut self, env: &Env) -> Ctl {
        cold!(self, |m| m.op_invoke_lambda_tail_cold(env))
    }

    #[inline(never)]
    fn op_invoke_lambda_tail_cold(&mut self, env: &Env) -> Ctl {
        let p = &env.p;
        if self.ftop < FRAME_WORDS { return Ctl::Stuck(stuck::BAD_FRAME); }
        let a = p.method(self.method).arity as usize;
        if a < 1 || self.lim - self.top != a { return Ctl::Stuck(stuck::STACK_RANGE); }
        let recv = self.slot(self.base);
        match self.instance_fields(p, recv) {
            Some(f) if f >= 2 => {}
            _ => return self.raise(env, INVALID_PROGRAM),
        }
        let mid = self.field(recv, 0);
        if !is_smi(mid) { return self.raise(env, INVALID_PROGRAM); }
        let m = smi_value(mid);
        if m < 0 || m as usize >= p.methods.len() { return self.raise(env, INVALID_PROGRAM); }
        let m = m as usize;
        let info = p.method(m);
        if info.kind != KIND_LAMBDA { return self.raise(env, INVALID_PROGRAM); }
        let c = info.aux as usize;
        let argument = self.field(recv, 1);
        // `captured`: an array of exactly c elements, or one non-array value.
        let captured_array = self.array_length(argument);
        match captured_array {
            Some(length) => if length != c { return self.raise(env, INVALID_PROGRAM); },
            None => if c != 1 { return self.raise(env, INVALID_PROGRAM); },
        }
        let arity = info.arity as usize;
        if arity < c { return self.raise(env, INVALID_PROGRAM); }
        let user = arity - c;
        if a - 1 < user { return self.raise_code(env, false, user, a - 1, m); }
        // The user arguments are the parameters 1..1+user, at array indices
        // lim-1-user .. lim-1 (parameter i is at array index lim-1-i).
        let from = self.lim - 1 - user;
        let ctl = self.replace_frame(env, m, from, user, c);
        if let Ctl::Stuck(_) = ctl { return ctl; }
        // The captures follow the user arguments: capture j is at
        // object-stack position base + user + j.
        let mut j = 0;
        while j < c {
            let v = match captured_array {
                Some(_) => self.heap.word(argument, ARRAY_ELEMENTS_WORD + j),
                None => argument,
            };
            let index = self.lim - 1 - (user + j);
            self.mem.write(index, v);
            j += 1;
        }
        ctl
    }

    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    fn op_invoke_initializer_tail(&mut self, env: &Env) -> Ctl {
        cold!(self, |m| m.op_invoke_initializer_tail_cold(env))
    }

    #[inline(never)]
    fn op_invoke_initializer_tail_cold(&mut self, env: &Env) -> Ctl {
        let p = &env.p;
        if !self.has_slot(0) { return Ctl::Stuck(stuck::STACK_RANGE); }
        let v = self.at(0);
        if !is_smi(v) { return self.raise(env, INVALID_PROGRAM); }
        let m = smi_value(v);
        if m < 0 || m as usize >= p.methods.len() { return self.raise(env, INVALID_PROGRAM); }
        let info = p.method(m as usize);
        if info.kind != KIND_METHOD || info.arity != 0 { return self.raise(env, INVALID_PROGRAM); }
        let from = self.top;
        self.replace_frame(env, m as usize, from, 0, 0)
    }

    #[inline(always)]
    fn op_invoke_virtual_get(&mut self, env: &Env, sel: i64) -> Ctl {
        let p = &env.p;
        if !self.has_slot(0) { return Ctl::Stuck(stuck::STACK_RANGE); }
        let recv = self.at(0);
        match self.find_method(p, recv, sel) {
            Lookup::Stuck(r) => Ctl::Stuck(r),
            Lookup::Missing => self.raise_lookup(env, recv, sel),
            Lookup::Found(t) => {
                let info = p.method(t);
                if info.arity != 1 { return Ctl::Stuck(stuck::BAD_ARITY); }
                let f = info.aux as usize;
                if info.kind == KIND_FIELD_ACCESSOR && self.field_ok(p, recv, f) {
                    let v = self.field(recv, f);
                    self.put(0, v);
                    self.bci += 3;
                    return Ctl::Next;
                }
                if let Some(c) = self.ensure_room(env) { return c; }
                let ret = self.bci + 3;
                self.call(env, t, ret)
            }
        }
    }

    #[inline(always)]
    fn op_invoke_virtual_set(&mut self, env: &Env, sel: i64) -> Ctl {
        let p = &env.p;
        if !self.has_slot(1) { return Ctl::Stuck(stuck::STACK_RANGE); }
        let recv = self.at(1);
        let v = self.at(0);
        match self.find_method(p, recv, sel) {
            Lookup::Stuck(r) => Ctl::Stuck(r),
            Lookup::Missing => self.raise_lookup(env, recv, sel),
            Lookup::Found(t) => {
                let info = p.method(t);
                if info.arity != 2 { return Ctl::Stuck(stuck::BAD_ARITY); }
                let f = info.aux as usize;
                if info.kind == KIND_FIELD_ACCESSOR && self.field_store_ok(p, recv, f) && !self.is_ro(p, recv) {
                    self.heap.set_word(recv, INSTANCE_FIELDS_WORD + f, v);
                    self.drop(1);
                    self.put(0, v);
                    self.bci += 3;
                    return Ctl::Next;
                }
                if let Some(c) = self.ensure_room(env) { return c; }
                let ret = self.bci + 3;
                self.call(env, t, ret)
            }
        }
    }

    #[inline(always)]
    fn op_invoke_eq(&mut self, env: &Env) -> Ctl {
        let p = &env.p;
        let a0 = self.at(1);
        let a1 = self.at(0);
        if is_smi(a0) && is_smi(a1) { return self.binary_result(p.boolean(a0 == a1)); }
        self.op_invoke_eq_slow(env, a0, a1)
    }

    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    fn op_invoke_eq_slow(&mut self, env: &Env, a0: usize, a1: usize) -> Ctl {
        cold!(self, |m| m.op_invoke_eq_slow_cold(env, a0, a1))
    }

    #[inline(never)]
    fn op_invoke_eq_slow_cold(&mut self, env: &Env, a0: usize, a1: usize) -> Ctl {
        let p = &env.p;
        if a0 == a1 {
            let nan = self.is_double(a0) && f64::from_bits(self.double_bits(a0)).is_nan();
            return self.binary_result(p.boolean(!nan));
        }
        if a0 == p.null || a1 == p.null { return self.binary_result(p.false_); }
        if is_smi(a0) && is_smi(a1) { return self.binary_result(p.false_); }
        let c = self.compare_numbers(a0, a1);
        if c != 0 { return self.binary_result(p.boolean(c & 32 != 0)); }
        if let Some(c) = self.ensure_room(env) { return c; }
        self.operator_fallback(env, op::INVOKE_EQ)
    }

    #[inline(always)]
    fn op_invoke_relational(&mut self, env: &Env, opcode: u8) -> Ctl {
        let p = &env.p;
        let a0 = self.at(1);
        let a1 = self.at(0);
        if is_smi(a0) && is_smi(a1) {
            let (x, y) = (a0 as isize, a1 as isize);  // Same order as the values.
            let r = match opcode {
                op::INVOKE_LT => x < y,
                op::INVOKE_LTE => x <= y,
                op::INVOKE_GT => x > y,
                _ => x >= y,
            };
            return self.binary_result(p.boolean(r));
        }
        self.op_invoke_relational_slow(env, opcode, a0, a1)
    }

    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    fn op_invoke_relational_slow(&mut self, env: &Env, opcode: u8, a0: usize, a1: usize) -> Ctl {
        cold!(self, |m| m.op_invoke_relational_slow_cold(env, opcode, a0, a1))
    }

    #[inline(never)]
    fn op_invoke_relational_slow_cold(&mut self, env: &Env, opcode: u8, a0: usize, a1: usize) -> Ctl {
        let p = &env.p;
        let c = self.compare_numbers(a0, a1);
        if c != 0 {
            let flag = match opcode {
                op::INVOKE_LT => 8,
                op::INVOKE_LTE => 16,
                op::INVOKE_GT => 128,
                _ => 64,
            };
            return self.binary_result(p.boolean(c & flag != 0));
        }
        if let Some(c) = self.ensure_room(env) { return c; }
        self.operator_fallback(env, opcode)
    }

    #[inline(always)]
    fn op_invoke_arith(&mut self, env: &Env, opcode: u8) -> Ctl {
        let a0 = self.at(1);
        let a1 = self.at(0);
        if is_smi(a0) && is_smi(a1) {
            if let Some(r) = smi_arith(opcode, smi_value(a0), smi_value(a1)) {
                return self.binary_result(smi(r));
            }
        }
        self.op_invoke_arith_slow(env, opcode, a0, a1)
    }

    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    fn op_invoke_arith_slow(&mut self, env: &Env, opcode: u8, a0: usize, a1: usize) -> Ctl {
        cold!(self, |m| m.op_invoke_arith_slow_cold(env, opcode, a0, a1))
    }

    #[inline(never)]
    fn op_invoke_arith_slow_cold(&mut self, env: &Env, opcode: u8, a0: usize, a1: usize) -> Ctl {
        if is_smi(a0) && is_smi(a1) {
        } else if (opcode == op::INVOKE_ADD || opcode == op::INVOKE_SUB || opcode == op::INVOKE_MUL)
            && self.is_double(a0) && self.is_double(a1) {
            let x = f64::from_bits(self.double_bits(a0));
            let y = f64::from_bits(self.double_bits(a1));
            let r = match opcode {
                op::INVOKE_ADD => x + y,
                op::INVOKE_SUB => x - y,
                _ => x * y,
            };
            match self.alloc_double(env, r.to_bits()) {
                // Out of memory: the virtual call allocates through the
                // primitive, which reports the failure.
                None => {}
                Some(d) => return self.binary_result(d),
            }
        }
        if let Some(c) = self.ensure_room(env) { return c; }
        self.operator_fallback(env, opcode)
    }

    #[inline(always)]
    fn op_invoke_at(&mut self, env: &Env) -> Ctl {
        let p = &env.p;
        let recv = self.at(1);
        let arg = self.at(0);
        let null = p.null;
        match self.fast_at(p, recv, arg, false, null, 8) {
            FastAt::Done(v) => self.binary_result(v),
            FastAt::Fail => {
                if let Some(c) = self.ensure_room(env) { return c; }
                self.operator_fallback(env, op::INVOKE_AT)
            }
        }
    }

    #[inline(always)]
    fn op_invoke_at_put(&mut self, env: &Env) -> Ctl {
        let p = &env.p;
        if !self.has_slot(2) { return Ctl::Stuck(stuck::STACK_RANGE); }
        let recv = self.at(2);
        let arg = self.at(1);
        let value = self.at(0);
        match self.fast_at(p, recv, arg, true, value, 8) {
            FastAt::Done(v) => {
                self.drop(2);
                self.put(0, v);
                self.bci += 1;
                Ctl::Next
            }
            FastAt::Fail => {
                if let Some(c) = self.ensure_room(env) { return c; }
                self.operator_fallback(env, op::INVOKE_AT_PUT)
            }
        }
    }

    #[inline(always)]
    fn op_invoke_size(&mut self, env: &Env, sel: i64) -> Ctl {
        let p = &env.p;
        if !self.has_slot(0) { return Ctl::Stuck(stuck::STACK_RANGE); }
        match self.fast_size(p, self.at(0)) {
            Some(n) if smi_ok(n) => {
                self.put(0, smi(n));
                self.bci += 3;
                Ctl::Next
            }
            _ => self.op_invoke_virtual_get(env, sel),
        }
    }

    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    fn op_primitive(&mut self, env: &Env) -> Ctl {
        cold!(self, |m| m.op_primitive_cold(env))
    }

    #[inline(never)]
    fn op_primitive_cold(&mut self, env: &Env) -> Ctl {
        let p = &env.p;
        let bci = self.bci;
        let arity = p.method(self.method).arity as usize;
        if self.lim - self.top != arity { return Ctl::Stuck(stuck::STACK_RANGE); }
        let module = p.code.at(bci + 1) as usize;
        let index = Self::u16_at(p, bci + 2);
        self.save();
        let (status, result, _) = env.rt.call_primitive(&mut self.mem, module, index, arity, self.base);
        if status == V2_PRIMITIVE_ABSENT {
            return self.raise_msg(env, PRIMITIVE_LOOKUP_FAILED, Msg::primitive(module, index));
        }
        if !self.reload(p) { return Ctl::Stuck(stuck::FATAL); }
        if status == V2_PRIMITIVE_SUCCESS {
            self.return_from(env, result)
        } else if status == V2_PRIMITIVE_FAILURE {
            if !self.push(result) { return Ctl::Stuck(stuck::LIMIT); }
            self.bci += 4;
            Ctl::Next
        } else {
            self.raise_value(env, result)
        }
    }

    #[inline(always)]
    fn op_try(&mut self, env: &Env) -> Ctl {
        let p = &env.p;
        if !self.has_slot(0) || self.ftop < FRAME_WORDS { return Ctl::Stuck(stuck::STACK_RANGE); }
        let height = self.len - self.top;
        let r = self.ftop - FRAME_WORDS;
        if self.mem.read(r + FRAME_HANDLER) != 0 {
            return Ctl::Stuck(stuck::LIMIT);
        }
        let fi = self.ftop / FRAME_WORDS - 1;
        // Stale finally records of the frame (left by a `break` out of
        // finally code) go first.
        self.cut_fins(fi, height - 1);
        self.mem.write(r + FRAME_HANDLER, height);
        self.mem.write(r + FRAME_HANDLER_BCI, self.bci + 1);
        let slot = height - 1;
        match self.block_target(p, slot) {
            None => self.raise(env, INVALID_PROGRAM),
            Some(t) => {
                let arity = p.method(t).arity as usize;
                if arity != 1 { return self.raise_code(env, true, arity, 1, t); }
                if !self.push(Self::block_value(fi, slot)) { return Ctl::Stuck(stuck::LIMIT); }
                let ret = self.bci + 1;
                self.call(env, t, ret)
            }
        }
    }

    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    fn op_unwind(&mut self, env: &Env) -> Ctl {
        cold!(self, |m| m.op_unwind_cold(env))
    }

    #[inline(never)]
    fn op_unwind_cold(&mut self, env: &Env) -> Ctl {
        let p = &env.p;
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
        let target_height = self.mem.read(e + FIN_TARGET_HEIGHT);
        let f = resume >> 2;
        let u = match resume & 3 {
            UNWIND_THROW => Unwinding::Throw(value),
            UNWIND_RETURN => Unwinding::Return(f, value),
            UNWIND_BRANCH => Unwinding::Branch(f, target, target_height),
            _ => return Ctl::Stuck(stuck::FATAL),
        };
        self.drop(3);
        // Records k and above go.
        self.rtop = e;
        self.unwind(env, u)
    }

    /// Cold path: runs out of line on a copy of the machine (see `cold!`).
    #[inline(always)]
    fn op_halt(&mut self, env: &Env, code: usize) -> Ctl {
        cold!(self, |m| m.op_halt_cold(env, code))
    }

    #[inline(never)]
    fn op_halt_cold(&mut self, env: &Env, code: usize) -> Ctl {
        let p = &env.p;
        if code == 0 {
            if !self.push(smi(91)) { return Ctl::Stuck(stuck::LIMIT); }
            self.bci += 2;
            Ctl::Exit(RESULT_YIELDED as u32, 0)
        } else if code == 1 {
            if !self.has_slot(0) { return Ctl::Stuck(stuck::STACK_RANGE); }
            let v = self.at(0);
            if !is_smi(v) { return self.raise(env, INVALID_PROGRAM); }
            self.drop(1);
            self.bci += 2;
            Ctl::Exit(RESULT_TERMINATED as u32, smi_value(v))
        } else if code == 2 {
            if !self.has_slot(0) { return Ctl::Stuck(stuck::STACK_RANGE); }
            let v = self.at(0);
            let duration = if is_smi(v) {
                smi_value(v)
            } else if self.is_large_int(v) {
                self.heap.word64(v, LARGE_INTEGER_VALUE_WORD) as i64
            } else {
                0
            };
            self.drop(1);
            self.bci += 2;
            let _ = p;
            Ctl::Exit(RESULT_DEEP_SLEEP as u32, duration)
        } else {
            self.bci += 2;
            Ctl::Exit(RESULT_RESET as u32, 0)
        }
    }

    #[inline(always)]
    fn op_non_local_return(&mut self, env: &Env) -> Ctl {
        if !self.has_slot(1) { return Ctl::Stuck(stuck::STACK_RANGE); }
        let (f, _) = match self.block_ref(self.at(0)) {
            None => return Ctl::Stuck(stuck::NOT_BLOCK),
            Some(r) => r,
        };
        if f >= self.ftop / FRAME_WORDS - 1 { return Ctl::Stuck(stuck::BAD_FRAME); }
        let v = self.at(1);
        self.unwind(env, Unwinding::Return(f, v))
    }

    #[inline(always)]
    fn op_non_local_branch(&mut self, env: &Env, hd: usize, off: usize) -> Ctl {
        let p = &env.p;
        if !self.has_slot(0) { return Ctl::Stuck(stuck::STACK_RANGE); }
        let (f, slot) = match self.block_ref(self.at(0)) {
            None => return Ctl::Stuck(stuck::NOT_BLOCK),
            Some(r) => r,
        };
        if f >= self.ftop / FRAME_WORDS - 1 { return Ctl::Stuck(stuck::BAD_FRAME); }
        let fbase = self.mem.read(f * FRAME_WORDS + FRAME_BASE);
        if slot + 1 < hd || slot + 1 - hd < fbase { return Ctl::Stuck(stuck::STACK_RANGE); }
        let m = self.mem.read(f * FRAME_WORDS + FRAME_METHOD);
        if m >= p.methods.len() { return Ctl::Stuck(stuck::BAD_BRANCH); }
        let info = p.method(m);
        let target = info.entry as usize + off;
        if !(target < info.end()) { return Ctl::Stuck(stuck::BAD_BRANCH); }
        self.unwind(env, Unwinding::Branch(f, target, slot + 1 - hd))
    }
}

/// `spec_step::smi_arith` on the target's words.
#[inline(always)]
pub fn smi_arith(opcode: u8, a: i64, b: i64) -> Option<i64> {
    let r: i64 = match opcode {
        op::INVOKE_BIT_OR => a | b,
        op::INVOKE_BIT_XOR => a ^ b,
        op::INVOKE_BIT_AND => a & b,
        op::INVOKE_ADD => a + b,
        op::INVOKE_SUB => a - b,
        op::INVOKE_MUL => {
            match a.checked_mul(b) {
                None => return None,
                Some(r) => r,
            }
        }
        op::INVOKE_DIV => {
            if b == 0 { return None; }
            a / b
        }
        op::INVOKE_MOD => {
            if b == 0 { return None; }
            a % b
        }
        op::INVOKE_BIT_SHL => {
            if b < 0 || b >= WORD_BITS as i64 { return None; }
            let r = (a as i128) << b;
            if r < MIN_SMI as i128 || r > MAX_SMI as i128 { return None; }
            r as i64
        }
        op::INVOKE_BIT_SHR => {
            if b < 0 || b >= WORD_BITS as i64 { return None; }
            a >> b
        }
        _ => {
            if b < 0 || b >= WORD_BITS as i64 || a < 0 { return None; }
            a >> b
        }
    };
    if smi_ok(r) { Some(r) } else { None }
}

impl Machine {
    // --- Blocks ---------------------------------------------------------------

    #[inline(always)]
    pub fn op_load_block(&mut self, k: usize) -> Ctl {
        if !self.has_slot(k) || self.ftop < FRAME_WORDS {
            return Ctl::Stuck(1);
        }
        let height = self.len - self.top;
        let slot = height - 1 - k;
        let f = self.ftop / FRAME_WORDS - 1;
        if f >= 0x4000 {
            return Ctl::Stuck(100);
        }
        let v = Machine::block_value(f, slot);
        self.push_next_u(v, 2)
    }

    // --- Fields -------------------------------------------------------------

    #[inline(always)]
    pub fn op_load_field_this(&mut self, p: &Program, f: usize) -> Ctl {
        // The receiver range of the method guarantees the field (checked by
        // the loader); the run-time check below makes the access safe for
        // every program.
        if self.base >= self.len - self.top || self.method >= p.methods.len() {
            return Ctl::Stuck(8);
        }
        let this = self.mem.read(self.len - 1 - self.base);
        if !self.field_ok(p, this, f) {
            return Ctl::Stuck(8);
        }
        let v = self.field(this, f);
        self.push_next_u(v, 2)
    }

    #[inline(always)]
    pub fn op_load_outer(&mut self, k: usize) -> Ctl {
        if !self.has_slot(0) { return Ctl::Stuck(1); }
        let (f, slot) = match self.block_ref(self.at(0)) {
            None => return Ctl::Stuck(9),
            Some(r) => r,
        };
        let fbase = self.mem.read(f * FRAME_WORDS + FRAME_BASE);
        if slot < k || slot - k < fbase { return Ctl::Stuck(1); }
        let v = self.slot(slot - k);
        self.put(0, v);
        self.bci += 2;
        Ctl::Next
    }

    #[inline(always)]
    pub fn op_store_outer(&mut self, k: usize) -> Ctl {
        if !self.has_slot(1) { return Ctl::Stuck(1); }
        let v = self.at(0);
        let (f, slot) = match self.block_ref(self.at(1)) {
            None => return Ctl::Stuck(9),
            Some(r) => r,
        };
        let fbase = self.mem.read(f * FRAME_WORDS + FRAME_BASE);
        if slot < k || slot - k < fbase { return Ctl::Stuck(1); }
        let i = slot - k;
        self.drop(2);
        if i >= self.len - self.top { return Ctl::Stuck(1); }
        let index = self.len - 1 - i;
        self.mem.write(index, v);
        if !self.push(v) { return Ctl::Stuck(100); }
        self.bci += 2;
        Ctl::Next
    }

    #[inline(always)]
    pub fn op_load_outer_block(&mut self, k: usize) -> Ctl {
        if !self.has_slot(0) { return Ctl::Stuck(1); }
        let (f, slot) = match self.block_ref(self.at(0)) {
            None => return Ctl::Stuck(9),
            Some(r) => r,
        };
        let fbase = self.mem.read(f * FRAME_WORDS + FRAME_BASE);
        if slot < k || slot - k < fbase { return Ctl::Stuck(1); }
        self.put(0, Machine::block_value(f, slot - k));
        self.bci += 2;
        Ctl::Next
    }

    #[inline(always)]
    pub fn op_load_field(&mut self, env: &Env, f: usize, len: usize) -> Ctl {
        if !self.has_slot(0) { return Ctl::Stuck(1); }
        let obj = self.at(0);
        if !self.field_ok(&env.p, obj, f) {
            return self.raise(env, INVALID_PROGRAM);
        }
        let v = self.field(obj, f);
        self.put(0, v);
        self.bci += len;
        Ctl::Next
    }

    #[inline(always)]
    pub fn op_load_field_local(&mut self, env: &Env, enc: usize, pop: bool) -> Ctl {
        let local = enc % 16;
        let f = enc / 16;
        let slot = if pop { local + 1 } else { local };
        if !self.has_slot(slot) { return Ctl::Stuck(1); }
        let obj = self.at(slot);
        if !self.field_ok(&env.p, obj, f) {
            return self.raise(env, INVALID_PROGRAM);
        }
        let v = self.field(obj, f);
        if pop {
            self.put(0, v);
            self.bci += 2;
            Ctl::Next
        } else {
            self.push_next_u(v, 2)
        }
    }

    #[inline(always)]
    pub fn op_store_field(&mut self, env: &Env, f: usize, len: usize, keep: bool) -> Ctl {
        if !self.has_slot(1) { return Ctl::Stuck(1); }
        let v = self.at(0);
        let obj = self.at(1);
        if !self.field_store_ok(&env.p, obj, f) || self.is_ro(&env.p, obj) {
            return self.raise(env, INVALID_PROGRAM);
        }
        self.drop(2);
        self.heap.set_word(obj, INSTANCE_FIELDS_WORD + f, v);
        if keep {
            self.push_next_u(v, len)
        } else {
            self.bci += len;
            Ctl::Next
        }
    }

    #[inline(always)]
    pub fn op_store_field_this(&mut self, env: &Env, f: usize) -> Ctl {
        let p = &env.p;
        if !self.has_slot(0) { return Ctl::Stuck(1); }
        if self.base >= self.len - self.top { return Ctl::Stuck(8); }
        let this = self.mem.read(self.len - 1 - self.base);
        if !self.field_store_ok(p, this, f) { return Ctl::Stuck(8); }
        if self.is_ro(p, this) {
            return self.raise(env, INVALID_PROGRAM);
        }
        let v = self.at(0);
        self.heap.set_word(this, INSTANCE_FIELDS_WORD + f, v);
        self.bci += 2;
        Ctl::Next
    }
}

impl Program {
    /// `instance_field_count`: the instance size in words minus the header.
    #[inline(always)]
    pub fn instance_field_count(&self, cid: usize) -> i64 {
        (((self.class_bits.at(cid) >> CLASS_ID_OFFSET) & INSTANCE_SIZE_MASK) as i64) - 1
    }

    /// `dispatch_target`.
    #[inline(always)]
    pub fn dispatch_target(&self, d: usize) -> i64 {
        if d < self.dispatch.len() { self.dispatch.at(d) as i64 } else { -1 }
    }

    /// `entry_method`.
    #[inline(always)]
    pub fn entry_method(&self, k: usize) -> i64 {
        let d = self.entry_points.at(k);
        if d < 0 { return -1; }
        self.dispatch_target(d as usize)
    }

    #[inline(always)]
    pub fn boolean(&self, b: bool) -> usize {
        if b { self.true_ } else { self.false_ }
    }
}

// ---------------------------------------------------------------------------
// The checked interpreter: programs that were not accepted by the launch
// verification (trusted format-2 programs run without -Xverify) run on the
// checked handlers only. Every stuck state of the spec is a run-time check,
// so any program is memory safe (TRUSTED.md section 4); nothing here is
// proven. Accepted programs run on `step::run_loop`.

/// The run loop for programs that were not accepted.
fn run_checked(m: &mut Machine, env: &Env) -> (usize, i64) {
    let tracing = env.rt.tracing();
    loop {
        let bci = m.bci;
        let ctl = if !m.instruction_in_method(&env.p, bci) {
            Ctl::Stuck(stuck::BAD_INSTRUCTION)
        } else {
            let raw = env.p.code.at(bci);
            if tracing { env.rt.report(V2_REPORT_TRACE, bci, raw as usize); }
            // An unchecked twin (format note 20) runs as its checked base here.
            let opcode = toit_spec::v2::bytecodes::exec_base_op(raw);
            m.dispatch_checked(env, bci, opcode)
        };
        match ctl {
            Ctl::Next => {}
            Ctl::Exit(state, value) => {
                m.save();
                return (state as usize, value);
            }
            Ctl::Stuck(reason) => {
                env.rt.report(V2_REPORT_STUCK, m.bci, reason);
                m.save();
                return (RESULT_TERMINATED, 1);
            }
            // Only register handlers (not the checked ones) hand a slow path
            // to the loop.
            Ctl::Slow => {
                env.rt.report(V2_REPORT_STUCK, m.bci, stuck::FATAL);
                m.save();
                return (RESULT_TERMINATED, 1);
            }
        }
    }
}

impl Machine {
    /// The instruction at `bci` is a valid opcode and ends inside the top
    /// frame's method.
    #[inline(always)]
    fn instruction_in_method(&self, p: &Program, bci: usize) -> bool {
        if self.method >= p.methods.len() { return false; }
        let end = p.method(self.method).end();
        if bci >= end || end > p.code.len() { return false; }
        let opcode = p.code.at(bci);
        if opcode as usize >= OPCODE_LENGTHS.len() { return false; }
        bci + OPCODE_LENGTHS[opcode as usize] as usize <= end
    }

    /// Executes the instruction at `bci` (inside the method) with every run-time
    /// check: the simple families here, the others in `dispatch_unverified`.
    #[inline(always)]
    pub fn dispatch_checked(&mut self, env: &Env, bci: usize, opcode: u8) -> Ctl {
        let p = &env.p;
        macro_rules! len { () => { OPCODE_LENGTHS[opcode as usize] as usize } }
        macro_rules! b1 { () => { p.code.at(bci + 1) as usize } }
        macro_rules! w1 { () => { Self::u16_at(p, bci + 1) } }
        match opcode {
            op::LOAD_LOCAL => self.c_load_local(b1!(), len!()),
            op::LOAD_LOCAL_WIDE => self.c_load_local(w1!(), len!()),
            14..=19 => self.c_load_local((opcode - op::LOAD_LOCAL_0) as usize, 1),
            op::POP_LOAD_LOCAL => {
                let n = b1!();
                if !self.has_slot(n + 1) { return Ctl::Stuck(stuck::STACK_RANGE); }
                let v = self.at(n + 1);
                self.put(0, v);
                self.bci += 2;
                Ctl::Next
            }
            op::STORE_LOCAL => {
                let n = b1!();
                if !self.has_slot(n) { return Ctl::Stuck(stuck::STACK_RANGE); }
                let v = self.at(0);
                self.put(n, v);
                self.bci += 2;
                Ctl::Next
            }
            op::STORE_LOCAL_POP => {
                let n = b1!();
                if n < 1 || !self.has_slot(n) { return Ctl::Stuck(stuck::STACK_RANGE); }
                let v = self.at(0);
                self.drop(1);
                self.put(n - 1, v);
                self.bci += 2;
                Ctl::Next
            }
            op::LOAD_LITERAL | op::LOAD_LITERAL_WIDE => {
                let i = if opcode == op::LOAD_LITERAL { b1!() } else { w1!() };
                if i >= p.literals.len() { return Ctl::Stuck(stuck::TABLE_RANGE); }
                let v = p.literals.at(i);
                self.push_next_u(v, len!())
            }
            op::LOAD_NULL => self.push_next_u(p.null, len!()),
            op::LOAD_SMI_0 => self.push_next_u(smi(0), len!()),
            op::LOAD_SMI_1 => self.push_next_u(smi(1), len!()),
            op::LOAD_SMI_U8 => self.push_next_u(smi(b1!() as i64), len!()),
            op::LOAD_SMI_U16 => self.push_next_u(smi(w1!() as i64), len!()),
            op::LOAD_SMI_U32 => {
                let v = Self::u32_at(p, bci + 1) as i64;
                if !smi_ok(v) { return Ctl::Stuck(stuck::SMI_RANGE); }
                self.push_next_u(smi(v), len!())
            }
            op::LOAD_SMIS_0 => {
                let n = b1!();
                if self.top - self.rtop < n { return Ctl::Stuck(stuck::LIMIT); }
                let mut i = 0;
                while i < n {
                    self.push(0);
                    i += 1;
                }
                self.bci += 2;
                Ctl::Next
            }
            op::LOAD_METHOD => {
                let m = Self::u32_at(p, bci + 1);
                if m >= p.methods.len() { return Ctl::Stuck(stuck::NOT_METHOD); }
                self.push_next_u(smi(m as i64), len!())
            }
            op::LOAD_GLOBAL_VAR | op::LOAD_GLOBAL_VAR_WIDE => {
                let g = if opcode == op::LOAD_GLOBAL_VAR { b1!() } else { w1!() };
                if g >= self.globals.len() { return Ctl::Stuck(stuck::TABLE_RANGE); }
                let v = self.globals.at(g);
                self.push_next_u(v, len!())
            }
            op::STORE_GLOBAL_VAR | op::STORE_GLOBAL_VAR_WIDE => {
                let g = if opcode == op::STORE_GLOBAL_VAR { b1!() } else { w1!() };
                if g >= self.globals.len() { return Ctl::Stuck(stuck::TABLE_RANGE); }
                if !self.has_slot(0) { return Ctl::Stuck(stuck::STACK_RANGE); }
                let v = self.at(0);
                self.globals.set(g, v);
                self.bci += len!();
                Ctl::Next
            }
            op::POP | op::POP_1 => {
                if p.preempt_a_lot { env.pre.request(); }
                let n = if opcode == op::POP { b1!() } else { 1 };
                if n > self.lim - self.top { return Ctl::Stuck(stuck::STACK_RANGE); }
                self.drop(n);
                self.bci += len!();
                Ctl::Next
            }
            op::BRANCH..=op::BRANCH_IF_NOT_NULL => {
                let d = w1!();
                if d == 0 { return Ctl::Stuck(stuck::BAD_BRANCH); }
                self.c_branch(p, (opcode - op::BRANCH) as usize, bci + d, len!())
            }
            op::BRANCH_BACK..=op::BRANCH_BACK_IF_NOT_NULL => {
                if env.pre.requested() {
                    env.pre.clear();
                    return Ctl::Exit(RESULT_PREEMPTED as u32, 0);
                }
                let d = w1!();
                if d > bci { return Ctl::Stuck(stuck::BAD_BRANCH); }
                self.c_branch(p, (opcode - op::BRANCH_BACK) as usize, bci - d, len!())
            }
            _ => self.dispatch_unverified(env, bci, opcode),
        }
    }

    #[inline(always)]
    fn c_load_local(&mut self, n: usize, len: usize) -> Ctl {
        if !self.has_slot(n) { return Ctl::Stuck(stuck::STACK_RANGE); }
        let v = self.at(n);
        self.push_next_u(v, len)
    }

    /// LOOP_REPEAT (proposal, format note 19): `spec::op_loop_repeat` with
    /// every stuck state checked.
    fn c_loop_repeat(&mut self, p: &Program, bci: usize) -> Ctl {
        let n = p.code.at(bci + 3) as usize;
        if n < 1 || !self.has_slot(n + 2) { return Ctl::Stuck(stuck::STACK_RANGE); }
        let (c, b, l) = (self.at(n), self.at(n + 1), self.at(n + 2));
        if !(is_smi(c) && is_smi(l) && (c as isize) < (l as isize)) {
            self.drop(1);
            self.bci += OPCODE_LENGTHS[op::LOOP_REPEAT as usize] as usize;
            return Ctl::Next;
        }
        let d = Self::u16_at(p, bci + 1);
        if d > bci { return Ctl::Stuck(stuck::BAD_BRANCH); }
        let target = bci - d;
        if self.method >= p.methods.len() { return Ctl::Stuck(stuck::BAD_BRANCH); }
        let m = p.method(self.method);
        if !((m.entry as usize) <= target && target < m.end()) {
            return Ctl::Stuck(stuck::BAD_BRANCH);
        }
        // c < l, so c + 1 is a smi: its word is c's plus 2.
        self.put(n, c + 2);
        self.drop(1);
        if !self.push(b) || !self.push(c) { return Ctl::Stuck(stuck::LIMIT); }
        self.bci = target;
        Ctl::Next
    }

    /// HASH_FIND's probe (`spec::hf_find`): `Ok((key, position, slot, step,
    /// deleted))` for a candidate, `Err(code)` otherwise.
    fn c_hf_find(&mut self, p: &Program, coll: usize, hash: usize, slot: usize, step: usize, d: usize)
            -> Result<(usize, i64, i64, i64, i64), i64> {
        match self.instance_fields(p, coll) {
            Some(f) if f >= 4 => {}
            _ => return Err(-2),
        }
        if !(is_smi(hash) && is_smi(slot) && is_smi(step) && is_smi(d)) { return Err(-2); }
        let (hash, slot, step, d) = (smi_value(hash), smi_value(slot), smi_value(step), smi_value(d));
        let (index, backing) = (self.field(coll, 2), self.field(coll, 3));
        let size = match self.fast_size(p, index) { Some(n) => n, None => return Err(-2) };
        if !(1 <= size && size <= 0x100_0000 && size & (size - 1) == 0
            && 0 <= slot && slot < size && 0 <= step && step <= 2 * size && 0 <= d && d <= size) {
            return Err(-2);
        }
        let mask = size - 1;
        let start = hash & mask;
        let (mut slot, mut step, mut d) = if step == 0 {
            (start, 1, d)
        } else {
            let slot2 = (slot + step) & mask;
            if slot2 == start { return Err(-1); }
            (slot2, step + 1, d)
        };
        let tombstone = smi_value(p.builtin.at(10));
        let null = p.null;
        let mut fuel = 2 * size;
        loop {
            if fuel == 0 { return Err(-2); }
            let hw = match self.fast_at(p, index, smi(slot), false, null, 8) { FastAt::Done(w) => w, _ => return Err(-2) };
            if !is_smi(hw) { return Err(-2); }
            let hap = smi_value(hw);
            if hap == 0 { return Err(if d > 0 { 2 * (d - 1) } else { 2 * slot + 1 }); }
            if hap < 0 { return Err(-2); }
            let pos = hap / 4096 - 1;
            if pos < 0 { return Err(-2); }
            let k = match self.fast_at(p, backing, smi(pos), false, null, 8) { FastAt::Done(w) => w, _ => return Err(-2) };
            let tomb = is_heap(k) && (smi_value(self.heap.header(k)) >> CLASS_ID_OFFSET) == tombstone;
            if d == 0 && tomb { d = slot + 1; }
            if (hap & 0xfff) == (hash & 0xfff) && !tomb { return Ok((k, pos, slot, step, d)); }
            let slot2 = (slot + step) & mask;
            if slot2 == start { return Err(-1); }
            slot = slot2;
            step += 1;
            fuel -= 1;
        }
    }

    /// HASH_FIND (proposal, format note 19): `spec::op_hash_find` with every
    /// stuck state checked.
    fn c_hash_find(&mut self, p: &Program, bci: usize) -> Ctl {
        let n = p.code.at(bci + 3) as usize;
        let m = p.code.at(bci + 4) as usize;
        if !self.has_slot(n + 2) || !self.has_slot(m + 2) { return Ctl::Stuck(stuck::STACK_RANGE); }
        let r = self.c_hf_find(p, self.at(m + 2), self.at(m), self.at(n), self.at(n + 1), self.at(n + 2));
        match r {
            Ok((k, pos, slot, step, d)) => {
                self.put(n, smi(slot));
                self.put(n + 1, smi(step));
                self.put(n + 2, smi(d));
                if !self.push(k) || !self.push(smi(pos)) { return Ctl::Stuck(stuck::LIMIT); }
                self.bci += OPCODE_LENGTHS[op::HASH_FIND as usize] as usize;
                Ctl::Next
            }
            Err(code) => {
                let target = bci + Self::u16_at(p, bci + 1);
                if self.method >= p.methods.len() { return Ctl::Stuck(stuck::BAD_BRANCH); }
                let mt = p.method(self.method);
                if !((mt.entry as usize) <= target && target < mt.end()) {
                    return Ctl::Stuck(stuck::BAD_BRANCH);
                }
                if !self.push(smi(code)) { return Ctl::Stuck(stuck::LIMIT); }
                self.bci = target;
                Ctl::Next
            }
        }
    }

    /// LOOP_ARRAY (proposal, format note 19): `spec::op_loop_array` with
    /// every stuck state checked.
    fn c_loop_array(&mut self, p: &Program, bci: usize) -> Ctl {
        let n = p.code.at(bci + 3) as usize;
        if n < 1 || !self.has_slot(n + 3) { return Ctl::Stuck(stuck::STACK_RANGE); }
        let (c, b, e, a) = (self.at(n), self.at(n + 1), self.at(n + 2), self.at(n + 3));
        let go = is_smi(c) && is_smi(e) && (c as isize) >= 0 && (c as isize) < (e as isize)
            && match self.array_length(a) { Some(len) => (smi_value(c) as usize) < len, None => false };
        if !go {
            self.drop(1);
            self.bci += OPCODE_LENGTHS[op::LOOP_ARRAY as usize] as usize;
            return Ctl::Next;
        }
        let d = Self::u16_at(p, bci + 1);
        if d > bci { return Ctl::Stuck(stuck::BAD_BRANCH); }
        let target = bci - d;
        if self.method >= p.methods.len() { return Ctl::Stuck(stuck::BAD_BRANCH); }
        let m = p.method(self.method);
        if !((m.entry as usize) <= target && target < m.end()) {
            return Ctl::Stuck(stuck::BAD_BRANCH);
        }
        let x = self.heap.word(a, ARRAY_ELEMENTS_WORD + smi_value(c) as usize);
        // 0 <= c < e, so c + 1 is a smi: its word is c's plus 2.
        self.put(n, c + 2);
        self.drop(1);
        if !self.push(b) || !self.push(x) { return Ctl::Stuck(stuck::LIMIT); }
        self.bci = target;
        Ctl::Next
    }

    #[inline(always)]
    fn c_branch(&mut self, p: &Program, kind: usize, target: usize, len: usize) -> Ctl {
        if kind != 0 {
            if !self.has_slot(0) { return Ctl::Stuck(stuck::STACK_RANGE); }
            let v = self.at(0);
            self.drop(1);
            let taken = if kind == 1 {
                v != p.false_ && v != p.null
            } else if kind == 2 {
                !(v != p.false_ && v != p.null)
            } else {
                v != p.null
            };
            if !taken {
                self.bci += len;
                return Ctl::Next;
            }
        }
        if self.method >= p.methods.len() { return Ctl::Stuck(stuck::BAD_BRANCH); }
        let m = p.method(self.method);
        if !((m.entry as usize) <= target && target < m.end()) {
            return Ctl::Stuck(stuck::BAD_BRANCH);
        }
        self.bci = target;
        Ctl::Next
    }
}
