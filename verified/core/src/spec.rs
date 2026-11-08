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

//! Abstract machine for the opcodes the verified core executes.
//!
//! The state is the word-level view of the interpreter: the stack object's
//! array as a sequence of words (index 0 is `limit_`, `stack.len()` is
//! `base_`), the stack pointer, the try-chain pointer and the bytecode
//! pointer, all as indices. Words that hold pointers into the bytecodes
//! (return addresses) are absolute addresses `code_base + bci`, exactly as
//! the C++ interpreter stores them.
//!
//! `spec_step` is total. Every precondition the C++ interpreter merely
//! assumes (ASSERT or nothing) is an explicit check here, and a failed check
//! yields `Trap`. `Fallback` means "the core does not execute this step; the
//! C++ interpreter does" and is used for uncovered opcodes and for the cases
//! that need the runtime (stack growth, preemption, debug flags).

use vstd::prelude::*;
#[allow(unused_imports)]
use crate::layout::*;

verus! {

/// Immutable inputs of a run.
pub struct Cfg {
    pub code: Seq<u8>,
    pub code_base: int,
    pub dispatch: Seq<i32>,
    pub frame_marker: usize,
    pub preempt_a_lot: bool,
}

/// Mutable interpreter state.
pub struct AState {
    pub stack: Seq<usize>,
    pub sp: int,
    pub try_sp: int,
    pub bcp: int,
}

pub enum Step {
    Next(AState),
    Fallback,
    Trap,
}

pub open spec fn base(s: AState) -> int {
    s.stack.len() as int
}

pub open spec fn wf_state(s: AState) -> bool {
    &&& 0 <= s.sp <= s.stack.len()
    &&& 0 <= s.try_sp <= s.stack.len()
    &&& s.stack.len() <= MAX_STACK_WORDS
    &&& 0 <= s.bcp
}

pub open spec fn wf_cfg(c: Cfg) -> bool {
    &&& c.code.len() <= MAX_CODE_BYTES
    &&& c.dispatch.len() <= MAX_CODE_BYTES
    &&& 0 <= c.code_base
    &&& c.code_base + c.code.len() <= usize::MAX
}

// ---------------------------------------------------------------------------
// Encoding helpers.

pub open spec fn byte_at(c: Cfg, i: int) -> int {
    c.code[i] as int
}

/// Unaligned little-endian uint16 (Utils::read_unaligned_uint16 on x86 and
/// RISC-V).
pub open spec fn u16_at(c: Cfg, i: int) -> int {
    c.code[i] as int + 256 * (c.code[i + 1] as int)
}

/// Smi::from(v) for 0 <= v.
pub open spec fn smi(v: int) -> usize {
    (v * SMI_SCALE) as usize
}

/// from_block: the stack index a block reference designates, if any.
/// C++: base_ - (Smi::value(block) - BLOCK_SALT). Words that are not smis
/// or designate an index outside the stack are not block references.
pub open spec fn block_target(s: AState, w: usize) -> Option<int> {
    let v = w as int / SMI_SCALE as int;
    if w as int % SMI_SCALE as int == 0 && v >= BLOCK_SALT && v - BLOCK_SALT <= base(s) {
        Some(base(s) - (v - BLOCK_SALT))
    } else {
        None
    }
}

/// to_block: Smi::from(base_ - pointer + BLOCK_SALT).
pub open spec fn to_block(s: AState, p: int) -> usize {
    smi(base(s) - p + BLOCK_SALT)
}

/// Method::max_height() of the method whose header starts at `m`.
pub open spec fn max_height(c: Cfg, m: int) -> int {
    (byte_at(c, m + METHOD_KIND_HEIGHT_OFFSET) / METHOD_KIND_BITS_DIVISOR as int)
        * METHOD_HEIGHT_SCALE as int
}

/// A word is a return address if it points into the bytecodes.
pub open spec fn is_return_address(c: Cfg, w: usize) -> bool {
    c.code_base <= w as int && w as int - c.code_base < c.code.len()
}

pub open spec fn bci_of(c: Cfg, w: usize) -> int {
    w as int - c.code_base
}

/// The next instruction must exist, so that handing control back to the C++
/// interpreter at the new bcp never reads outside the bytecodes.
pub open spec fn can_advance(c: Cfg, s: AState, len: int) -> bool {
    s.bcp + len < c.code.len()
}

// ---------------------------------------------------------------------------
// Primitive state transformers.

pub open spec fn push(s: AState, v: usize) -> AState {
    AState { stack: s.stack.update(s.sp - 1, v), sp: s.sp - 1, ..s }
}

pub open spec fn drop(s: AState, n: int) -> AState {
    AState { sp: s.sp + n, ..s }
}

pub open spec fn put(s: AState, i: int, v: usize) -> AState {
    AState { stack: s.stack.update(i, v), ..s }
}

pub open spec fn goto(s: AState, bcp: int) -> AState {
    AState { bcp, ..s }
}

pub open spec fn tos(s: AState, n: int) -> usize {
    s.stack[s.sp + n]
}

// ---------------------------------------------------------------------------
// One spec function per covered opcode.

/// LOAD_LOCAL, LOAD_LOCAL_WIDE, LOAD_LOCAL_0..5: PUSH(STACK_AT(n)).
pub open spec fn spec_load_local(c: Cfg, s: AState, n: int, len: int) -> Step {
    if !can_advance(c, s, len) || !(s.sp >= 1 && s.sp + n < base(s)) {
        Step::Trap
    } else {
        Step::Next(goto(push(s, tos(s, n)), s.bcp + len))
    }
}

/// STORE_LOCAL n: STACK_AT_PUT(n, STACK_AT(0)).
pub open spec fn spec_store_local(c: Cfg, s: AState, n: int) -> Step {
    if !can_advance(c, s, LEN_STORE_LOCAL as int) || !(s.sp + n < base(s)) {
        Step::Trap
    } else {
        Step::Next(goto(put(s, s.sp + n, tos(s, 0)), s.bcp + LEN_STORE_LOCAL))
    }
}

/// POP n, POP_1: DROP(n). Preempt-a-lot mode is left to C++.
pub open spec fn spec_pop(c: Cfg, s: AState, n: int, len: int) -> Step {
    if c.preempt_a_lot {
        Step::Fallback
    } else if !can_advance(c, s, len) || !(s.sp + n <= base(s)) {
        Step::Trap
    } else {
        Step::Next(goto(drop(s, n), s.bcp + len))
    }
}

/// LOAD_SMI_U8: PUSH(Smi::from(bcp[1])).
pub open spec fn spec_load_smi_u8(c: Cfg, s: AState) -> Step {
    if !can_advance(c, s, LEN_LOAD_SMI_U8 as int) || !(s.sp >= 1) {
        Step::Trap
    } else {
        Step::Next(goto(push(s, smi(byte_at(c, s.bcp + 1))), s.bcp + LEN_LOAD_SMI_U8))
    }
}

/// LOAD_OUTER k: block = POP(); PUSH(from_block(block)[k]).
/// The outer slot must be live (at or above the stack pointer after the pop).
pub open spec fn spec_load_outer(c: Cfg, s: AState, k: int) -> Step {
    if !can_advance(c, s, LEN_LOAD_OUTER as int) || !(s.sp < base(s)) {
        Step::Trap
    } else {
        let s1 = drop(s, 1);
        match block_target(s, tos(s, 0)) {
            None => Step::Trap,
            Some(t) => if !(s1.sp <= t + k < base(s)) {
                Step::Trap
            } else {
                Step::Next(goto(push(s1, s.stack[t + k]), s.bcp + LEN_LOAD_OUTER))
            },
        }
    }
}

/// STORE_OUTER k: value = POP(); block = POP(); from_block(block)[k] = value;
/// PUSH(value).
pub open spec fn spec_store_outer(c: Cfg, s: AState, k: int) -> Step {
    if !can_advance(c, s, LEN_STORE_OUTER as int) || !(s.sp + 1 < base(s)) {
        Step::Trap
    } else {
        let value = tos(s, 0);
        let s1 = drop(s, 2);
        match block_target(s, tos(s, 1)) {
            None => Step::Trap,
            Some(t) => if !(s1.sp <= t + k < base(s)) {
                Step::Trap
            } else {
                Step::Next(goto(push(put(s1, t + k, value), value), s.bcp + LEN_STORE_OUTER))
            },
        }
    }
}

/// INVOKE_STATIC d: target = dispatch_table[d]; push return address and frame
/// marker; continue at the target's entry. `room` is the outcome of the
/// runtime's stack-overflow/preemption check (watermark), which is
/// environment nondeterminism; without room the C++ interpreter handles the
/// call (growing the stack or preempting).
pub open spec fn spec_invoke_static(c: Cfg, s: AState, room: bool) -> Step {
    if !(s.bcp + LEN_INVOKE_STATIC <= c.code.len()) {
        Step::Trap
    } else {
        let d = u16_at(c, s.bcp + 1);
        if !(d < c.dispatch.len()) {
            Step::Trap
        } else {
            let m = c.dispatch[d] as int;
            if !(0 <= m && m + METHOD_ENTRY_OFFSET < c.code.len()) {
                Step::Trap
            } else if !(s.sp >= FRAME_SIZE) || !room {
                Step::Fallback
            } else {
                let ra = (c.code_base + s.bcp + LEN_INVOKE_STATIC) as usize;
                Step::Next(goto(push(push(s, ra), c.frame_marker), m + METHOD_ENTRY_OFFSET))
            }
        }
    }
}

/// RETURN h a: result = STACK_AT(0); DROP(h); pop frame marker and return
/// address; DROP(a); PUSH(result).
pub open spec fn spec_return(c: Cfg, s: AState) -> Step {
    if !(s.bcp + LEN_RETURN <= c.code.len()) || !(s.sp < base(s)) {
        Step::Trap
    } else {
        let h = byte_at(c, s.bcp + 1);
        let a = byte_at(c, s.bcp + 2);
        let f = s.sp + h;
        if !(f + 1 < base(s)) || s.stack[f + FRAME_MARKER_SLOT] != c.frame_marker {
            Step::Trap
        } else {
            let ra = s.stack[f + RETURN_ADDRESS_SLOT];
            let new_sp = f + FRAME_SIZE + a;
            if !is_return_address(c, ra) || !(new_sp <= base(s)) {
                Step::Trap
            } else {
                Step::Next(goto(push(AState { sp: new_sp, ..s }, tos(s, 0)), bci_of(c, ra)))
            }
        }
    }
}

/// NON_LOCAL_RETURN(_WIDE) with the unwind it jumps to.
///
/// C++: block = POP(); result = POP(); target = from_block(block) + h + 1;
/// push result, to_block(target), Smi(arity << 1); goto UNWIND. The unwinder
/// either finds a try/finally between here and the target (`target >
/// try_sp_`) and simulates a return from the try-block call with the link
/// words updated, or it returns from the target frame. The three pushed
/// words are dead in both cases and are not modelled.
pub open spec fn spec_nlr(c: Cfg, s: AState, arity: int, h: int, len: int) -> Step {
    if !(s.bcp + len <= c.code.len()) || !(s.sp + 1 < base(s)) {
        Step::Trap
    } else {
        let result = tos(s, 1);
        match block_target(s, tos(s, 0)) {
            None => Step::Trap,
            Some(t) => {
                let target = t + h + 1;
                let reason = smi(arity * 2);
                if !(target + 1 < base(s)) {
                    Step::Trap
                } else if target > s.try_sp {
                    // Hit unwind protect: sp = try_sp_ - 1 - FRAME_SIZE.
                    let f = s.try_sp - 1 - FRAME_SIZE;
                    if !(f >= 0 && s.try_sp + LINK_RESULT_SLOT < base(s)) {
                        Step::Trap
                    } else if s.stack[f + FRAME_MARKER_SLOT] != c.frame_marker {
                        Step::Trap
                    } else {
                        let ra = s.stack[f + RETURN_ADDRESS_SLOT];
                        if !is_return_address(c, ra) {
                            Step::Trap
                        } else {
                            let s1 = put(put(put(s, s.try_sp + LINK_REASON_SLOT, reason),
                                             s.try_sp + LINK_TARGET_SLOT, to_block(s, target)),
                                         s.try_sp + LINK_RESULT_SLOT, result);
                            Step::Next(goto(AState { sp: f + FRAME_SIZE, ..s1 }, bci_of(c, ra)))
                        }
                    }
                } else if s.stack[target + FRAME_MARKER_SLOT] != c.frame_marker {
                    Step::Trap
                } else {
                    let ra = s.stack[target + RETURN_ADDRESS_SLOT];
                    let new_sp = target + FRAME_SIZE + arity;
                    if !is_return_address(c, ra) || !(new_sp <= base(s)) {
                        Step::Trap
                    } else {
                        Step::Next(goto(push(AState { sp: new_sp, ..s }, result), bci_of(c, ra)))
                    }
                }
            }
        }
    }
}

/// LINK: push result, target, reason and the chain (Smi(base_ - try_sp_));
/// try_sp_ = sp.
pub open spec fn spec_link(c: Cfg, s: AState) -> Step {
    if !can_advance(c, s, LEN_LINK as int) || !(s.sp >= LINK_WORDS) {
        Step::Trap
    } else {
        let s1 = push(push(push(push(s, SMI_LINK_RESULT_INIT), SMI_LINK_TARGET_INIT),
                           SMI_LINK_REASON_INIT), smi(base(s) - s.try_sp));
        Step::Next(goto(AState { try_sp: s1.sp, ..s1 }, s.bcp + LEN_LINK))
    }
}

/// UNLINK: try_sp_ = base_ - Smi::value(POP()).
pub open spec fn spec_unlink(c: Cfg, s: AState) -> Step {
    if !can_advance(c, s, LEN_UNLINK as int) || !(s.sp < base(s)) {
        Step::Trap
    } else {
        let w = tos(s, 0);
        let v = w as int / SMI_SCALE as int;
        if !(w as int % SMI_SCALE as int == 0 && v <= base(s)) {
            Step::Trap
        } else {
            Step::Next(goto(AState { try_sp: base(s) - v, ..drop(s, 1) }, s.bcp + LEN_UNLINK))
        }
    }
}

pub open spec fn covers(op: u8) -> bool {
    op == OP_LOAD_LOCAL || op == OP_LOAD_LOCAL_WIDE || op == OP_LOAD_LOCAL_0
        || op == OP_LOAD_LOCAL_1 || op == OP_LOAD_LOCAL_2 || op == OP_LOAD_LOCAL_3
        || op == OP_LOAD_LOCAL_4 || op == OP_LOAD_LOCAL_5 || op == OP_STORE_LOCAL
        || op == OP_POP || op == OP_POP_1 || op == OP_LOAD_SMI_U8 || op == OP_INVOKE_STATIC
        || op == OP_RETURN || op == OP_LOAD_OUTER || op == OP_STORE_OUTER
        || op == OP_NON_LOCAL_RETURN || op == OP_NON_LOCAL_RETURN_WIDE || op == OP_LINK
        || op == OP_UNLINK
}

/// One step of the abstract machine.
pub open spec fn spec_step(c: Cfg, s: AState, room: bool) -> Step {
    if !(s.bcp < c.code.len()) {
        Step::Trap
    } else {
        let op = c.code[s.bcp];
        // Operand bytes are read only after the length check inside each
        // case, so these may be out of range when unused.
        let b1 = byte_at(c, s.bcp + 1);
        if op == OP_LOAD_LOCAL {
            if !(s.bcp + 1 < c.code.len()) { Step::Trap } else { spec_load_local(c, s, b1, LEN_LOAD_LOCAL as int) }
        } else if op == OP_LOAD_LOCAL_WIDE {
            if !(s.bcp + 2 < c.code.len()) { Step::Trap } else { spec_load_local(c, s, u16_at(c, s.bcp + 1), LEN_LOAD_LOCAL_WIDE as int) }
        } else if OP_LOAD_LOCAL_0 <= op <= OP_LOAD_LOCAL_5 {
            spec_load_local(c, s, op - OP_LOAD_LOCAL_0, LEN_LOAD_LOCAL_N as int)
        } else if op == OP_STORE_LOCAL {
            if !(s.bcp + 1 < c.code.len()) { Step::Trap } else { spec_store_local(c, s, b1) }
        } else if op == OP_POP {
            if !(s.bcp + 1 < c.code.len()) { Step::Trap } else { spec_pop(c, s, b1, LEN_POP as int) }
        } else if op == OP_POP_1 {
            spec_pop(c, s, 1, LEN_POP_1 as int)
        } else if op == OP_LOAD_SMI_U8 {
            spec_load_smi_u8(c, s)
        } else if op == OP_INVOKE_STATIC {
            spec_invoke_static(c, s, room)
        } else if op == OP_RETURN {
            spec_return(c, s)
        } else if op == OP_LOAD_OUTER {
            if !(s.bcp + 1 < c.code.len()) { Step::Trap } else { spec_load_outer(c, s, b1) }
        } else if op == OP_STORE_OUTER {
            if !(s.bcp + 1 < c.code.len()) { Step::Trap } else { spec_store_outer(c, s, b1) }
        } else if op == OP_NON_LOCAL_RETURN {
            if !(s.bcp + 1 < c.code.len()) { Step::Trap } else { spec_nlr(c, s, b1 % 16, b1 / 16, LEN_NON_LOCAL_RETURN as int) }
        } else if op == OP_NON_LOCAL_RETURN_WIDE {
            if !(s.bcp + 4 < c.code.len()) {
                Step::Trap
            } else {
                spec_nlr(c, s, u16_at(c, s.bcp + 1), u16_at(c, s.bcp + 3), LEN_NON_LOCAL_RETURN_WIDE as int)
            }
        } else if op == OP_LINK {
            spec_link(c, s)
        } else if op == OP_UNLINK {
            spec_unlink(c, s)
        } else {
            Step::Fallback
        }
    }
}

/// Executing the steps in `rooms` (one room oracle value per step) from `s`
/// reaches the returned state, with every step a `Next`.
pub open spec fn spec_run(c: Cfg, s: AState, rooms: Seq<bool>) -> Option<AState>
    decreases rooms.len(),
{
    if rooms.len() == 0 {
        Some(s)
    } else {
        match spec_run(c, s, rooms.drop_last()) {
            None => None,
            Some(s1) => match spec_step(c, s1, rooms.last()) {
                Step::Next(s2) => Some(s2),
                _ => None,
            },
        }
    }
}

} // verus!
