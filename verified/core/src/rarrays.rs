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

//! Collections, allocation and primitives on registers (the fast paths;
//! DESIGN.md "Run loop").
//!
//! INVOKE_AT, INVOKE_AT_PUT and INVOKE_SIZE: the receivers `fast_at` and
//! `fast_size` handle (`arrays::locate`, `size_x`, which look at the heap
//! only) are read and written through the registers; anything else (the
//! operator's virtual call) runs on the machine's handler (`bridge_r`).
//!
//! ALLOCATE(_WIDE): a GC point. The registers are written back, the state
//! saved, the trusted allocation called and the machine reloaded (as
//! `alloc.rs`); the new instance is pushed on the reloaded machine and
//! `room::regain` derives the registers again (and grows the stack if the
//! GC shrank it). Out of memory throws on the machine.
//!
//! PRIMITIVE: a Rust primitive (`prims::call`, no GC point) runs on the
//! frame's parameters in place; success returns through the registers (a
//! return the fast path of `rcalls::op_return` takes; otherwise the
//! machine's `do_return`), failure pushes the error. A C++ primitive (a GC
//! point that may switch the task), a missing one, and a Rust primitive
//! that needs a GC run on the machine's handler (`bridge_r`).

use vstd::prelude::*;
use crate::layout::*;
use crate::view::*;
use crate::abs::*;
use crate::exec::*;
use crate::regs::*;
use crate::room::*;
use crate::step::*;
use crate::calls::*;
use crate::arrays::*;
use crate::alloc::{reload, gc_allocate_instance};
#[cfg(verus_keep_ghost)]
use crate::alloc::{reloaded, lemma_saved, new_instance};
#[cfg(verus_keep_ghost)]
use crate::halt::lemma_word_tag;
use crate::prims::{self, PrimOutcome};
#[cfg(verus_keep_ghost)]
use crate::primitive::{lemma_rust_args, lemma_refines_heap, lemma_completion, lemma_source_completion,
    norm_args, args_at};
use toit_spec::v2::prim::PrimRet;
use toit_spec::types::{Value, HeapObj, Body, Unwind, Frame};
use toit_spec::v2::types::{State2, Program2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::types::{p1, as1};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, step_ok, outcome_ok, cur_op, good};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound_instr::lemma_instr;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::prim::{with_heap2, prim_success, prim_args};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::bytecodes::opcode_length2;
#[cfg(verus_keep_ghost)]
use toit_spec::spec_common::{smi, u16_at, elements};

verus! {

// ---------------------------------------------------------------------------
// Heap writes with stale register fields.

/// `m1` is `m0` with another heap and the ghost state with another heap:
/// everything the registers describe is unchanged.
pub open spec fn heap_only(m0: Machine, m1: Machine) -> bool {
    &&& m1.mem == m0.mem
    &&& m1.globals == m0.globals
    &&& m1.len == m0.len && m1.top == m0.top && m1.ftop == m0.ftop && m1.rtop == m0.rtop
    &&& m1.bci == m0.bci && m1.base == m0.base && m1.lim == m0.lim && m1.method == m0.method
    &&& m1.fw == m0.fw && m1.need == m0.need && m1.bot == m0.bot
    &&& m1.heap.addrs() == m0.heap.addrs()
    &&& m1.g@ == (State2 { heap: m1.g@.heap, ..m0.g@ })
}

/// A heap change that keeps the heap part of the abstraction keeps all of
/// it.
pub proof fn lemma_heap_only(p: &Program, m0: Machine, m1: Machine)
    requires m0.refines(p), m1.hrefines(p), heap_only(m0, m1),
    ensures m1.refines(p),
{
    assert(m1.words() =~= m0.words());
}

/// `Machine::set_element_val` on the heap part of the abstraction.
#[inline(always)]
pub fn set_element_h(m: &mut Machine, p: &Program, w: usize, Ghost(v): Ghost<Value>, n: usize, wx: usize,
    Ghost(x): Ghost<Value>)
    requires
        old(m).hrefines(p),
        w == enc(old(m).addr(), v),
        v is Obj,
        (v->Obj_0 as int) < old(m).g@.heap.len(),
        old(m).g@.heap[v->Obj_0 as int].body is Array,
        n < old(m).g@.heap[v->Obj_0 as int].body->Array_0.len(),
        !old(m).g@.heap[v->Obj_0 as int].ro,
        wx == enc(old(m).addr(), x),
        encodable(old(m).addr(), x),
    ensures
        final(m).hrefines(p),
        heap_only(*old(m), *final(m)),
        final(m).g@ == (State2 {
            heap: old(m).g@.heap.update(v->Obj_0 as int, HeapObj {
                body: Body::Array(old(m).g@.heap[v->Obj_0 as int].body->Array_0.update(n as int, x)),
                ..old(m).g@.heap[v->Obj_0 as int]
            }),
            ..old(m).g@
        }),
{
    let ghost g0 = m.g@;
    let ghost id = v->Obj_0 as int;
    m.heap.set_element(w, n, wx, Ghost(id), Ghost(x));
    let ghost g1 = State2 {
        heap: g0.heap.update(id, HeapObj {
            body: Body::Array(g0.heap[id].body->Array_0.update(n as int, x)),
            ..g0.heap[id]
        }),
        ..g0
    };
    m.g = Ghost(g1);
    proof {
        let objs = m.heap.objs();
        let cb = m.heap.class_bits();
        let a = m.addr();
        assert(objs == g1.heap);
        assert forall|i: int| 0 <= i < objs.len() implies #[trigger] obj_model_ok(objs[i], cb, a) by {
            assert(obj_model_ok(g0.heap[i], cb, a));
            if i == id {
                let es = g0.heap[id].body->Array_0.update(n as int, x);
                assert forall|j: int| 0 <= j < es.len() implies #[trigger] encodable(a, es[j]) by {
                    if j != n { assert(es[j] == g0.heap[id].body->Array_0[j]); }
                }
            }
        }
        assert(heap_model_ok(objs, a, cb));
        assert forall|i: int| 0 <= i < g1.heap.len() implies #[trigger] g1.heap[i].ro == in_ro(p, a[i]) by {
            assert(g0.heap[i].ro == in_ro(p, a[i]));
        }
        lemma_prog_rel_update(p, g0.heap, a, id, g1.heap[id]);
        assert(g1.heap == g0.heap.update(id, g1.heap[id]));
        assert(m.hrefines(p));
    }
}

/// `Machine::set_byte_val` on the heap part of the abstraction.
#[inline(always)]
pub fn set_byte_h(m: &mut Machine, p: &Program, w: usize, Ghost(v): Ghost<Value>, n: usize, b: u8)
    requires
        old(m).hrefines(p),
        w == enc(old(m).addr(), v),
        v is Obj,
        (v->Obj_0 as int) < old(m).g@.heap.len(),
        old(m).g@.heap[v->Obj_0 as int].body is Bytes,
        n < old(m).g@.heap[v->Obj_0 as int].body->Bytes_0.len(),
        !old(m).g@.heap[v->Obj_0 as int].ro,
    ensures
        final(m).hrefines(p),
        heap_only(*old(m), *final(m)),
        final(m).g@ == (State2 {
            heap: old(m).g@.heap.update(v->Obj_0 as int, HeapObj {
                body: Body::Bytes(old(m).g@.heap[v->Obj_0 as int].body->Bytes_0.update(n as int, b)),
                ..old(m).g@.heap[v->Obj_0 as int]
            }),
            ..old(m).g@
        }),
{
    let ghost g0 = m.g@;
    let ghost id = v->Obj_0 as int;
    m.heap.set_byte_at(w, n, b, Ghost(id));
    let ghost g1 = State2 {
        heap: g0.heap.update(id, HeapObj {
            body: Body::Bytes(g0.heap[id].body->Bytes_0.update(n as int, b)),
            ..g0.heap[id]
        }),
        ..g0
    };
    m.g = Ghost(g1);
    proof {
        let objs = m.heap.objs();
        let cb = m.heap.class_bits();
        let a = m.addr();
        assert(objs == g1.heap);
        assert forall|i: int| 0 <= i < objs.len() implies #[trigger] obj_model_ok(objs[i], cb, a) by {
            assert(obj_model_ok(g0.heap[i], cb, a));
        }
        assert(heap_model_ok(objs, a, cb));
        assert forall|i: int| 0 <= i < g1.heap.len() implies #[trigger] g1.heap[i].ro == in_ro(p, a[i]) by {
            assert(g0.heap[i].ro == in_ro(p, a[i]));
        }
        lemma_prog_rel_update(p, g0.heap, a, id, g1.heap[id]);
        assert(g1.heap == g0.heap.update(id, g1.heap[id]));
        assert(m.hrefines(p));
    }
}

// ---------------------------------------------------------------------------
// Results through the registers (steps inside the top frame).

/// Replaces the two operands by the encoding `w` of `v` and continues
/// after the instruction (`spec::binary_result`).
#[inline(always)]
pub fn binary_next_r(m: &mut Machine, r: &mut Regs, p: &Program, w: usize, Ghost(v): Ghost<Value>)
    requires
        m_ok(p, *old(m), *old(r)),
        sp::has_slot(old(m).g@, 1),
        w == enc(old(m).addr(), v),
        encodable(old(m).addr(), v),
        old(r).ip@ + 1 < 0x1000_0000,
    ensures
        rsame(*old(m), *final(m)),
        rnext(p, *final(m), *final(r), sp::binary_result(old(m).g@, v)),
{
    let ghost m0 = m.with(*r);
    let ghost g0 = m.g@;
    proof { m0.lemma_at(p, 1); m0.lemma_frame(p); }
    r.sp.write(1, w, &mut m.mem);
    r.sp = r.sp.offset(1);
    r.ip = r.ip.offset(1 as isize);
    let ghost g1 = sp::goto(sp::push(sp::drop(g0, 2), v), g0.bci + 1);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        let h = g0.stack.len();
        assert(m1.words() =~= m0.words().subrange(0, h - 2).push(w));
        assert forall|i: int| 0 <= i < h - 1 implies #[trigger] m1.words()[i] == enc(m0.addr(), g1.stack[i]) by {
            if i < h - 2 {
                assert(m1.words()[i] == m0.words()[i]);
                assert(m0.words()[i] == enc_seq(m0.addr(), g0.stack)[i]);
            }
        }
        assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
        assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
            if i < h - 2 { assert(g1.stack[i] == g0.stack[i]); }
        }
        lemma_local(p, m0, m1, g1);
    }
}

/// Replaces the three operands of INVOKE_AT_PUT by the encoding `w` of `v`
/// and continues after the instruction.
#[inline(always)]
pub fn put_result_r(m: &mut Machine, r: &mut Regs, p: &Program, w: usize, Ghost(v): Ghost<Value>)
    requires
        m_ok(p, *old(m), *old(r)),
        sp::has_slot(old(m).g@, 2),
        w == enc(old(m).addr(), v),
        encodable(old(m).addr(), v),
        old(r).ip@ + 1 < 0x1000_0000,
    ensures
        rsame(*old(m), *final(m)),
        rnext(p, *final(m), *final(r), sp::next(sp::push(sp::drop(old(m).g@, 3), v), 1)),
{
    let ghost m0 = m.with(*r);
    let ghost g0 = m.g@;
    proof { m0.lemma_at(p, 2); m0.lemma_frame(p); }
    r.sp.write(2, w, &mut m.mem);
    r.sp = r.sp.offset(2);
    r.ip = r.ip.offset(1 as isize);
    let ghost g1 = sp::goto(sp::push(sp::drop(g0, 3), v), g0.bci + 1);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        let h = g0.stack.len();
        assert(m1.words() =~= m0.words().subrange(0, h - 3).push(w));
        assert forall|i: int| 0 <= i < h - 2 implies #[trigger] m1.words()[i] == enc(m0.addr(), g1.stack[i]) by {
            if i < h - 3 {
                assert(m1.words()[i] == m0.words()[i]);
                assert(m0.words()[i] == enc_seq(m0.addr(), g0.stack)[i]);
            }
        }
        assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
        assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
            if i < h - 3 { assert(g1.stack[i] == g0.stack[i]); }
        }
        lemma_local(p, m0, m1, g1);
    }
}

/// Replaces the operand by the encoding `w` of `x` and continues `len`
/// bytes further (INVOKE_SIZE).
#[inline(always)]
pub fn put0_next_r(m: &mut Machine, r: &mut Regs, p: &Program, w: usize, Ghost(x): Ghost<Value>, len: usize)
    requires
        m_ok(p, *old(m), *old(r)),
        sp::has_slot(old(m).g@, 0),
        w == enc(old(m).addr(), x),
        encodable(old(m).addr(), x),
        old(r).ip@ + len < 0x1000_0000,
    ensures
        rsame(*old(m), *final(m)),
        rnext(p, *final(m), *final(r), sp::next(sp::put(old(m).g@, 0, x), len as int)),
{
    let ghost m0 = m.with(*r);
    let ghost g0 = m.g@;
    proof { m0.lemma_at(p, 0); }
    r.sp.write(0, w, &mut m.mem);
    r.ip = r.ip.offset(len as isize);
    let ghost g1 = sp::goto(sp::put(g0, 0, x), g0.bci + len);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        assert(m1.words() =~= m0.words().update(m0.height() - 1, w));
        assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
        assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
            if i != g0.stack.len() - 1 { assert(g1.stack[i] == g0.stack[i]); }
        }
        lemma_local(p, m0, m1, g1);
    }
}

// ---------------------------------------------------------------------------
// Back to the registers after a path on the machine.

/// After a path that ran on the machine (`step_post` from `w0`): on `Next`
/// the room is re-established (`ensure_room_all`, unless `ok` says that it
/// holds) and the registers derived; otherwise the machine is the result.
#[inline(never)]
pub fn resume_r(m: &mut Machine, r: Regs, env: &Env, c: Ctl, ok: bool, Ghost(w0): Ghost<Machine>) -> (res: (Regs, Ctl))
    requires
        step_post(&env.p, w0, *old(m), c),
        ok ==> room_ok(&env.p, *old(m)),
    ensures
        res.1 == Ctl::Next ==> final(m).rok(res.0) && crate::regs::ipok(&env.p, res.0) && steps_post(&env.p, w0, final(m).with(res.0), res.1)
            && room_ok(&env.p, final(m).with(res.0)) && crate::regs::gate_ok(&env.p, *final(m)),
        res.1 != Ctl::Next ==> steps_post(&env.p, w0, *final(m), res.1),
{
    match crate::step::resume_with(m, env, c, ok, Ghost(w0)) {
        (Some(r2), Ctl::Next) => (r2, Ctl::Next),
        (_, c2) => (r, c2),
    }
}

/// After a return on the machine (`Machine::do_return`) from the state
/// `gr`, which has the frames of `w0` (a machine with room): the return
/// popped the top frame (entering finally code or not) and the frames below
/// keep the room they had, so only the new top frame is checked
/// (`step::top_room_kept`), not every frame (`ensure_room_all`).
#[inline(always)]
fn ret_room_kept(m: &Machine, env: &Env, c: &Ctl, Ghost(w0): Ghost<Machine>, Ghost(gr): Ghost<State2>,
    Ghost(v): Ghost<Value>) -> (ok: bool)
    requires
        step_post(&env.p, w0, *m, *c),
        room_ok(&env.p, w0),
        gr.frames == w0.g@.frames,
        *c == Ctl::Next ==> Outcome2::Next(m.g@) == sp::return_from(env.p.ap@, gr, v),
        m.len >= w0.len,
    ensures ok ==> room_ok(&env.p, *m),
{
    if let Ctl::Next = *c {
        proof {
            crate::unwind::lemma_return_prefix(env.p.ap@, gr, v);
            assert(top_kept(w0.g@, m.g@));
        }
        top_room_kept(m, env, Ghost(w0))
    } else {
        false
    }
}

// ---------------------------------------------------------------------------
// INVOKE_AT, INVOKE_AT_PUT, INVOKE_SIZE.

/// INVOKE_AT (`spec::op_invoke_at`).
#[inline(always)]
pub fn op_invoke_at(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        opcode == 78,
        bci + 1 < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost s = as1(g);
    let ghost w0 = m.with(*r);
    let ghost rv = sp::at(g, 1);
    let ghost av = sp::at(g, 0);
    proof {
        lemma_step_at(p, g);
        lemma_heap_good(p, g);
        w0.lemma_at(p, 0);
        w0.lemma_at(p, 1);
        assert(const_ok(g.heap, ap.roots[0]));
        assert(m.hrefines(p));
    }
    let recv = at(m, r, 1);
    let arg = at(m, r, 0);
    if let Some(n) = index_x(m, p, arg, Ghost(av)) {
        let null = p.null;
        match m.locate(p, recv, Ghost(rv), n, false, null, Ghost(sp::null2(ap)), 8) {
            Loc::Elem(aw, garr, i) => {
                let ghost arr = garr@;
                let ghost id = arr->Obj_0 as int;
                let ghost x = elements(s, arr)[i as int];
                proof {
                    lemma_val(p, *m, aw, arr);
                    assert(obj_model_ok(g.heap[id], m.heap.class_bits(), m.addr()));
                }
                let w = m.heap.element(aw, i, Ghost(id));
                proof { assert(sp::op_invoke_at(ap, g) == sp::binary_result(g, x)); }
                binary_next_r(m, r, p, w, Ghost(x));
                proof {
                    lemma_matches(p, w0, m.with(*r), Ctl::Next);
                    lemma_room_same(p, w0, m.with(*r));
                }
                return Ctl::Next;
            },
            Loc::Byte(bw, gba, i) => {
                let ghost ba = gba@;
                let ghost id = ba->Obj_0 as int;
                proof { lemma_val(p, *m, bw, ba); }
                let b = m.heap.byte_at(bw, i, Ghost(id));
                let ghost x = smi(b as int);
                proof {
                    lemma_smi_word_nat(b as i64);
                    assert(sp::op_invoke_at(ap, g) == sp::binary_result(g, x));
                }
                let w = smi_of(b as i64);
                binary_next_r(m, r, p, w, Ghost(x));
                proof {
                    lemma_matches(p, w0, m.with(*r), Ctl::Next);
                    lemma_room_same(p, w0, m.with(*r));
                }
                return Ctl::Next;
            },
            Loc::Fail => {},
        }
    } else {
        proof { reveal_with_fuel(toit_spec::spec_helpers::fast_at, 1); }
    }
    // The operator's virtual call (on registers; lookup failures, stack
    // growth and preemption via the bridge).
    proof { assert(sp::op_invoke_at(ap, g) == sp::operator_fallback(ap, g, opcode)); }
    crate::rops::rfallback(m, r, env, bci, opcode)
}

/// INVOKE_AT_PUT (`spec::op_invoke_at_put`): stores the value and leaves it
/// (a byte array stores and leaves the value modulo 256).
#[inline(always)]
pub fn op_invoke_at_put(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        opcode == 79,
        bci + 1 < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost s = as1(g);
    let ghost w0 = m.with(*r);
    let ghost rv = sp::at(g, 2);
    let ghost av = sp::at(g, 1);
    let ghost xv = sp::at(g, 0);
    proof {
        lemma_step_at(p, g);
        lemma_heap_good(p, g);
        w0.lemma_at(p, 0);
        w0.lemma_at(p, 1);
        w0.lemma_at(p, 2);
        assert(m.hrefines(p));
    }
    let recv = at(m, r, 2);
    let arg = at(m, r, 1);
    let value = at(m, r, 0);
    if let Some(n) = index_x(m, p, arg, Ghost(av)) {
        match m.locate(p, recv, Ghost(rv), n, true, value, Ghost(xv), 8) {
            Loc::Elem(aw, garr, i) => {
                let ghost arr = garr@;
                proof { lemma_val(p, *m, aw, arr); }
                set_element_h(m, p, aw, Ghost(arr), i, value, Ghost(xv));
                proof {
                    lemma_heap_only(p, w0, m.with(*r));
                    let g1 = m.g@;
                    assert(sp::op_invoke_at_put(ap, g) == sp::next(sp::push(sp::drop(g1, 3), xv), 1));
                }
                let ghost m1 = *m;
                put_result_r(m, r, p, value, Ghost(xv));
                proof {
                    lemma_matches(p, w0, m.with(*r), Ctl::Next);
                    lemma_room_same(p, w0, m.with(*r));
                }
                return Ctl::Next;
            },
            Loc::Byte(bw, gba, i) => {
                let ghost ba = gba@;
                proof { lemma_val(p, *m, bw, ba); lemma_word_tag(m, p, value, xv); }
                let b = smi_value(value) as u8;
                proof {
                    let v = xv->Smi_0;
                    assert(b as int == (v as int) % 256) by (bit_vector)
                        requires b == ((v as i64) as u8);
                }
                set_byte_h(m, p, bw, Ghost(ba), i, b);
                let ghost x = smi(b as int);
                proof {
                    lemma_heap_only(p, w0, m.with(*r));
                    let g1 = m.g@;
                    lemma_smi_word_nat(b as i64);
                    assert(sp::op_invoke_at_put(ap, g) == sp::next(sp::push(sp::drop(g1, 3), x), 1));
                }
                let w = smi_of(b as i64);
                put_result_r(m, r, p, w, Ghost(x));
                proof {
                    lemma_matches(p, w0, m.with(*r), Ctl::Next);
                    lemma_room_same(p, w0, m.with(*r));
                }
                return Ctl::Next;
            },
            Loc::Fail => {},
        }
    } else {
        proof { reveal_with_fuel(toit_spec::spec_helpers::fast_at, 1); }
    }
    proof { assert(sp::op_invoke_at_put(ap, g) == sp::operator_fallback(ap, g, opcode)); }
    crate::rops::rfallback(m, r, env, bci, opcode)
}

/// INVOKE_SIZE (`spec::op_invoke_size`): `spec_helpers::fast_size`, else
/// the virtual getter (on the machine).
#[inline(always)]
pub fn op_invoke_size(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8, sel_: usize) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        sel_ as int == u16_at(p1(env.p.ap@), bci + 1),
        sel_ < 0x1_0000,
        opcode == 80,
        bci + 3 < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost w0 = m.with(*r);
    let ghost rv = sp::at(g, 0);
    let ghost sel = u16_at(p1(ap), g.bci + 1);
    proof {
        lemma_step_at(p, g);
        lemma_heap_good(p, g);
        w0.lemma_at(p, 0);
        assert(m.hrefines(p));
    }
    let recv = at(m, r, 0);
    match m.size_x(p, recv, Ghost(rv)) {
        Some(n) => {
            let ghost x = smi(n as int);
            proof {
                lemma_smi_word(n);
                assert(sp::op_invoke_size(ap, g, sel) == sp::next(sp::put(g, 0, x), 3));
            }
            let w = smi_of(n);
            put0_next_r(m, r, p, w, Ghost(x), 3);
            proof {
                lemma_matches(p, w0, m.with(*r), Ctl::Next);
                lemma_room_same(p, w0, m.with(*r));
            }
            Ctl::Next
        },
        None => {
            // The virtual getter (`spec::op_invoke_virtual_get`), on registers.
            proof { assert(sp::op_invoke_size(ap, g, sel) == sp::op_invoke_virtual_get(ap, g, sel)); }
            crate::rfields::op_invoke_virtual_get(m, r, env, bci, opcode, sel_, false)
        },
    }
}

// ---------------------------------------------------------------------------
// ALLOCATE.

/// ALLOCATE(_WIDE) c (`spec::op_allocate`): the GC point on the machine,
/// then the registers again (`room::regain`).
#[inline(always)]
pub fn op_allocate(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8, c: usize, len: usize) -> (ctl: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_allocate(env.p.ap@, old(m).g@, c as int, len as int),
        opcode == 42 || opcode == 43,
        bci + len < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), ctl),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost w0 = m.with(*r);
    proof { assert(outcome_ok(ap, p.cert@, sp::step(ap, g))); }
    let ghost m00 = *old(m);
    let ghost r00 = *old(r);
    // Inline in new space (no GC point): the registers stay.
    let wb = crate::alloc::bump_instance(m, env, c, Ghost(*r), Ghost(g));
    if wb != 0 {
        let ghost g1 = sp::alloc2(g, new_instance(ap, c as int));
        m.g = Ghost(g1);
        proof {
            assert(m.with(*r).refines(p));
            assert(m.rok(*r));
            assert(m.addr().len() == g1.heap.len());
        }
        let ctl = push_next(m, r, p, wb, len, Ghost(sp::new_ref2(g)));
        proof { crate::rops::lemma_rnext_post(p, m00, r00, *m, *r); }
        return ctl;
    }
    let len0 = m.len;
    m.sync(*r, &env.p);
    m.save();
    proof { lemma_saved(p, *m); }
    let (w, moved) = gc_allocate_instance(m, env, c, Ghost(g));
    let ghost o = new_instance(ap, c as int);
    let ghost g2 = choose|g2: State2| #[trigger] crate::alloc::gc_alloc_post(p, *m, g, g2, o, w, moved);
    if w != 0 && !moved {
        // Nothing moved (the heap's epoch is unchanged): the registers stay.
        let ghost g1 = sp::alloc2(g, new_instance(ap, c as int));
        proof { assert(reloaded(*m, g1) == (Machine { g: Ghost(g1), ..*m })); }
        m.g = Ghost(g1);
        proof {
            assert(m.with(*r) == *m);
            assert(m.rok(*r));
            assert(m.addr().len() == g1.heap.len());
        }
        let ctl = push_next(m, r, p, w, len, Ghost(sp::new_ref2(g)));
        proof { crate::rops::lemma_rnext_post(p, m00, r00, *m, *r); }
        return ctl;
    }
    if w == 0 {
        // Out of memory after the collections: the resource throw of
        // ALLOCATE (`prim::resource_throw`) in the collected state, the
        // out-of-memory error.
        let ghost wa = reloaded(*m, g2);
        proof {
            lemma_inv_gc(p, w0, wa);
            lemma_instr(ap, p.cert@, p.trusted@, g);
            let o1 = sp::unwind(ap, g2, Unwind::Throw(toit_spec::v2::prim::out_of_memory(ap)));
            assert(toit_spec::v2::prim::resource_throw(ap, g2, o1));
            lemma_source_resource(ap, g2, o1);
        }
        let (r2, ctl) = alloc_oom(m, *r, env, Ghost(g2), Ghost(wa));
        proof {
            if ctl == Ctl::Next {
                toit_spec::v2::gc::lemma_gc_steps_refl(ap, m.with(r2).g@);
                lemma_steps_post_gc(p, w0, wa, m.with(r2), m.with(r2), ctl);
            } else {
                toit_spec::v2::gc::lemma_gc_steps_refl(ap, m.g@);
                lemma_steps_post_gc(p, w0, wa, *m, *m, ctl);
            }
        }
        *r = r2;
        return ctl;
    }
    // Allocated after the collections: the step, then the collections.
    proof { toit_spec::v2::gc::lemma_gc_steps_shape(ap, g, g2); }
    let ghost g1 = sp::alloc2(g2, o);
    reload(m, p, Ghost(g1));
    proof { assert(m.addr().len() == g1.heap.len()); }
    let ctl = m.push_next(p, w, len, Ghost(sp::new_ref2(g2)));
    proof {
        toit_spec::v2::gc::lemma_gc_steps_shape(ap, g, g2);
        assert(g2.stack.subrange(0, g2.stack.len() - 0) =~= g2.stack);
        assert(g.stack.subrange(0, g.stack.len() - 0) =~= g.stack);
        assert(sp::step(ap, g) == Outcome2::Next(toit_spec::v2::gc::alloc_push(g, o, 0, len as int)));
        if ctl == Ctl::Next {
            assert(m.g@ == toit_spec::v2::gc::alloc_push(g2, o, 0, len as int));
        }
        lemma_alloc_gc(p, w0, *m, ctl, g2, o, 0, len as int);
    }
    if let Ctl::Next = ctl {
    } else {
        return ctl;
    }
    let ghost m1 = *m;
    match regain(m, env, len0, Ghost(w0)) {
        Some(r2) => {
            proof {
                toit_spec::v2::gc::lemma_gc_steps_refl(ap, w0.g@);
                lemma_step_post_gc(p, w0, w0, m1, m.with(r2), Ctl::Next);
            }
            *r = r2;
            Ctl::Next
        },
        None => Ctl::Stuck(stuck::LIMIT),
    }
}

/// ALLOCATE out of memory (cold): reloads the machine (state `g`) and
/// throws the out-of-memory error on it.
#[inline(never)]
fn alloc_oom(m: &mut Machine, r: Regs, env: &Env, Ghost(g): Ghost<State2>, Ghost(w0): Ghost<Machine>) -> (res: (Regs, Ctl))
    requires
        reloaded(*old(m), g).refines(&env.p),
        w0.inv(&env.p),
        w0.g@ == g,
        source(env.p.ap@, g, sp::unwind(env.p.ap@, g, Unwind::Throw(toit_spec::v2::prim::out_of_memory(env.p.ap@)))),
    ensures
        res.1 == Ctl::Next ==> final(m).rok(res.0) && crate::regs::ipok(&env.p, res.0) && steps_post(&env.p, w0, final(m).with(res.0), res.1)
            && room_ok(&env.p, final(m).with(res.0)) && crate::regs::gate_ok(&env.p, *final(m)),
        res.1 != Ctl::Next ==> steps_post(&env.p, w0, *final(m), res.1),
{
    reload(m, &env.p, Ghost(g));
    let c = crate::unwind::throw_oom(m, env);
    resume_r(m, r, env, c, false, Ghost(w0))
}

// ---------------------------------------------------------------------------
// PRIMITIVE.

/// A return (`spec::return_from`) with the result `w`, on the registers,
/// when the fast path of `rcalls::op_return` applies: no finally records,
/// not the task's bottom frame, the caller not suspended in a TRY. `false`
/// (nothing changed) otherwise.
#[inline(always)]
pub fn ret_r(m: &mut Machine, r: &mut Regs, p: &Program, w: usize, Ghost(v): Ghost<Value>) -> (b: bool)
    requires
        m_ok(p, *old(m), *old(r)),
        old(r).sp@ >= old(r).fr@ + old(m).fw + STACK_RESERVE,
        room_ok(p, old(m).with(*old(r))),
        shape_ok(p, old(m).g@),
        w == enc(old(m).addr(), v),
        encodable(old(m).addr(), v),
        !(sp::return_from(p.ap@, old(m).g@, v) is Stuck),
    ensures
        !b ==> *final(m) == *old(m) && *final(r) == *old(r),
        b ==> final(m).rok(*final(r)) && ipok(p, *final(r)) && final(m).with(*final(r)).refines(p) && gate_ok(p, *final(m))
            && sp::return_from(p.ap@, old(m).g@, v) == Outcome2::Next(final(m).g@)
            && room_ok(p, final(m).with(*final(r))),
{
    let ghost ap = p.ap@;
    let ghost g0 = m.g@;
    let ghost m0 = m.with(*r);
    proof {
        m0.lemma_frame(p);
        lemma_no_handler(g0);
    }
    if !m.bot.lt(r.fr, &m.mem) {
        // The task's bottom frame returns, or there are finally records.
        return false;
    }
    let ghost n = g0.frames.len() as int;
    proof {
        assert(m0.ftop == FRAME_WORDS * n);
        assert(n >= 2);
        lemma_rec_index(n, n - 2, FRAME_HANDLER);
        lemma_rec_index(n, n - 2, FRAME_METHOD);
        lemma_rec_index(n, n - 2, FRAME_BASE);
        lemma_rec_index(n, n - 1, FRAME_RET);
    }
    let crec = r.fr.offset(-((2 * FRAME_WORDS) as isize));
    let handler = crec.read(FRAME_HANDLER, &m.mem);
    if handler != 0 {
        // The caller is suspended in a TRY: its finally code runs.
        return false;
    }
    let rec_ = r.fr.offset(-(FRAME_WORDS as isize));
    let ret = rec_.read(FRAME_RET, &m.mem);
    let base = crec.read(FRAME_BASE, &m.mem);
    proof {
        assert(rec(m0.mem@, n - 1, FRAME_RET) == g0.frames[n - 1].ret);
        assert(rec(m0.mem@, n - 2, FRAME_METHOD) == g0.frames[n - 2].method);
        assert(rec(m0.mem@, n - 2, FRAME_BASE) == g0.frames[n - 2].base);
        assert(rec(m0.mem@, n - 2, FRAME_HANDLER) == handler);
        assert(toit_spec::v2::sound::base_step(g0, n - 2));
        lemma_frames_pop(m0.mem@, g0.frames, g0.tries);
        lemma_handler_word(m0.mem@, g0.frames.drop_last(), g0.tries);
        assert(g0.frames.drop_last()[n - 2] == g0.frames[n - 2]);
        assert(!sp::has_handler(State2 { frames: g0.frames.drop_last(), ..g0 }));
    }
    let s = r.fp.offset(-1);
    s.write(0, w, &mut m.mem);
    r.sp = s;
    r.fp = r.end.offset(-(base as isize));
    r.fr = rec_;
    r.ip = p.code.cursor(ret);
    let ghost g1 = State2 {
        stack: g0.stack.subrange(0, sp::top(g0).base as int).push(v),
        frames: g0.frames.drop_last(),
        fins: sp::fins_popped(g0),
        bci: sp::top(g0).ret,
        ..g0
    };
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        assert(g0.fins.len() == 0);
        assert(sp::fins_popped(g0) =~= g0.fins);
        assert(sp::base(g1) == g0.frames[n - 2].base);
        lemma_frames_pop(m0.mem@, g0.frames, g0.tries);
        assert forall|i: int| 0 <= i < FRAME_WORDS * g1.frames.len() implies #[trigger] m1.mem@[i] == m0.mem@[i] by {}
        lemma_frames_rel_same(m0.mem@, m1.mem@, g1.frames, g1.tries);
        let b = sp::top(g0).base as int;
        assert(m1.words() =~= m0.words().subrange(0, b).push(w));
        assert(enc_seq(m0.addr(), g1.stack) =~= enc_seq(m0.addr(), g0.stack).subrange(0, b).push(w));
        assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
            if i < b { assert(g1.stack[i] == g0.stack[i]); }
        }
        assert(m1.method < p.methods@.len()) by {
            assert(sp::valid_method(ap, g0.frames[n - 2].method as int));
        }
        assert(m1.refines(p));
        assert(sp::return_from(ap, g0, v) == Outcome2::Next(g1));
        assert forall|i: int| 0 <= i < g1.frames.len() implies #[trigger] frame_room(p, m1, i) by {
            assert(g1.frames[i] == g0.frames[i]);
            assert(frame_room(p, m0, i));
        }
    }
    true
}

/// PRIMITIVE module index (`spec::step`'s `Outcome2::Primitive`, completed
/// by the protocol): a Rust primitive on the registers, anything else on
/// the machine.
#[inline(always)]
pub fn op_primitive(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        opcode == 89,
        bci + 4 < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost w0 = m.with(*r);
    proof {
        lemma_instr(ap, p.cert@, p.trusted@, g);
        reveal_with_fuel(opcode_length2, 1);
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        w0.lemma_frame(p);
        lemma_shape(p, g);
    }
    let module = p.code.at(bci + 1);
    let index = code_u16(p, bci + 2) as u16;
    proof {
        assert(sp::step(ap, g) == Outcome2::Primitive(g, module, index)) by { reveal(sp::step); }
        crate::regs::lemma_method(p, w0);
    }
    // The method of the top frame: its frame record's.
    let method = r.fr.offset(-(FRAME_WORDS as isize)).read(FRAME_METHOD, &m.mem);
    proof {
        assert(method == w0.method);
        assert(ap.methods[method as int] == method_info(p.minfo(method as int), p.max_height));
    }
    let arity = p.method(method).arity as usize;
    // A core primitive the policy resolves to the VM's own entry with the
    // method's arity: its Rust port, if there is one.
    if let Some(c) = rust_primitive_r(m, r, env, module, index, arity) {
        return c;
    }
    // A C++ primitive (a GC point that may switch the task) or a missing
    // one; a Rust primitive that needs a GC calls its C++ primitive too.
    let (r2, c) = cxx_primitive_v(m, *r, env, module, index, arity);
    set_regs(r, r2);
    c
}

/// Calls the C++ primitive `(module, index)` of the process' policy
/// (`primitive::gc_call_primitive`) and completes the step: when the heap's
/// epoch is unchanged (nothing moved, the usual case) and the primitive
/// succeeded, its return on the registers, as for a Rust primitive;
/// everything else in `cxx_primitive_rest`. Out of line, the registers by
/// value. Only the Stack header is written before the call (what C++ and a
/// GC read); the machine's fields stay stale, the registers describe it,
/// so little lives across the call.
#[inline(never)]
pub fn cxx_primitive_v(m: &mut Machine, r: Regs, env: &Env, module: u8, index: u16, arity: usize) -> (res: (Regs, Ctl))
    requires
        rinv(&env.p, *old(m), r),
        r.sp@ >= r.fr@ + old(m).fw + STACK_RESERVE,
        step_ok(env.p.ap@, env.p.cert@, old(m).g@),
        sp::step(env.p.ap@, old(m).g@) == Outcome2::Primitive(old(m).g@, module, index),
        arity == sp::frame_height(old(m).g@),
        r.ip@ + 4 < 0x1000_0000,
        cur_op(env.p.ap@, old(m).g@) == 89,
    ensures rpost(&env.p, *old(m), r, *final(m), res.0, res.1),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost w0 = m.with(r);
    proof {
        w0.lemma_frame(p);
        crate::regs::lemma_bci(p, w0);
        lemma_shape(p, g);
    }
    m.save_r(&r, p);
    let ghost ms = *m;
    proof {
        assert(ms.with(r) == (Machine { mem: ms.mem, ..w0 }));
        assert(ms.with(r).refines(p));
        lemma_saved(p, ms.with(r));
        assert(reloaded(ms, g) == reloaded(ms.with(r), g));
    }
    let base = r.end.diff(r.fp);
    proof { assert(base == w0.base); }
    let (st, w, moved) = crate::primitive::gc_call_primitive(m, env, module, index, arity, base, Ghost(g));
    let ghost mc = *m;
    if !moved && st == V2_PRIMITIVE_SUCCESS {
        let ghost (g2, gx, v) = choose|g2: State2, gx: State2, v: Value| toit_spec::v2::gc::gc_steps(ap, g, g2)
            && #[trigger] crate::primitive::prim_call_post(p, *m, g2, module, index, st, w, gx, v)
            && (!moved ==> g2 == g && gx == with_heap2(g, gx.heap));
        proof {
            // Nothing moved: the reload derives the registers' machine.
            assert(reloaded(*m, gx) == (Machine { g: Ghost(gx), ..m.with(r) }));
        }
        m.g = Ghost(gx);
        proof {
            assert(m.with(r) == reloaded(*m, gx));
            assert(m.rok(r));
            lemma_room_same(p, w0, m.with(r));
        }
        let ghost o = prim_success(ap, g, gx.heap, v);
        proof {
            lemma_source_completion(ap, g, module, index, o);
            lemma_source_outcome(p, w0, o);
            crate::raise::lemma_shape_same(p, g, gx);
        }
        let mut r2 = r;
        if ret_r(m, &mut r2, p, w, Ghost(v)) {
            proof { lemma_outcome_matches(p, w0, m.with(r2), Ctl::Next, o); }
            return (r2, Ctl::Next);
        }
        m.g = Ghost(mc.g@);
        proof { assert(*m == mc); }
    } else if !moved && st == V2_PRIMITIVE_FAILURE {
        // A failure without a GC or a task switch (the task transfer to the
        // running task, the yield): the error pushed, on the registers.
        let ghost (g2, gx, v) = choose|g2: State2, gx: State2, v: Value| toit_spec::v2::gc::gc_steps(ap, g, g2)
            && #[trigger] crate::primitive::prim_call_post(p, *m, g2, module, index, st, w, gx, v)
            && (!moved ==> g2 == g && gx == with_heap2(g, gx.heap));
        proof {
            assert(reloaded(*m, gx) == (Machine { g: Ghost(gx), ..m.with(r) }));
        }
        m.g = Ghost(gx);
        proof {
            assert(m.with(r) == reloaded(*m, gx));
            assert(m.rok(r));
            lemma_room_same(p, w0, m.with(r));
        }
        let ghost o = sp::next(sp::push(gx, v), 4);
        proof {
            lemma_source_completion(ap, g, module, index, o);
            lemma_source_outcome(p, w0, o);
        }
        let mut r2 = r;
        let ctl = push_next(m, &mut r2, p, w, 4, Ghost(v));
        proof {
            lemma_outcome_matches(p, w0, m.with(r2), Ctl::Next, o);
            lemma_room_same(p, w0, m.with(r2));
        }
        return (r2, ctl);
    }
    cxx_primitive_rest(m, r, env, st, w, moved, module, index, Ghost(m0), Ghost(ms))
}

/// The rest of `cxx_primitive_v` after the call: a missing primitive, a
/// failure, a throw, anything after a GC or a task switch, and a return the
/// registers cannot do (in a TRY, with finally records, of the bottom
/// frame). Out of line: these paths keep the call's fast path lean.
#[inline(never)]
fn cxx_primitive_rest(m: &mut Machine, r: Regs, env: &Env, st: usize, w: usize, moved: bool,
    module: u8, index: u16, Ghost(m0): Ghost<Machine>, Ghost(ms): Ghost<Machine>) -> (res: (Regs, Ctl))
    requires
        rinv(&env.p, m0, r),
        r.sp@ >= r.fr@ + m0.fw + STACK_RESERVE,
        step_ok(env.p.ap@, env.p.cert@, m0.g@),
        sp::step(env.p.ap@, m0.g@) == Outcome2::Primitive(m0.g@, module, index),
        cur_op(env.p.ap@, m0.g@) == 89,
        r.ip@ + 4 < 0x1000_0000,
        ms == (Machine { mem: ms.mem, ..m0 }),
        ms.mem@ == m0.mem@,
        ms.mem.sid() == m0.mem.sid(),
        crate::alloc::saved(ms.with(r)),
        st == V2_PRIMITIVE_ABSENT ==> *old(m) == ms,
        st != V2_PRIMITIVE_ABSENT ==>
            exists|g2: State2, gx: State2, v: Value| toit_spec::v2::gc::gc_steps(env.p.ap@, m0.g@, g2)
                && #[trigger] crate::primitive::prim_call_post(&env.p, *old(m), g2, module, index, st, w, gx, v)
                && (!moved ==> g2 == m0.g@ && gx == with_heap2(m0.g@, gx.heap)),
        st != V2_PRIMITIVE_ABSENT && !moved ==> crate::primitive::unmoved(*old(m), ms),
    ensures rpost(&env.p, m0, r, *final(m), res.0, res.1),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m0.g@;
    let ghost w0 = m0.with(r);
    proof {
        w0.lemma_frame(p);
        crate::regs::lemma_bci(p, w0);
        lemma_shape(p, g);
        assert(ms.with(r) == (Machine { mem: ms.mem, ..w0 }));
        assert(ms.with(r).refines(p));
        lemma_saved(p, ms.with(r));
    }
    if st == V2_PRIMITIVE_ABSENT {
        m.sync(r, p);
        proof { assert(m.inv(p)); }
        let c = crate::primitive::op_prim_missing(m, env, module, index);
        return resume_r(m, r, env, c, false, Ghost(w0));
    }
    if !moved && (st == V2_PRIMITIVE_SUCCESS || st == V2_PRIMITIVE_FAILURE) {
        let ghost (g2, gx, v) = choose|g2: State2, gx: State2, v: Value| toit_spec::v2::gc::gc_steps(ap, g, g2)
            && #[trigger] crate::primitive::prim_call_post(p, *m, g2, module, index, st, w, gx, v)
            && (!moved ==> g2 == g && gx == with_heap2(g, gx.heap));
        proof {
            // Nothing moved: the reload derives the registers' machine.
            assert(reloaded(*m, gx) == (Machine { g: Ghost(gx), ..m.with(r) }));
        }
        m.g = Ghost(gx);
        proof {
            assert(m.with(r) == reloaded(*m, gx));
            assert(m.rok(r));
            lemma_room_same(p, w0, m.with(r));
        }
        if st == V2_PRIMITIVE_SUCCESS {
            let ghost o = prim_success(ap, g, gx.heap, v);
            proof {
                lemma_source_completion(ap, g, module, index, o);
                lemma_source_outcome(p, w0, o);
                crate::raise::lemma_shape_same(p, g, gx);
            }
            let mut r2 = r;
            if ret_r(m, &mut r2, p, w, Ghost(v)) {
                proof { lemma_outcome_matches(p, w0, m.with(r2), Ctl::Next, o); }
                return (r2, Ctl::Next);
            }
            // A return in a TRY, with finally records, or of the bottom
            // frame: on the machine.
            m.sync_b(r2, p);
            proof { assert(m.len == w0.len); }
            let c = m.do_return(env, w, Ghost(v));
            proof { lemma_outcome_matches(p, w0, *m, c, o); }
            let ok = ret_room_kept(m, env, &c, Ghost(w0), Ghost(State2 { heap: gx.heap, ..g }), Ghost(v));
            return resume_r(m, r2, env, c, ok, Ghost(w0));
        }
        let ghost o = sp::next(sp::push(gx, v), 4);
        proof {
            lemma_source_completion(ap, g, module, index, o);
            lemma_source_outcome(p, w0, o);
        }
        let mut r2 = r;
        let ctl = push_next(m, &mut r2, p, w, 4, Ghost(v));
        proof {
            lemma_outcome_matches(p, w0, m.with(r2), Ctl::Next, o);
            lemma_room_same(p, w0, m.with(r2));
        }
        return (r2, ctl);
    }
    let c = crate::primitive::prim_cxx_complete(m, env, st, w, Ghost(g), Ghost(w0), Ghost(module), Ghost(index));
    resume_r(m, r, env, c, false, Ghost(w0))
}

/// Runs the Rust port of core primitive `index` (`prims::call`) on the
/// frame's parameters, where the policy resolves the primitive to the VM's
/// own entry with the method's arity (`Env::core_arities`), and completes
/// the step as the protocol says (as `primitive::op_rust_primitive`), on the
/// registers. `None` (nothing changed) when the policy does not, there is no
/// port for these arguments or an allocation did not fit: then
/// `op_primitive` calls the C++ primitive, and only then.
///
/// The ports of `prims::never_falls_back` never give `None` where the
/// policy resolves them: for such a primitive the C++ primitive does not
/// run. The method's arity, which the port is called with, is the arity the
/// verifier's primitive table (`cert.prim_arity`) gives the primitive.
#[inline(always)]
fn rust_primitive_r(m: &mut Machine, r: &mut Regs, env: &Env, module: u8, index: u16, arity: usize) -> (res: Option<Ctl>)
    requires
        rinv(&env.p, *old(m), *old(r)),
        old(r).sp@ >= old(r).fr@ + old(m).fw + STACK_RESERVE,
        step_ok(env.p.ap@, env.p.cert@, old(m).g@),
        cur_op(env.p.ap@, old(m).g@) == 89,
        sp::step(env.p.ap@, old(m).g@) == Outcome2::Primitive(old(m).g@, module, index),
        arity == sp::frame_height(old(m).g@),
        old(r).ip@ + 4 < 0x1000_0000,
    ensures
        res is None ==> *final(m) == *old(m) && *final(r) == *old(r),
        res matches Some(c) ==> rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
        // The method's arity is the verifier's arity of the primitive.
        (module as int) < env.p.cert@.prim_arity.len()
            && (index as int) < env.p.cert@.prim_arity[module as int].len()
            && env.p.cert@.prim_arity[module as int][index as int] == arity as int,
        // A port that never falls back completes the step: no C++ primitive.
        module == 0 && (index as int) < env.core_arities@.len()
            && env.core_arities@[index as int] as int == arity + 1
            && prims::never_falls_back(index as int, arity as int) ==> res is Some,
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost w0 = m.with(*r);
    let ghost vs = prim_args(ap, g);
    proof {
        w0.lemma_frame(p);
        lemma_prim_arity(p, w0, module, index, arity);
    }
    if !(module == 0 && (index as usize) < env.core_arities.len()
        && env.core_arities.at(index as usize) as usize == arity + 1) {
        return None;
    }
    proof {
        crate::regs::lemma_bci(p, w0);
        lemma_rust_args(p, w0, arity);
        lemma_shape(p, g);
    }
    let fpi = m.mem.index(r.fp);
    let at = if fpi > 0 { fpi - 1 } else { 0 };
    proof { assert(at == args_at(w0)); }
    let al = env.rt.allocator();
    let (res, v) = prims::call(0, index, &m.mem, at, arity, &mut m.heap, p, &al, Ghost(norm_args(vs)));
    match res {
        PrimOutcome::Success(w) => {
            let ghost h2 = m.heap.objs();
            m.g = Ghost(with_heap2(g, h2));
            let ghost o = prim_success(ap, g, h2, v@);
            proof {
                lemma_refines_heap(p, w0, m.with(*r));
                lemma_completion(p, g, index, h2, PrimRet::Success(v@), vs);
                crate::raise::lemma_shape_same(p, g, m.g@);
                lemma_source_completion(ap, g, 0, index, o);
                lemma_source_outcome(p, w0, o);
                lemma_room_same(p, w0, m.with(*r));
            }
            if ret_r(m, r, p, w, Ghost(v@)) {
                proof { lemma_outcome_matches(p, w0, m.with(*r), Ctl::Next, o); }
                return Some(Ctl::Next);
            }
            // A return in a TRY, with finally records, or of the bottom
            // frame: on the machine.
            m.sync_b(*r, p);
            proof { assert(m.len == w0.len); }
            let c = m.do_return(env, w, Ghost(v@));
            proof { lemma_outcome_matches(p, w0, *m, c, o); }
            let ok = ret_room_kept(m, env, &c, Ghost(w0), Ghost(State2 { heap: h2, ..g }), Ghost(v@));
            let (r2, c2) = resume_r(m, *r, env, c, ok, Ghost(w0));
            *r = r2;
            Some(c2)
        },
        PrimOutcome::Failure(w) => {
            let ghost h2 = m.heap.objs();
            m.g = Ghost(with_heap2(g, h2));
            let ghost o = sp::next(sp::push(with_heap2(g, h2), v@), 4);
            proof {
                lemma_refines_heap(p, w0, m.with(*r));
                lemma_completion(p, g, index, h2, PrimRet::Failure(v@), vs);
                lemma_source_completion(ap, g, 0, index, o);
                lemma_source_outcome(p, w0, o);
            }
            let ctl = push_next(m, r, p, w, 4, Ghost(v@));
            proof {
                lemma_outcome_matches(p, w0, m.with(*r), Ctl::Next, o);
                lemma_room_same(p, w0, m.with(*r));
            }
            Some(ctl)
        },
        _ => None,
    }
}

/// The arity of a PRIMITIVE's method, its frame height, is the arity the
/// verifier's primitive table gives the primitive.
proof fn lemma_prim_arity(p: &Program, m: Machine, module: u8, index: u16, arity: usize)
    requires
        m.inv(p),
        cur_op(p.ap@, m.g@) == 89,
        sp::step(p.ap@, m.g@) == Outcome2::Primitive(m.g@, module, index),
        arity == sp::frame_height(m.g@),
    ensures
        (module as int) < p.cert@.prim_arity.len()
            && (index as int) < p.cert@.prim_arity[module as int].len()
            && p.cert@.prim_arity[module as int][index as int] == arity as int,
{
    let ap = p.ap@;
    let g = m.g@;
    reveal(wf);
    toit_spec::v2::sound_prim::lemma_prim_facts(ap, p.cert@, p.trusted@, g);
    toit_spec::v2::sound_instr::lemma_instr(ap, p.cert@, p.trusted@, g);
    reveal(sp::step);
    assert(module == ap.bytecodes[g.bci + 1]);
    assert(index as int == u16_at(p1(ap), g.bci + 2));
}

} // verus!
