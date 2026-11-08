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

//! Verified opcode handlers. Each handler's postcondition states that the
//! abstracted post-state is exactly the spec step of the abstracted
//! pre-state (or the state is unchanged when the spec says Fallback/Trap).

use vstd::prelude::*;
use crate::layout::*;
#[allow(unused_imports)]
use crate::spec::*;
use crate::view::*;

verus! {

pub struct VState {
    pub stack: StackView,
    pub sp: usize,
    pub try_sp: usize,
    pub bcp: usize,
}

impl VState {
    pub open spec fn view(&self) -> AState {
        AState {
            stack: self.stack@,
            sp: self.sp as int,
            try_sp: self.try_sp as int,
            bcp: self.bcp as int,
        }
    }

    pub open spec fn wf(&self) -> bool {
        wf_state(self@)
    }
}

pub struct Env {
    pub code: CodeView,
    pub dispatch: DispatchView,
    pub code_base: usize,
    pub frame_marker: usize,
    pub preempt_a_lot: bool,
    pub room: RoomOracle,
}

impl Env {
    pub open spec fn cfg(&self) -> Cfg {
        Cfg {
            code: self.code@,
            code_base: self.code_base as int,
            dispatch: self.dispatch@,
            frame_marker: self.frame_marker,
            preempt_a_lot: self.preempt_a_lot,
        }
    }

    pub open spec fn wf(&self) -> bool {
        wf_cfg(self.cfg())
    }
}

#[derive(PartialEq, Eq, Clone, Copy)]
pub enum Outcome {
    Next,
    Fallback,
    Trap,
}

/// The refinement relation for one step.
pub open spec fn refines(r: Outcome, step: Step, pre: AState, post: AState) -> bool {
    match step {
        Step::Next(s2) => r == Outcome::Next && post == s2,
        Step::Fallback => r == Outcome::Fallback && post == pre,
        Step::Trap => r == Outcome::Trap && post == pre,
    }
}

/// Common precondition of the handlers.
pub open spec fn pre(st: &VState, e: &Env) -> bool {
    st.wf() && e.wf() && st.bcp < e.code@.len()
}

// ---------------------------------------------------------------------------
// Small verified helpers.

fn push_word(st: &mut VState, v: usize)
    requires
        old(st).wf(),
        old(st).sp >= 1,
    ensures
        final(st).wf(),
        final(st)@ == push(old(st)@, v),
{
    st.stack.write(st.sp - 1, v);
    st.sp = st.sp - 1;
}

/// Exec version of `block_target`; returns stack.len() + 1 for "none".
fn block_target_exec(st: &VState, w: usize) -> (r: Option<usize>)
    requires
        st.wf(),
    ensures
        match block_target(st@, w) {
            None => r.is_none(),
            Some(t) => r == Some(t as usize) && 0 <= t <= st.stack@.len(),
        },
{
    let len = st.stack.len();
    let v = w / SMI_SCALE;
    if w % SMI_SCALE == 0 && v >= BLOCK_SALT && v - BLOCK_SALT <= len {
        Some(len - (v - BLOCK_SALT))
    } else {
        None
    }
}

/// Method::max_height() for the header byte at KIND_HEIGHT_OFFSET.
pub fn method_max_height(kind_height: u8) -> (r: usize)
    ensures
        r == (kind_height as int / METHOD_KIND_BITS_DIVISOR as int) * METHOD_HEIGHT_SCALE as int,
{
    ((kind_height / METHOD_KIND_BITS_DIVISOR) as usize) * METHOD_HEIGHT_SCALE
}

/// The opcodes the core executes (same as spec `covers`).
pub fn covers_exec(op: u8) -> (r: bool)
    ensures
        r == covers(op),
{
    op == OP_LOAD_LOCAL || op == OP_LOAD_LOCAL_WIDE || op == OP_LOAD_LOCAL_0
        || op == OP_LOAD_LOCAL_1 || op == OP_LOAD_LOCAL_2 || op == OP_LOAD_LOCAL_3
        || op == OP_LOAD_LOCAL_4 || op == OP_LOAD_LOCAL_5 || op == OP_STORE_LOCAL
        || op == OP_POP || op == OP_POP_1 || op == OP_LOAD_SMI_U8 || op == OP_INVOKE_STATIC
        || op == OP_RETURN || op == OP_LOAD_OUTER || op == OP_STORE_OUTER
        || op == OP_NON_LOCAL_RETURN || op == OP_NON_LOCAL_RETURN_WIDE || op == OP_LINK
        || op == OP_UNLINK
}

fn u16_exec(e: &Env, i: usize) -> (r: usize)
    requires
        e.wf(),
        i + 1 < e.code@.len(),
    ensures
        r as int == u16_at(e.cfg(), i as int),
{
    let lo = e.code.byte(i) as usize;
    let hi = e.code.byte(i + 1) as usize;
    lo + 256 * hi
}

// ---------------------------------------------------------------------------
// Opcode handlers.

pub fn exec_load_local(st: &mut VState, e: &Env, n: usize, len: usize) -> (r: Outcome)
    requires
        pre(old(st), e),
        n <= 0xffff,
        1 <= len <= 5,
    ensures
        final(st).wf(),
        refines(r, spec_load_local(e.cfg(), old(st)@, n as int, len as int), old(st)@, final(st)@),
{
    if !(st.bcp + len < e.code.len()) || !(st.sp >= 1 && st.sp + n < st.stack.len()) {
        return Outcome::Trap;
    }
    let v = st.stack.read(st.sp + n);
    push_word(st, v);
    st.bcp = st.bcp + len;
    Outcome::Next
}

pub fn exec_store_local(st: &mut VState, e: &Env, n: usize) -> (r: Outcome)
    requires
        pre(old(st), e),
        n <= 0xff,
    ensures
        final(st).wf(),
        refines(r, spec_store_local(e.cfg(), old(st)@, n as int), old(st)@, final(st)@),
{
    if !(st.bcp + LEN_STORE_LOCAL < e.code.len()) || !(st.sp + n < st.stack.len()) {
        return Outcome::Trap;
    }
    let v = st.stack.read(st.sp);
    st.stack.write(st.sp + n, v);
    st.bcp = st.bcp + LEN_STORE_LOCAL;
    Outcome::Next
}

pub fn exec_pop(st: &mut VState, e: &Env, n: usize, len: usize) -> (r: Outcome)
    requires
        pre(old(st), e),
        n <= 0xff,
        1 <= len <= 5,
    ensures
        final(st).wf(),
        refines(r, spec_pop(e.cfg(), old(st)@, n as int, len as int), old(st)@, final(st)@),
{
    if e.preempt_a_lot {
        return Outcome::Fallback;
    }
    if !(st.bcp + len < e.code.len()) || !(st.sp + n <= st.stack.len()) {
        return Outcome::Trap;
    }
    st.sp = st.sp + n;
    st.bcp = st.bcp + len;
    Outcome::Next
}

pub fn exec_load_smi_u8(st: &mut VState, e: &Env) -> (r: Outcome)
    requires
        pre(old(st), e),
    ensures
        final(st).wf(),
        refines(r, spec_load_smi_u8(e.cfg(), old(st)@), old(st)@, final(st)@),
{
    if !(st.bcp + LEN_LOAD_SMI_U8 < e.code.len()) || !(st.sp >= 1) {
        return Outcome::Trap;
    }
    let b = e.code.byte(st.bcp + 1) as usize;
    push_word(st, b * SMI_SCALE);
    st.bcp = st.bcp + LEN_LOAD_SMI_U8;
    Outcome::Next
}

pub fn exec_load_outer(st: &mut VState, e: &Env, k: usize) -> (r: Outcome)
    requires
        pre(old(st), e),
        k <= 0xff,
    ensures
        final(st).wf(),
        refines(r, spec_load_outer(e.cfg(), old(st)@, k as int), old(st)@, final(st)@),
{
    if !(st.bcp + LEN_LOAD_OUTER < e.code.len()) || !(st.sp < st.stack.len()) {
        return Outcome::Trap;
    }
    let w = st.stack.read(st.sp);
    match block_target_exec(st, w) {
        None => Outcome::Trap,
        Some(t) => {
            if !(st.sp + 1 <= t + k && t + k < st.stack.len()) {
                return Outcome::Trap;
            }
            let v = st.stack.read(t + k);
            st.sp = st.sp + 1;
            push_word(st, v);
            st.bcp = st.bcp + LEN_LOAD_OUTER;
            Outcome::Next
        },
    }
}

pub fn exec_store_outer(st: &mut VState, e: &Env, k: usize) -> (r: Outcome)
    requires
        pre(old(st), e),
        k <= 0xff,
    ensures
        final(st).wf(),
        refines(r, spec_store_outer(e.cfg(), old(st)@, k as int), old(st)@, final(st)@),
{
    if !(st.bcp + LEN_STORE_OUTER < e.code.len()) || !(st.sp + 1 < st.stack.len()) {
        return Outcome::Trap;
    }
    let value = st.stack.read(st.sp);
    let w = st.stack.read(st.sp + 1);
    match block_target_exec(st, w) {
        None => Outcome::Trap,
        Some(t) => {
            if !(st.sp + 2 <= t + k && t + k < st.stack.len()) {
                return Outcome::Trap;
            }
            st.sp = st.sp + 2;
            st.stack.write(t + k, value);
            push_word(st, value);
            st.bcp = st.bcp + LEN_STORE_OUTER;
            Outcome::Next
        },
    }
}

pub fn exec_invoke_static(st: &mut VState, e: &Env) -> (r: (Outcome, Ghost<bool>))
    requires
        pre(old(st), e),
    ensures
        final(st).wf(),
        refines(r.0, spec_invoke_static(e.cfg(), old(st)@, r.1@), old(st)@, final(st)@),
{
    if !(st.bcp + LEN_INVOKE_STATIC <= e.code.len()) {
        return (Outcome::Trap, Ghost(false));
    }
    let d = u16_exec(e, st.bcp + 1);
    if !(d < e.dispatch.len()) {
        return (Outcome::Trap, Ghost(false));
    }
    let m = e.dispatch.at(d);
    if !(0 <= m && (m as usize) + METHOD_ENTRY_OFFSET < e.code.len()) {
        return (Outcome::Trap, Ghost(false));
    }
    let m = m as usize;
    if !(st.sp >= FRAME_SIZE) {
        return (Outcome::Fallback, Ghost(false));
    }
    let max_height = method_max_height(e.code.byte(m + METHOD_KIND_HEIGHT_OFFSET));
    let room = e.room.has_room(st.sp - FRAME_SIZE, max_height);
    if !room {
        return (Outcome::Fallback, Ghost(false));
    }
    let ra = e.code_base + st.bcp + LEN_INVOKE_STATIC;
    push_word(st, ra);
    push_word(st, e.frame_marker);
    st.bcp = m + METHOD_ENTRY_OFFSET;
    (Outcome::Next, Ghost(true))
}

/// Pops a frame at stack index `f` (frame marker, return address) and returns
/// the bci of the return address, or None if the frame is malformed.
fn frame_return_bci(st: &VState, e: &Env, f: usize) -> (r: Option<usize>)
    requires
        st.wf(),
        e.wf(),
        f + 1 < st.stack@.len(),
    ensures
        r.is_some() <==> (st.stack@[f + FRAME_MARKER_SLOT] == e.frame_marker
            && is_return_address(e.cfg(), st.stack@[f + RETURN_ADDRESS_SLOT])),
        r.is_some() ==> r.unwrap() as int == bci_of(e.cfg(), st.stack@[f + RETURN_ADDRESS_SLOT])
            && r.unwrap() < e.code@.len(),
{
    if st.stack.read(f + FRAME_MARKER_SLOT) != e.frame_marker {
        return None;
    }
    let ra = st.stack.read(f + RETURN_ADDRESS_SLOT);
    if ra >= e.code_base && ra - e.code_base < e.code.len() {
        Some(ra - e.code_base)
    } else {
        None
    }
}

pub fn exec_return(st: &mut VState, e: &Env) -> (r: Outcome)
    requires
        pre(old(st), e),
    ensures
        final(st).wf(),
        refines(r, spec_return(e.cfg(), old(st)@), old(st)@, final(st)@),
{
    if !(st.bcp + LEN_RETURN <= e.code.len()) || !(st.sp < st.stack.len()) {
        return Outcome::Trap;
    }
    let h = e.code.byte(st.bcp + 1) as usize;
    let a = e.code.byte(st.bcp + 2) as usize;
    let f = st.sp + h;
    if !(f + 1 < st.stack.len()) {
        return Outcome::Trap;
    }
    let bci = match frame_return_bci(st, e, f) {
        None => { return Outcome::Trap; },
        Some(b) => b,
    };
    let new_sp = f + FRAME_SIZE + a;
    if !(new_sp <= st.stack.len()) {
        return Outcome::Trap;
    }
    let result = st.stack.read(st.sp);
    st.sp = new_sp;
    push_word(st, result);
    st.bcp = bci;
    Outcome::Next
}

pub fn exec_nlr(st: &mut VState, e: &Env, arity: usize, h: usize, len: usize) -> (r: Outcome)
    requires
        pre(old(st), e),
        arity <= 0xffff,
        h <= 0xffff,
        1 <= len <= 5,
    ensures
        final(st).wf(),
        refines(r, spec_nlr(e.cfg(), old(st)@, arity as int, h as int, len as int), old(st)@, final(st)@),
{
    if !(st.bcp + len <= e.code.len()) || !(st.sp + 1 < st.stack.len()) {
        return Outcome::Trap;
    }
    let w = st.stack.read(st.sp);
    let result = st.stack.read(st.sp + 1);
    let t = match block_target_exec(st, w) {
        None => { return Outcome::Trap; },
        Some(t) => t,
    };
    let target = t + h + 1;
    let reason = arity * 2 * SMI_SCALE;
    if !(target + 1 < st.stack.len()) {
        return Outcome::Trap;
    }
    if target > st.try_sp {
        // Hit unwind protect.
        if !(st.try_sp >= 1 + FRAME_SIZE && st.try_sp + LINK_RESULT_SLOT < st.stack.len()) {
            return Outcome::Trap;
        }
        let f = st.try_sp - 1 - FRAME_SIZE;
        let bci = match frame_return_bci(st, e, f) {
            None => { return Outcome::Trap; },
            Some(b) => b,
        };
        let ghost s0 = st@;
        let target_block = (st.stack.len() - target + BLOCK_SALT) * SMI_SCALE;
        st.stack.write(st.try_sp + LINK_REASON_SLOT, reason);
        st.stack.write(st.try_sp + LINK_TARGET_SLOT, target_block);
        st.stack.write(st.try_sp + LINK_RESULT_SLOT, result);
        st.sp = f + FRAME_SIZE;
        st.bcp = bci;
        proof {
            assert(target_block == to_block(s0, target as int));
        }
        Outcome::Next
    } else {
        let bci = match frame_return_bci(st, e, target) {
            None => { return Outcome::Trap; },
            Some(b) => b,
        };
        let new_sp = target + FRAME_SIZE + arity;
        if !(new_sp <= st.stack.len()) {
            return Outcome::Trap;
        }
        st.sp = new_sp;
        push_word(st, result);
        st.bcp = bci;
        Outcome::Next
    }
}

pub fn exec_link(st: &mut VState, e: &Env) -> (r: Outcome)
    requires
        pre(old(st), e),
    ensures
        final(st).wf(),
        refines(r, spec_link(e.cfg(), old(st)@), old(st)@, final(st)@),
{
    if !(st.bcp + LEN_LINK < e.code.len()) || !(st.sp >= LINK_WORDS) {
        return Outcome::Trap;
    }
    let chain = (st.stack.len() - st.try_sp) * SMI_SCALE;
    push_word(st, SMI_LINK_RESULT_INIT);
    push_word(st, SMI_LINK_TARGET_INIT);
    push_word(st, SMI_LINK_REASON_INIT);
    push_word(st, chain);
    st.try_sp = st.sp;
    st.bcp = st.bcp + LEN_LINK;
    Outcome::Next
}

pub fn exec_unlink(st: &mut VState, e: &Env) -> (r: Outcome)
    requires
        pre(old(st), e),
    ensures
        final(st).wf(),
        refines(r, spec_unlink(e.cfg(), old(st)@), old(st)@, final(st)@),
{
    if !(st.bcp + LEN_UNLINK < e.code.len()) || !(st.sp < st.stack.len()) {
        return Outcome::Trap;
    }
    let w = st.stack.read(st.sp);
    let v = w / SMI_SCALE;
    if !(w % SMI_SCALE == 0 && v <= st.stack.len()) {
        return Outcome::Trap;
    }
    st.try_sp = st.stack.len() - v;
    st.sp = st.sp + 1;
    st.bcp = st.bcp + LEN_UNLINK;
    Outcome::Next
}

// ---------------------------------------------------------------------------
// Dispatch.

/// Executes one instruction. `room` is the ghost room-oracle value the step
/// observed (irrelevant for all opcodes but INVOKE_STATIC).
pub fn step(st: &mut VState, e: &Env) -> (r: (Outcome, Ghost<bool>))
    requires
        old(st).wf(),
        e.wf(),
    ensures
        final(st).wf(),
        refines(r.0, spec_step(e.cfg(), old(st)@, r.1@), old(st)@, final(st)@),
{
    if !(st.bcp < e.code.len()) {
        return (Outcome::Trap, Ghost(false));
    }
    let op = e.code.byte(st.bcp);
    let has_b1 = st.bcp + 1 < e.code.len();
    if op == OP_LOAD_LOCAL {
        if !has_b1 { return (Outcome::Trap, Ghost(false)); }
        let n = e.code.byte(st.bcp + 1) as usize;
        (exec_load_local(st, e, n, LEN_LOAD_LOCAL), Ghost(false))
    } else if op == OP_LOAD_LOCAL_WIDE {
        if !(st.bcp + 2 < e.code.len()) { return (Outcome::Trap, Ghost(false)); }
        let n = u16_exec(e, st.bcp + 1);
        (exec_load_local(st, e, n, LEN_LOAD_LOCAL_WIDE), Ghost(false))
    } else if OP_LOAD_LOCAL_0 <= op && op <= OP_LOAD_LOCAL_5 {
        (exec_load_local(st, e, (op - OP_LOAD_LOCAL_0) as usize, LEN_LOAD_LOCAL_N), Ghost(false))
    } else if op == OP_STORE_LOCAL {
        if !has_b1 { return (Outcome::Trap, Ghost(false)); }
        let n = e.code.byte(st.bcp + 1) as usize;
        (exec_store_local(st, e, n), Ghost(false))
    } else if op == OP_POP {
        if !has_b1 { return (Outcome::Trap, Ghost(false)); }
        let n = e.code.byte(st.bcp + 1) as usize;
        (exec_pop(st, e, n, LEN_POP), Ghost(false))
    } else if op == OP_POP_1 {
        (exec_pop(st, e, 1, LEN_POP_1), Ghost(false))
    } else if op == OP_LOAD_SMI_U8 {
        (exec_load_smi_u8(st, e), Ghost(false))
    } else if op == OP_INVOKE_STATIC {
        exec_invoke_static(st, e)
    } else if op == OP_RETURN {
        (exec_return(st, e), Ghost(false))
    } else if op == OP_LOAD_OUTER {
        if !has_b1 { return (Outcome::Trap, Ghost(false)); }
        let k = e.code.byte(st.bcp + 1) as usize;
        (exec_load_outer(st, e, k), Ghost(false))
    } else if op == OP_STORE_OUTER {
        if !has_b1 { return (Outcome::Trap, Ghost(false)); }
        let k = e.code.byte(st.bcp + 1) as usize;
        (exec_store_outer(st, e, k), Ghost(false))
    } else if op == OP_NON_LOCAL_RETURN {
        if !has_b1 { return (Outcome::Trap, Ghost(false)); }
        let encoded = e.code.byte(st.bcp + 1);
        let arity = (encoded % 16) as usize;
        let h = (encoded / 16) as usize;
        (exec_nlr(st, e, arity, h, LEN_NON_LOCAL_RETURN), Ghost(false))
    } else if op == OP_NON_LOCAL_RETURN_WIDE {
        if !(st.bcp + 4 < e.code.len()) { return (Outcome::Trap, Ghost(false)); }
        let arity = u16_exec(e, st.bcp + 1);
        let h = u16_exec(e, st.bcp + 3);
        (exec_nlr(st, e, arity, h, LEN_NON_LOCAL_RETURN_WIDE), Ghost(false))
    } else if op == OP_LINK {
        (exec_link(st, e), Ghost(false))
    } else if op == OP_UNLINK {
        (exec_unlink(st, e), Ghost(false))
    } else {
        (Outcome::Fallback, Ghost(false))
    }
}

/// Runs up to `fuel` covered instructions. Returns Fallback when the next
/// instruction must be executed by the C++ interpreter (or fuel ran out),
/// Trap when the next instruction violates a safety check. In both cases
/// the state is the one reached by the executed steps.
pub fn run(st: &mut VState, e: &Env, fuel: usize) -> (r: (Outcome, usize, Ghost<Seq<bool>>))
    requires
        old(st).wf(),
        e.wf(),
    ensures
        final(st).wf(),
        r.0 != Outcome::Next,
        spec_run(e.cfg(), old(st)@, r.2@) == Some(final(st)@),
        r.1 == r.2@.len(),
        r.0 == Outcome::Trap ==> exists|room: bool| spec_step(e.cfg(), final(st)@, room) == Step::Trap,
{
    let ghost s0 = st@;
    let ghost mut rooms: Seq<bool> = Seq::empty();
    let mut i: usize = 0;
    while i < fuel
        invariant
            st.wf(),
            e.wf(),
            s0 == old(st)@,
            spec_run(e.cfg(), s0, rooms) == Some(st@),
            i == rooms.len(),
        decreases fuel - i,
    {
        let ghost before = st@;
        let (r, Ghost(room)) = step(st, e);
        match r {
            Outcome::Next => {
                proof {
                    let old_rooms = rooms;
                    rooms = rooms.push(room);
                    assert(rooms.drop_last() =~= old_rooms);
                    assert(rooms.last() == room);
                }
                i = i + 1;
            },
            _ => {
                assert(st@ == before);
                return (r, i, Ghost(rooms));
            },
        }
    }
    (Outcome::Fallback, i, Ghost(rooms))
}

/// Entry point used by the FFI layer: validates the inputs (so that the
/// views' ghost state is well formed) and runs.
pub fn entry(st: &mut VState, e: &Env, fuel: usize) -> (r: (Outcome, usize))
    ensures
        r.0 != Outcome::Next,
        // The state is touched only if the inputs are well formed, and then
        // it is a spec run from the initial state.
        (old(st).wf() && e.wf()) || final(st)@ == old(st)@,
        old(st).wf() && e.wf() ==> final(st).wf() && exists|rooms: Seq<bool>|
                #[trigger] spec_run(e.cfg(), old(st)@, rooms) == Some(final(st)@) && rooms.len() == r.1,
{
    let len = st.stack.len();
    let code_len = e.code.len();
    if !(len <= MAX_STACK_WORDS && st.sp <= len && st.try_sp <= len
        && code_len <= MAX_CODE_BYTES && e.dispatch.len() <= MAX_CODE_BYTES
        && e.code_base <= usize::MAX - code_len) {
        return (Outcome::Fallback, 0);
    }
    proof {
        assert(spec_run(e.cfg(), st@, Seq::<bool>::empty()) == Some(st@));
    }
    let (r, n, Ghost(rooms)) = run(st, e, fuel);
    (r, n)
}

} // verus!
