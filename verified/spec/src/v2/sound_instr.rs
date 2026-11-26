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

//! The facts every per-opcode lemma starts from: the instruction at the
//! bci of a well-formed state is the accepted instruction of the top
//! frame's map, and the top frame's slots conform to that map.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::bytecodes::*;
use crate::v2::verifier::*;
use crate::v2::sound::*;
use crate::v2::sound_local::*;
#[cfg(verus_only)]
use crate::spec_common::{u16_at, u32_at};

verus! {

/// The top frame's method, offset and kinds of a state.
pub open spec fn cur_m(s: State2) -> int {
    fmethod(s, top_i(s))
}

pub open spec fn cur_off(p: Program2, s: State2) -> int {
    foff(p, s, top_i(s))
}

pub open spec fn cur_k(p: Program2, c: Cert, s: State2) -> Seq<Kind> {
    kinds_of(p, c, s, top_i(s))
}

pub open spec fn cur_b(s: State2) -> int {
    fbase(s, top_i(s))
}

// ---------------------------------------------------------------------------
// The opcode families of the per-opcode lemmas (they cover 0..=100).

/// Locals, constants, globals (not lazy), POP, ALLOCATE, type checks,
/// IDENTICAL, branches, HALT.
pub open spec fn fam_local(op: u8) -> bool {
    op <= 4 || (14 <= op && op <= 31) || (34 <= op && op <= 37) || (40 <= op && op <= 52)
        || (81 <= op && op <= 88) || op == 96 || op == 100 || op == 101 || op == 102 || op == 103
        || (114 <= op && op <= 118)
}

/// Field access.
pub open spec fn fam_field(op: u8) -> bool {
    (7 <= op && op <= 13) || op == 94 || op == 98
}

/// LOAD_OUTER, STORE_OUTER, LOAD_BLOCK, LOAD_OUTER_BLOCK.
pub open spec fn fam_block(op: u8) -> bool {
    op == 5 || op == 6 || op == 38 || op == 39
}

/// Lazy globals, INVOKE_STATIC, INVOKE_BLOCK, TRY.
pub open spec fn fam_call(op: u8) -> bool {
    op == 32 || op == 33 || op == 53 || op == 55 || op == 97
}

/// Virtual calls and operators.
pub open spec fn fam_virtual(op: u8) -> bool {
    58 <= op && op <= 80
}

/// Tail calls.
pub open spec fn fam_tail(op: u8) -> bool {
    op == 54 || op == 56 || op == 57
}

/// THROW, RETURN, RETURN_NULL, NON_LOCAL_RETURN, NON_LOCAL_BRANCH, UNWIND.
pub open spec fn fam_unwind(op: u8) -> bool {
    (90 <= op && op <= 93) || op == 95 || op == 99
}

/// PRIMITIVE.
pub open spec fn fam_prim(op: u8) -> bool {
    op == 89
}

pub proof fn lemma_families(op: u8)
    requires op < OPCODE_COUNT2, !is_twin(op),
    ensures fam_local(op) || fam_field(op) || fam_block(op) || fam_call(op) || fam_virtual(op)
        || fam_tail(op) || fam_unwind(op) || fam_prim(op),
{}

/// The instruction at the bci of a well-formed state.
pub proof fn lemma_instr(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s),
    ensures ({
        let m = cur_m(s);
        let off = cur_off(p, s);
        let k = cur_k(p, c, s);
        let len = opcode_length2(cur_op(p, s));
        &&& s.frames.len() > 0
        &&& valid_method(p, m)
        &&& !dead_block(p, c, m)
        &&& top(s).method as int == m
        &&& top_index(s) == top_i(s)
        &&& base(s) == cur_b(s)
        &&& 0 <= cur_b(s) <= s.stack.len()
        &&& frame_height(s) == k.len()
        &&& slots(s, top_i(s)) == k.len()
        &&& s.bci as int == instr_at(p, m, off)
        &&& 0 <= off
        &&& cur_op(p, s) == op_of(p, m, off)
        &&& map_at(c, m, off) == Some(k)
        &&& instr_ok(p, c, m, off, k, trusted)
        &&& wf_kinds(p, c, m, k)
        &&& ctx_ok(p, c, m, k)
        &&& shape_ok(p, c, m, k)
        &&& instruction_ok(p, s)
        &&& 1 <= len <= 6
        &&& s.bci + len <= info(p, m).end <= p.bytecodes.len()
        &&& p.bytecodes.len() < 0x1000_0000
        &&& (len >= 2 ==> byte2(p, s.bci + 1) == b1_of(p, m, off))
        &&& (len >= 3 ==> u16_at(p1(p), s.bci + 1) == w1_of(p, m, off))
        &&& frame_ok(p, c, s, top_i(s))
        &&& heap_ok(p, c, s.heap)
        &&& globals_ok(c, s)
        &&& consts_ok(p, s.heap)
        &&& wf_task(p, c, s)
        &&& tables_ok(p, c)
        &&& crate::v2::exec::wf_program2(p)
    }),
{
    let t = top_i(s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    lemma_wf_parts(p, c, s);
    lemma_task_basics(p, c, s);
    lemma_top_kinds(p, c, s);
    lemma_map_instr(p, c, trusted, m, off);
    lemma_map_bound(p, c, trusted, m, off);
    assert(frame_ok(p, c, s, t)) by { reveal(wf_task); }
    lemma_base_op(p.bytecodes[s.bci as int]);
    let op = cur_op(p, s);
    assert(op < OPCODE_COUNT2);
    assert(1 <= opcode_length2(op) <= 6) by {
        reveal_with_fuel(opcode_length2, 1);
    }
}

/// The unchecked twins at the bci of a well-formed state (format note 20):
/// `cur_op` is a base opcode, a twin's byte occurs only in the unchecked
/// mode, and has its base's length.
pub proof fn lemma_instr_twin(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s),
    ensures
        !is_twin(cur_op(p, s)),
        is_twin(p.bytecodes[s.bci as int]) ==> p.unchecked,
        opcode_length2(p.bytecodes[s.bci as int]) == opcode_length2(cur_op(p, s)),
{
    lemma_instr(p, c, trusted, s);
    lemma_base_op(p.bytecodes[s.bci as int]);
}

/// The value in slot `n` from the top of the top frame conforms to its
/// kind.
pub proof fn lemma_at_conf(p: Program2, c: Cert, trusted: bool, s: State2, n: int)
    requires accepts(p, c, trusted), wf(p, c, s), 0 <= n < cur_k(p, c, s).len(),
    ensures ({
        let k = cur_k(p, c, s);
        let j = k.len() - 1 - n;
        &&& has_slot(s, n)
        &&& at(s, n) == s.stack[cur_b(s) + j]
        &&& conf(p, c, s, top_i(s), k, j, top_kind(k, n), at(s, n))
    }),
{
    lemma_instr(p, c, trusted, s);
    let t = top_i(s);
    let k = cur_k(p, c, s);
    let j = k.len() - 1 - n;
    reveal(frame_ok);
    assert(frame_conf(p, c, s, t));
    assert(conf(p, c, s, t, k, j, k[j], s.stack[fbase(s, t) + j]));
}

/// A value kind conforms only with values.
pub proof fn lemma_val_good(p: Program2, c: Cert, s: State2, fi: int, kf: Seq<Kind>, j: int, k: Kind, v: Value)
    requires conf(p, c, s, fi, kf, j, k, v), is_val(k),
    ensures good(s.heap, v), v is Smi || v is Obj,
{
    reveal(conf);
}

/// The value in slot `n` from the top is a value when its kind is.
pub proof fn lemma_at_good(p: Program2, c: Cert, trusted: bool, s: State2, n: int)
    requires accepts(p, c, trusted), wf(p, c, s), 0 <= n < cur_k(p, c, s).len(),
        is_val(top_kind(cur_k(p, c, s), n)),
    ensures has_slot(s, n), good(s.heap, at(s, n)), at(s, n) is Smi || at(s, n) is Obj,
{
    lemma_at_conf(p, c, trusted, s, n);
    let k = cur_k(p, c, s);
    lemma_val_good(p, c, s, top_i(s), k, k.len() - 1 - n, top_kind(k, n), at(s, n));
}

} // verus!
