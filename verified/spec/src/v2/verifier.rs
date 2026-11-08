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

//! The structural verifier of format 2, as spec functions, and the
//! statement of its soundness theorem (Phase 3 proves it).
//!
//! The verifier checks a *certificate*: for every method, the kinds of the
//! frame's slots at every instruction (a stack map), the set of block
//! parameters, and for every block method the context it is created in.
//! A certificate can be computed by abstract interpretation (the Phase 3
//! implementation does that, in one pass per method thanks to the block
//! masks and contexts) or shipped with the program; the checks below are
//! local to an instruction and its successors.
//!
//! What the verifier proves, and what format 2 checks at run time instead,
//! is listed in `format/README.md`. In short, the verifier proves stack
//! discipline (heights, frame bounds, no slot below the frame base), block
//! references (never dangling, never stored in the heap, returned or
//! compared), the shape of try/finally (tokens), branch targets,
//! terminators, the unchecked `this` field accesses, and the tables; the
//! machine checks everything that comes from the heap (method ids of
//! lambdas and initializers, block slots, field receivers, dynamic global
//! indices, captured values) and raises an exception when it fails.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::bytecodes::*;
#[cfg(verus_only)]
use crate::spec_common::{instance_field_count, u16_at, u32_at, is_string, class_tag, INSTANCE_TAG};

verus! {

// ---------------------------------------------------------------------------
// Abstract kinds and certificates.

/// The kind of a slot of a frame.
pub enum Kind {
    /// A smi or an object reference.
    Val,
    /// The method id `m` (a smi), pushed by LOAD_METHOD; the slot of a block.
    Method(int),
    /// A block reference to slot `slot` (frame-relative) of the frame
    /// `depth` contexts out: 0 is the current frame, 1 the frame the
    /// current block was created in, and so on.
    Block(int, int),
    /// A block reference received as a parameter (not the block's own):
    /// its frame is below the current one; it can only be invoked, passed
    /// on as a block argument, or used for a non-local return or branch is
    /// not allowed (its target is unknown).
    Param,
    /// The unwinding token of a finally code.
    Token,
}

/// Where a block method is created: by LOAD_METHOD (followed by LOAD_BLOCK)
/// or TRY in method `outer`, in frame slot `slot`; `kinds` are the kinds of
/// the outer frame's slots `0..=slot` at that point (`kinds[slot]` is
/// `Method(m)`), with every slot the outer code may still change while the
/// block is alive demoted to `Val`.
pub struct Context {
    pub outer: int,
    pub slot: int,
    pub kinds: Seq<Kind>,
}

pub struct Cert {
    /// `maps[m][i]`: the kinds of the frame's slots (bottom first) at the
    /// instruction at offset `i` of method `m`. Every instruction start
    /// that can be reached has an entry; no other offset does.
    pub maps: Seq<Map<int, Seq<Kind>>>,
    /// The parameters of each method that are blocks (P7's mask).
    pub block_params: Seq<Set<int>>,
    /// The creation context of each block method.
    pub contexts: Seq<Option<Context>>,
}

pub open spec fn kind_method(k: Kind) -> int {
    match k { Kind::Method(t) => t, _ => -1 }
}

/// The frame-relative slot of a block reference of the current frame, or -1.
pub open spec fn local_block(k: Kind) -> int {
    match k { Kind::Block(d, s) => if d == 0 { s } else { -1 }, _ => -1 }
}

/// A block reference to a frame below the current one (the target of a
/// non-local return).
pub open spec fn outer_block(k: Kind) -> bool {
    match k { Kind::Block(d, s) => d >= 1, _ => false }
}

/// The kind is the method id of a block method.
pub open spec fn block_method_kind(p: Program2, k: Kind) -> bool {
    k is Method && valid_method(p, kind_method(k)) && info(p, kind_method(k)).kind == KIND_BLOCK
}

pub open spec fn is_value_kind(k: Kind) -> bool {
    k is Val || k is Method
}

pub open spec fn is_block_kind(k: Kind) -> bool {
    k is Block || k is Param
}

/// Kind `n` slots below the top.
pub open spec fn top_kind(k: Seq<Kind>, n: int) -> Kind {
    k[k.len() - 1 - n]
}

pub open spec fn instr_at(p: Program2, m: int, off: int) -> int {
    info(p, m).entry + off
}

pub open spec fn op_of(p: Program2, m: int, off: int) -> u8 {
    p.bytecodes[instr_at(p, m, off)]
}

pub open spec fn len_of(p: Program2, m: int, off: int) -> int {
    opcode_length2(op_of(p, m, off))
}

pub open spec fn b1_of(p: Program2, m: int, off: int) -> int {
    p.bytecodes[instr_at(p, m, off) + 1] as int
}

pub open spec fn w1_of(p: Program2, m: int, off: int) -> int {
    u16_at(p1(p), instr_at(p, m, off) + 1)
}

// ---------------------------------------------------------------------------
// Contexts: the frames a block's references reach.

/// The kinds of the frame `depth` contexts out from method `m`.
pub open spec fn context_kinds(c: Cert, m: int, depth: nat) -> Option<Seq<Kind>>
    decreases depth,
{
    if depth == 0 {
        None
    } else if !(0 <= m < c.contexts.len()) {
        None
    } else {
        match c.contexts[m] {
            None => None,
            Some(ctx) => if depth == 1 { Some(ctx.kinds) } else { context_kinds(c, ctx.outer, (depth - 1) as nat) },
        }
    }
}

/// The method of the frame `depth` contexts out.
pub open spec fn context_method(c: Cert, m: int, depth: nat) -> int
    decreases depth,
{
    if depth == 0 || !(0 <= m < c.contexts.len()) {
        m
    } else {
        match c.contexts[m] {
            None => -1,
            Some(ctx) => context_method(c, ctx.outer, (depth - 1) as nat),
        }
    }
}

/// The kinds of the slots of the frame a block reference of kind
/// `Block(depth, _)` points into, seen from method `m` with current kinds
/// `k`.
pub open spec fn frame_kinds(c: Cert, m: int, k: Seq<Kind>, depth: int) -> Option<Seq<Kind>> {
    if depth == 0 { Some(k) } else if depth > 0 { context_kinds(c, m, depth as nat) } else { None }
}

/// A slot of an outer frame read through LOAD_OUTER, seen from here: block
/// references of that frame are `depth` contexts further out.
pub open spec fn shift(k: Kind, depth: int) -> Kind {
    match k {
        Kind::Block(d, s) => Kind::Block(d + depth, s),
        Kind::Method(_) => Kind::Val,
        _ => k,
    }
}

// ---------------------------------------------------------------------------
// Well-formed abstract frames.

/// Block references of the current frame point to block slots below them;
/// tokens only appear where a finally code put them.
pub open spec fn wf_kinds(p: Program2, k: Seq<Kind>) -> bool {
    forall|j: int| 0 <= j < k.len() ==> match #[trigger] k[j] {
        Kind::Block(d, i) => d >= 0 && (d == 0 ==> 0 <= i < j && block_method_kind(p, k[i])),
        _ => true,
    }
}

/// Slot `i` of the current frame is the target of a live block reference.
pub open spec fn referenced(k: Seq<Kind>, i: int) -> bool {
    exists|j: int| 0 <= j < k.len() && #[trigger] k[j] == Kind::Block(0, i)
}

/// The kinds at the entry of method `m`.
pub open spec fn entry_kinds(p: Program2, c: Cert, m: int) -> Seq<Kind> {
    let a = arity(p, m);
    if info(p, m).kind == KIND_BLOCK {
        Seq::new(a as nat, |i: int| if i == 0 {
            match c.contexts[m] { Some(ctx) => Kind::Block(1, ctx.slot), None => Kind::Param }
        } else { Kind::Val })
    } else {
        Seq::new(a as nat, |i: int| if c.block_params[m].contains(i) { Kind::Param } else { Kind::Val })
    }
}

/// The arguments on top of `k` fit the parameters of `t`.
pub open spec fn args_ok(c: Cert, t: int, k: Seq<Kind>, n: int) -> bool {
    &&& 0 <= n <= k.len()
    &&& forall|i: int| 0 <= i < n ==> {
        let kind = #[trigger] k[k.len() - n + i];
        if c.block_params[t].contains(i) { is_block_kind(kind) } else { is_value_kind(kind) }
    }
}

/// The kinds after popping `n` slots and pushing a value: no reference to a
/// popped block slot may survive.
pub open spec fn pop_push(k: Seq<Kind>, n: int, top: Option<Kind>) -> Seq<Kind> {
    let k1 = k.subrange(0, k.len() - n);
    match top { Some(t) => k1.push(t), None => k1 }
}

pub open spec fn no_dangling(k: Seq<Kind>) -> bool {
    forall|j: int| 0 <= j < k.len() ==> match #[trigger] k[j] {
        Kind::Block(d, i) => d == 0 ==> i < k.len(),
        _ => true,
    }
}

/// A slot may be overwritten: it is not `this` of a method that relies on
/// it, not a referenced block slot, and not a token.
pub open spec fn writable(p: Program2, m: int, k: Seq<Kind>, i: int) -> bool {
    &&& 0 <= i < k.len()
    &&& !(i == 0 && has_receiver_range(info(p, m)))
    &&& !referenced(k, i)
    &&& !(k[i] is Token)
}

// ---------------------------------------------------------------------------
// The instruction rules. `post` is the kinds at the next instruction (for
// instructions that continue there); `None` means the instruction is
// rejected.

pub open spec fn sel_ok(p: Program2, c: Cert, sel: int, n: int, k: Seq<Kind>) -> bool {
    // Every method the dispatch table can find for `sel` has arity `n` and
    // the same block parameters (`tables_ok`), so checking against any one
    // of them suffices; `selector_arity` names them.
    &&& selector_arity(p, sel) == n
    &&& args_ok(c, selector_method(p, sel), k, n)
}

/// One method with selector offset `sel` (the table check makes them agree).
pub open spec fn selector_method(p: Program2, sel: int) -> int {
    if exists|m: int| valid_method(p, m) && info(p, m).selector as int == sel {
        choose|m: int| valid_method(p, m) && info(p, m).selector as int == sel
    } else {
        -1
    }
}

pub open spec fn selector_arity(p: Program2, sel: int) -> int {
    let m = selector_method(p, sel);
    if m < 0 { -1 } else { arity(p, m) }
}

pub open spec fn value_operands(k: Seq<Kind>, n: int) -> bool {
    n <= k.len() && forall|i: int| 0 <= i < n ==> is_value_kind(#[trigger] top_kind(k, i))
}

/// The fall-through successor kinds of a non-branching instruction.
pub open spec fn post(p: Program2, c: Cert, m: int, off: int, k: Seq<Kind>) -> Option<Seq<Kind>> {
    let op = op_of(p, m, off);
    let b1 = b1_of(p, m, off);
    let w1 = w1_of(p, m, off);
    let h = k.len() as int;
    if op == LOAD_LOCAL || op == LOAD_LOCAL_WIDE || (LOAD_LOCAL_0 <= op && op <= LOAD_LOCAL_5) {
        let n = if op == LOAD_LOCAL { b1 } else if op == LOAD_LOCAL_WIDE { w1 } else { op - LOAD_LOCAL_0 };
        if n < h && !(top_kind(k, n) is Token) { Some(k.push(top_kind(k, n))) } else { None }
    } else if op == POP_LOAD_LOCAL {
        if b1 + 1 < h && !(top_kind(k, b1 + 1) is Token) && writable(p, m, k, h - 1) {
            Some(k.update(h - 1, top_kind(k, b1 + 1)))
        } else { None }
    } else if op == STORE_LOCAL || op == STORE_LOCAL_POP {
        let i = h - 1 - b1;
        let pop = op == STORE_LOCAL_POP;
        if (pop && b1 < 1) || !(0 <= i < h - 1) || !writable(p, m, k, i) || top_kind(k, 0) is Token
            || (top_kind(k, 0) is Block && !(0 <= local_block(top_kind(k, 0)) < i)) {
            None
        } else {
            let k1 = k.update(i, top_kind(k, 0));
            Some(if pop { k1.drop_last() } else { k1 })
        }
    } else if op == LOAD_OUTER || op == STORE_OUTER || op == LOAD_OUTER_BLOCK {
        let r = if op == STORE_OUTER { 1int } else { 0int };
        if r >= h { None } else {
            match top_kind(k, r) {
                Kind::Block(d, j) => match frame_kinds(c, m, k, d) {
                    None => None,
                    Some(fk) => {
                        let i = j - b1;
                        if !(0 <= i <= j < fk.len()) {
                            None
                        } else if op == LOAD_OUTER {
                            if fk[i] is Token { None } else { Some(k.update(h - 1, shift(fk[i], d))) }
                        } else if op == LOAD_OUTER_BLOCK {
                            if block_method_kind(p, fk[i]) {
                                Some(k.update(h - 1, Kind::Block(d, i)))
                            } else { None }
                        } else {
                            // STORE_OUTER: only into a plain value slot of an outer frame.
                            if d >= 1 && fk[i] is Val && is_value_kind(top_kind(k, 0)) {
                                Some(pop_push(k, 2, Some(Kind::Val)))
                            } else { None }
                        }
                    },
                },
                _ => None,
            }
        }
    } else if op == LOAD_BLOCK {
        let i = h - 1 - b1;
        if 0 <= i < h && block_method_kind(p, k[i]) {
            Some(k.push(Kind::Block(0, i)))
        } else { None }
    } else if op == LOAD_FIELD || op == LOAD_FIELD_WIDE {
        if value_operands(k, 1) { Some(k.update(h - 1, Kind::Val)) } else { None }
    } else if op == LOAD_FIELD_LOCAL || op == POP_LOAD_FIELD_LOCAL {
        let slot = if op == POP_LOAD_FIELD_LOCAL { b1 % 16 + 1 } else { b1 % 16 };
        if slot < h && is_value_kind(top_kind(k, slot)) && (op == LOAD_FIELD_LOCAL || writable(p, m, k, h - 1)) {
            Some(if op == LOAD_FIELD_LOCAL { k.push(Kind::Val) } else { k.update(h - 1, Kind::Val) })
        } else { None }
    } else if op == STORE_FIELD || op == STORE_FIELD_WIDE || op == STORE_FIELD_POP {
        if value_operands(k, 2) {
            Some(if op == STORE_FIELD_POP { pop_push(k, 2, None) } else { pop_push(k, 2, Some(Kind::Val)) })
        } else { None }
    } else if op == LOAD_FIELD_THIS || op == STORE_FIELD_THIS {
        // Every class of the receiver range has the field; `this` is never
        // overwritten (`writable`).
        if !this_field_ok(p, m, b1) || (op == STORE_FIELD_THIS && !value_operands(k, 1)) {
            None
        } else {
            Some(if op == LOAD_FIELD_THIS { k.push(Kind::Val) } else { k })
        }
    } else if op == LOAD_LITERAL || op == LOAD_LITERAL_WIDE {
        if (if op == LOAD_LITERAL { b1 } else { w1 }) < p.literals.len() { Some(k.push(Kind::Val)) } else { None }
    } else if op == LOAD_NULL || op == LOAD_SMI_0 || op == LOAD_SMI_1 || op == LOAD_SMI_U8 || op == LOAD_SMI_U16 {
        Some(k.push(Kind::Val))
    } else if op == LOAD_SMI_U32 {
        if u32_at(p1(p), instr_at(p, m, off) + 1) < 0x4000_0000 { Some(k.push(Kind::Val)) } else { None }
    } else if op == LOAD_SMIS_0 {
        Some(k + Seq::new(b1 as nat, |i: int| Kind::Val))
    } else if op == LOAD_METHOD {
        let t = u32_at(p1(p), instr_at(p, m, off) + 1);
        if valid_method(p, t) && t < 0x4000_0000 { Some(k.push(Kind::Method(t))) } else { None }
    } else if op == LOAD_GLOBAL_VAR || op == LOAD_GLOBAL_VAR_WIDE || op == LOAD_GLOBAL_VAR_LAZY || op == LOAD_GLOBAL_VAR_LAZY_WIDE {
        // The global count is checked against the program's initial globals.
        Some(k.push(Kind::Val))
    } else if op == STORE_GLOBAL_VAR || op == STORE_GLOBAL_VAR_WIDE {
        if value_operands(k, 1) { Some(k) } else { None }
    } else if op == LOAD_GLOBAL_VAR_DYNAMIC {
        if value_operands(k, 1) { Some(k.update(h - 1, Kind::Val)) } else { None }
    } else if op == STORE_GLOBAL_VAR_DYNAMIC {
        if value_operands(k, 2) { Some(pop_push(k, 2, None)) } else { None }
    } else if op == POP || op == POP_1 {
        let n = if op == POP { b1 } else { 1 };
        if n <= h && no_dangling(k.subrange(0, h - n)) {
            Some(k.subrange(0, h - n))
        } else { None }
    } else if op == ALLOCATE || op == ALLOCATE_WIDE {
        let cl = if op == ALLOCATE { b1 } else { w1 };
        if 0 <= cl < p.class_bits.len() && class_tag(p1(p), cl) == INSTANCE_TAG && instance_field_count(p1(p), cl) >= 0 {
            Some(k.push(Kind::Val))
        } else { None }
    } else if IS_CLASS <= op && op <= AS_INTERFACE_WIDE {
        if value_operands(k, 1) && typecheck_index_ok(p, op, if op % 2 == 0 { b1 } else { w1 }) {
            Some(if op <= IS_INTERFACE_WIDE { k.update(h - 1, Kind::Val) } else { k })
        } else { None }
    } else if op == AS_LOCAL {
        if b1 / 32 < h && is_value_kind(top_kind(k, b1 / 32)) && 2 * (b1 % 32) + 1 < p.class_check_ids.len() { Some(k) } else { None }
    } else if op == INVOKE_STATIC {
        let t = dispatch_target(p, w1);
        if valid_method(p, t) && arity(p, t) <= h && args_ok(c, t, k, arity(p, t))
            && no_dangling(k.subrange(0, h - arity(p, t))) {
            Some(pop_push(k, arity(p, t), Some(Kind::Val)))
        } else { None }
    } else if op == INVOKE_BLOCK {
        if !(1 <= b1 <= h) || !is_block_kind(top_kind(k, b1 - 1)) || !value_operands(k, b1 - 1) {
            None
        } else { Some(pop_push(k, b1, Some(Kind::Val))) }
    } else if op == INVOKE_VIRTUAL || op == INVOKE_VIRTUAL_WIDE {
        let n = if op == INVOKE_VIRTUAL { b1 + 1 } else { w1 + 1 };
        let sel = if op == INVOKE_VIRTUAL { u16_at(p1(p), instr_at(p, m, off) + 2) } else { u16_at(p1(p), instr_at(p, m, off) + 3) };
        if n <= h && is_value_kind(top_kind(k, n - 1)) && sel_ok(p, c, sel, n, k) {
            Some(pop_push(k, n, Some(Kind::Val)))
        } else { None }
    } else if op == INVOKE_VIRTUAL_GET || op == INVOKE_SIZE {
        if value_operands(k, 1) && sel_ok(p, c, w1, 1, k) { Some(k.update(h - 1, Kind::Val)) } else { None }
    } else if op == INVOKE_VIRTUAL_SET {
        if value_operands(k, 2) && sel_ok(p, c, w1, 2, k) { Some(pop_push(k, 2, Some(Kind::Val))) } else { None }
    } else if INVOKE_EQ <= op && op <= INVOKE_AT_PUT {
        let n = if op == INVOKE_AT_PUT { 3int } else { 2int };
        if value_operands(k, n) && sel_ok(p, c, p.invoke_offsets[op - INVOKE_EQ] as int, n, k) || value_operands(k, n) && p.invoke_offsets[op - INVOKE_EQ] < 0 {
            Some(pop_push(k, n, Some(Kind::Val)))
        } else { None }
    } else if op == IDENTICAL {
        if value_operands(k, 2) { Some(pop_push(k, 2, Some(Kind::Val))) } else { None }
    } else if BRANCH_IF_TRUE <= op && op <= BRANCH_IF_NOT_NULL || BRANCH_BACK_IF_TRUE <= op && op <= BRANCH_BACK_IF_NOT_NULL {
        if value_operands(k, 1) { Some(k.drop_last()) } else { None }
    } else if op == PRIMITIVE {
        // Only as the first instruction of a method without block
        // parameters: the arguments are exactly the parameters.
        if off == 0 && h == arity(p, m) && c.block_params[m].len() == 0 && info(p, m).kind == KIND_METHOD {
            Some(k.push(Kind::Val))
        } else { None }
    } else if op == TRY {
        // The try block is the top slot; the finally code starts with the
        // exception, the token and the reason.
        if 1 <= h && block_method_kind(p, k[h - 1])
            && arity(p, kind_method(k[h - 1])) == 1
            && c.contexts[kind_method(k[h - 1])] == Some(Context { outer: m, slot: h - 1, kinds: demote(k) }) {
            Some(k.push(Kind::Val).push(Kind::Token).push(Kind::Val))
        } else { None }
    } else if op == UNWIND {
        if 3 <= h && top_kind(k, 1) is Token && no_dangling(k.subrange(0, h - 3)) { Some(k.subrange(0, h - 3)) } else { None }
    } else if op == HALT {
        // HALT 2 and 3 (deep sleep, reset) are not allowed for untrusted
        // programs; that is the policy's part of the verifier.
        if b1 == 0 { Some(k.push(Kind::Val)) }
        else if b1 == 1 && value_operands(k, 1) { Some(k.drop_last()) }
        else { None }
    } else {
        // Terminators (RETURN, RETURN_NULL, THROW, NON_LOCAL_RETURN,
        // NON_LOCAL_BRANCH, the tail calls, BRANCH, BRANCH_BACK) have no
        // fall-through successor.
        None
    }
}

/// The context of a block created here: block references of this frame
/// are one context out from inside the block, and slots the outer code may
/// overwrite while the block is alive (the block is invoked from inside a
/// call, so only slots below the block's slot matter; they are values or
/// immutable block slots) keep their kinds.
pub open spec fn demote(k: Seq<Kind>) -> Seq<Kind> {
    Seq::new(k.len(), |i: int| match k[i] { Kind::Token => Kind::Val, x => x })
}

pub open spec fn typecheck_index_ok(p: Program2, op: u8, enc: int) -> bool {
    let index = enc / 2;
    if op == IS_INTERFACE || op == IS_INTERFACE_WIDE || op == AS_INTERFACE || op == AS_INTERFACE_WIDE {
        0 <= index < p.interface_check_offsets.len()
    } else {
        0 <= 2 * index + 1 < p.class_check_ids.len()
    }
}

/// LOAD_FIELD_THIS/STORE_FIELD_THIS f in method `m`: `m` declares a
/// receiver range whose classes all have field `f`.
pub open spec fn this_field_ok(p: Program2, m: int, f: int) -> bool {
    let i = info(p, m);
    &&& has_receiver_range(i)
    &&& arity(p, m) >= 1
    &&& info(p, m).kind == KIND_METHOD || info(p, m).kind == KIND_FIELD_ACCESSOR
    &&& forall|cl: int| i.recv_start <= cl < i.recv_end && cl < p.class_bits.len() ==>
            f < instance_field_count(p1(p), cl)
}

/// The instruction at offset `off` of `m` with kinds `k` is accepted, and
/// its successors' maps agree.
pub open spec fn instr_ok(p: Program2, c: Cert, m: int, off: int, k: Seq<Kind>) -> bool {
    let op = op_of(p, m, off);
    let b1 = b1_of(p, m, off);
    let w1 = w1_of(p, m, off);
    let h = k.len() as int;
    let i = info(p, m);
    let next_off = off + len_of(p, m, off);
    let at_map = |o: int, ks: Seq<Kind>| c.maps[m].contains_key(o) && c.maps[m][o] == ks;
    &&& wf_kinds(p, k)
    &&& i.entry + off + len_of(p, m, off) <= i.end
    &&& op < OPCODE_COUNT2
    &&& match post(p, c, m, off, k) {
        Some(k2) => at_map(next_off, k2) && wf_kinds(p, k2),
        None => true,
    }
    &&& if BRANCH <= op && op <= BRANCH_IF_NOT_NULL {
        // Forward branches move forward; the target is an instruction.
        let t = off + w1;
        w1 > 0 && at_map(t, if op == BRANCH { k } else { k.drop_last() })
            && (op == BRANCH || post(p, c, m, off, k) is Some)
    } else if BRANCH_BACK <= op && op <= BRANCH_BACK_IF_NOT_NULL {
        let t = off - w1;
        0 <= t && at_map(t, if op == BRANCH_BACK { k } else { k.drop_last() })
            && (op == BRANCH_BACK || post(p, c, m, off, k) is Some)
    } else if op == RETURN {
        1 <= h && is_value_kind(top_kind(k, 0))
    } else if op == RETURN_NULL {
        true
    } else if op == THROW {
        value_operands(k, 1)
    } else if op == INVOKE_STATIC_TAIL {
        let t = dispatch_target(p, w1);
        valid_method(p, t) && arity(p, t) <= h && args_ok(c, t, k, arity(p, t))
            // Block arguments of the current frame would dangle.
            && forall|j: int| h - arity(p, t) <= j < h ==> local_block(#[trigger] k[j]) < 0
    } else if op == INVOKE_LAMBDA_TAIL {
        info(p, m).kind == KIND_METHOD && h == arity(p, m) && h >= 1
    } else if op == INVOKE_INITIALIZER_TAIL {
        value_operands(k, 1)
    } else if op == NON_LOCAL_RETURN {
        2 <= h && is_value_kind(top_kind(k, 1)) && outer_block(top_kind(k, 0))
    } else if op == NON_LOCAL_BRANCH {
        1 <= h && match top_kind(k, 0) {
            Kind::Block(d, j) => d >= 1 && {
                let om = context_method(c, m, d as nat);
                let target = u32_at(p1(p), instr_at(p, m, off) + 2);
                valid_method(p, om) && c.maps[om].contains_key(target) && c.maps[om][target].len() == j + 1 - b1
            },
            _ => false,
        }
    } else {
        post(p, c, m, off, k) is Some
    }
}

/// The opcodes after which control does not fall through.
pub open spec fn is_terminator(op: u8) -> bool {
    op == RETURN || op == RETURN_NULL || op == THROW || op == BRANCH || op == BRANCH_BACK
        || op == INVOKE_STATIC_TAIL || op == INVOKE_LAMBDA_TAIL || op == INVOKE_INITIALIZER_TAIL
        || op == NON_LOCAL_RETURN || op == NON_LOCAL_BRANCH
}

/// Method `m` is accepted: its entry has the entry kinds, every mapped
/// offset is an accepted instruction, and the last instruction is a
/// terminator (control cannot fall off the end).
pub open spec fn method_ok(p: Program2, c: Cert, m: int) -> bool {
    let i = info(p, m);
    &&& i.entry <= i.end <= p.bytecodes.len()
    &&& i.entry < i.end
    &&& c.maps[m].contains_key(0) && c.maps[m][0] == entry_kinds(p, c, m)
    &&& forall|off: int| #[trigger] c.maps[m].contains_key(off) ==>
            0 <= off < i.end - i.entry && instr_ok(p, c, m, off, c.maps[m][off])
    &&& exists|last: int| c.maps[m].contains_key(last)
            && last + len_of(p, m, last) == i.end - i.entry && is_terminator(op_of(p, m, last))
    &&& (info(p, m).kind == KIND_BLOCK) == (c.contexts[m] is Some)
}

// ---------------------------------------------------------------------------
// Table checks (the verifier's phase 0).

pub open spec fn class_count(p: Program2) -> int {
    p.class_bits.len() as int
}

pub open spec fn tables_ok(p: Program2, c: Cert) -> bool {
    &&& c.maps.len() == p.methods.len()
    &&& c.block_params.len() == p.methods.len()
    &&& c.contexts.len() == p.methods.len()
    // Dispatch entries are methods (not blocks or lambdas).
    &&& forall|d: int| 0 <= d < p.dispatch.len() ==> {
        let t = #[trigger] p.dispatch[d] as int;
        t == -1 || (valid_method(p, t) && (info(p, t).kind == KIND_METHOD || info(p, t).kind == KIND_FIELD_ACCESSOR))
    }
    // Every selector fits for every class (find_method stays in the table).
    &&& forall|m: int| valid_method(p, m) && info(p, m).selector != 0xffff ==>
            class_count(p) + (#[trigger] info(p, m)).selector as int <= p.dispatch.len()
    &&& forall|k: int| 0 <= k < 19 ==> (#[trigger] p.invoke_offsets[k]) < 0 || class_count(p) + p.invoke_offsets[k] as int <= p.dispatch.len()
    &&& forall|k: int| 0 <= k < p.interface_check_offsets.len() ==>
            class_count(p) + (#[trigger] p.interface_check_offsets[k]) as int <= p.dispatch.len()
    // Methods reached through the same selector agree on arity and block
    // parameters.
    &&& forall|m1: int, m2: int| valid_method(p, m1) && valid_method(p, m2)
            && #[trigger] info(p, m1).selector == #[trigger] info(p, m2).selector && info(p, m1).selector != 0xffff ==>
            arity(p, m1) == arity(p, m2) && c.block_params[m1] == c.block_params[m2]
    // Virtual dispatch respects declared receiver ranges: a method found
    // for class `cl` declares a range containing `cl`.
    &&& forall|d: int| 0 <= d < p.dispatch.len() && #[trigger] p.dispatch[d] != -1 ==> {
            let t = p.dispatch[d] as int;
            let cl = d - info(p, t).selector as int;
            (info(p, t).selector != 0xffff && 0 <= cl < class_count(p) && has_receiver_range(info(p, t)))
                ==> info(p, t).recv_start as int <= cl < info(p, t).recv_end as int
        }
    // Entry points: methods of the expected arity without block parameters.
    &&& forall|k: int| 0 <= k < 9 ==> valid_method(p, #[trigger] entry_method(p, k))
            && c.block_params[entry_method(p, k)].len() == 0
    // The failure values are strings (literals 2..6).
    &&& p.literals.len() >= 7
    // Block methods are created at exactly one place (their context).
    &&& forall|m: int| valid_method(p, m) ==> (#[trigger] c.contexts[m] is Some ==> valid_method(p, c.contexts[m]->0.outer))
}

/// The verifier accepts program `p` with certificate `c`.
pub open spec fn accepted(p: Program2, c: Cert) -> bool {
    &&& tables_ok(p, c)
    &&& forall|m: int| 0 <= m < p.methods.len() ==> #[trigger] method_ok(p, c, m)
}

// ---------------------------------------------------------------------------
// The soundness theorem (stated; Phase 3 proves it).

/// Value `v` in frame `fi` of `s` has kind `k` (relative to method `m`).
pub open spec fn value_conforms(p: Program2, c: Cert, s: State2, fi: int, k: Kind, v: Value) -> bool {
    match k {
        Kind::Val => v is Smi || v is Obj,
        Kind::Method(t) => v == Value::Smi(t as i64),
        Kind::Block(d, j) => match v {
            Value::BlockRef(f, slot) => ref_ok(s, f as int, slot as int)
                && f as int == context_frame(s, fi, d as nat)
                && slot as int == s.frames[f as int].base + j,
            _ => false,
        },
        Kind::Param => match v {
            Value::BlockRef(f, slot) => ref_ok(s, f as int, slot as int) && (f as int) < fi,
            _ => false,
        },
        Kind::Token => v == null2(p) || match v {
            Value::Obj(id) => (id as int) < s.heap.len() && s.heap[id as int].body is Pending,
            _ => false,
        },
    }
}

/// The frame `depth` contexts out from frame `fi`: following the block's
/// own reference (parameter 0) of each block frame.
pub open spec fn context_frame(s: State2, fi: int, depth: nat) -> int
    decreases depth,
{
    if depth == 0 {
        fi
    } else if !(0 <= fi < s.frames.len()) || !(0 <= s.frames[fi].base < s.stack.len()) {
        -1
    } else {
        match s.stack[s.frames[fi].base as int] {
            Value::BlockRef(f, _) => if (f as int) < fi { context_frame(s, f as int, (depth - 1) as nat) } else { -1 },
            _ => -1,
        }
    }
}

/// The offset at which frame `fi` is suspended (the top frame: `s.bci`;
/// a lower frame: the return address of the frame above), and whether a
/// result is still to be pushed.
pub open spec fn frame_offset(p: Program2, s: State2, fi: int) -> int {
    let m = s.frames[fi].method as int;
    let bci = if fi == s.frames.len() - 1 { s.bci as int } else { s.frames[fi + 1].ret as int };
    bci - info(p, m).entry
}

/// The abstract maps describe the state: every frame's slots conform to
/// the map at its offset (lower frames: minus the result their callee
/// will push), handlers sit at TRY sites, and the program state is well
/// formed. This is the invariant of the soundness proof.
pub open spec fn conforms(p: Program2, c: Cert, s: State2) -> bool {
    &&& s.frames.len() > 0
    &&& forall|fi: int| 0 <= fi < s.frames.len() ==> {
        let f = #[trigger] s.frames[fi];
        let m = f.method as int;
        let top_frame = fi == s.frames.len() - 1;
        let limit = if top_frame { s.stack.len() as int } else { s.frames[fi + 1].base as int };
        let off = frame_offset(p, s, fi);
        let pending = if top_frame { 0int } else { 1int };
        &&& valid_method(p, m)
        &&& c.maps[m].contains_key(off)
        &&& f.base <= limit
        &&& c.maps[m][off].len() == limit - f.base + pending
        &&& forall|j: int| 0 <= j < limit - f.base ==>
                value_conforms(p, c, s, fi, #[trigger] c.maps[m][off][j], s.stack[f.base + j])
    }
    &&& forall|t: int| 0 <= t < s.tries.len() ==> {
        let h = #[trigger] s.tries[t];
        &&& (h.frame as int) < s.frames.len() - 1
        &&& (t > 0 ==> s.tries[t - 1].frame <= h.frame)
        &&& op_of(p, s.frames[h.frame as int].method as int, h.bci - 1 - info(p, s.frames[h.frame as int].method as int).entry) == TRY
    }
}

/// A primitive result: a value (no block reference or token).
pub open spec fn prim_value(v: Value) -> bool {
    v is Smi || v is Obj
}

/// One step, completed: the step itself, and for a PRIMITIVE every
/// completion the primitive oracle may choose (success with a value,
/// failure with an error, or a missing primitive), with any new heap that
/// extends the old one.
pub open spec fn completions_ok(p: Program2, c: Cert, s: State2) -> bool {
    match step(p, s) {
        Outcome2::Stuck(_) => false,
        Outcome2::Next(s1) => conforms(p, c, s1),
        Outcome2::Halt(s1, h) => h is Yield ==> conforms(p, c, s1),
        Outcome2::Primitive(s1, _, _) => forall|heap: Seq<HeapObj>, v: Value|
            #![trigger crate::v2::prim::prim_success(p, s1, heap, v)]
            heap.len() >= s1.heap.len() && prim_value(v) ==> {
                &&& match crate::v2::prim::prim_success(p, s1, heap, v) {
                    Outcome2::Next(s2) => conforms(p, c, s2),
                    Outcome2::Stuck(_) => false,
                    _ => true,
                }
                &&& match crate::v2::prim::prim_failure(s1, heap, v) {
                    Outcome2::Next(s2) => conforms(p, c, s2),
                    Outcome2::Stuck(_) => false,
                    _ => true,
                }
                &&& !(crate::v2::prim::prim_missing(p, s1) is Stuck)
            },
    }
}

/// Soundness of the structural verifier: for an accepted program, the
/// initial state conforms, and from a conforming state every step (with
/// every completion of a primitive) is not stuck and leads to a conforming
/// state. Hence no execution of an accepted program reaches
/// `Outcome2::Stuck`. (The task primitives keep conformance too; their
/// statement follows the same pattern and is left to Phase 3.)
///
/// Phase 3 proves `soundness()`; until then it is a statement only: there
/// is no `admit` and nothing depends on it.
pub open spec fn soundness() -> bool {
    forall|p: Program2, c: Cert|
        crate::v2::exec::wf_program2(p) && #[trigger] accepted(p, c) ==> {
            &&& forall|heap0: Seq<HeapObj>, globals0: Seq<Value>|
                    conforms(p, c, #[trigger] crate::v2::prim::initial_state(p, heap0, globals0))
            &&& forall|s: State2| #[trigger] conforms(p, c, s) ==> completions_ok(p, c, s)
        }
}

} // verus!
