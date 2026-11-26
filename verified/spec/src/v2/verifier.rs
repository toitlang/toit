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

//! The structural verifier of format 2: the decidable predicate
//! `accepts(p, c, trusted)` over the abstract program and a certificate.
//!
//! The certificate is computed by `v2::infer` (untrusted, plain Rust,
//! abstract interpretation): on the host, where the toolchain ships it
//! with the program (`v2::encode`, `v2::cert`; format/18), or on a host VM
//! for a program without one. `v2::walk::walk` (Verus) is proven to
//! accept only if `split_ok` holds, the per-method form of `accepts(p, c, trusted)`
//! (`v2::split`); `v2::theorem` proves that an
//! accepted program never reaches a stuck state. A wrong certificate can
//! only lead to a rejection, never to an unsound acceptance.
//!
//! The certificate has:
//!
//! * `maps[m][off]`: the kinds of the frame's slots (bottom first) at the
//!   instruction at offset `off` of method `m`, or `None` for offsets that
//!   are not reachable instruction starts;
//! * `block_params[m][i]`: parameter `i` of `m` is a block;
//! * `contexts[t]`: for a block method `t`, the method and the frame slot
//!   it is created in, and the kinds of that frame's slots up to and
//!   including the block's slot whenever the slot holds the block;
//! * `sel_rep[s]`: one method with selector offset `s` (or -1): all methods
//!   with the same selector agree on arity and block parameters;
//! * `global_count`: the number of globals of the program;
//! * `prim_arity`: the primitive table of the program's policy (not
//!   inferred, a trusted input: the arities from `src/primitive.h` of the
//!   primitives the policy allows, -1 for the ones it denies). A PRIMITIVE
//!   is accepted only for an allowed primitive of the method's arity, so
//!   an accepted program calls only the policy's primitives
//!   (`theorem::theorem_soundness`, `prim_allowed`).
//!
//! The rules are local: each mapped instruction is checked against its
//! map and the maps of its successors. See SOUNDNESS.md for the invariant
//! they establish.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::bytecodes::*;
#[cfg(verus_only)]
use crate::spec_common::{instance_field_count, u16_at, u32_at, class_tag, smi_ok, builtin, INSTANCE_TAG,
    EXCEPTION_CLASS, STACK_CLASS, TASK_CLASS, DOUBLE_CLASS, SMI_CLASS, ENTRY_MAIN, ENTRY_TASK,
    RUN_GLOBAL_INITIALIZER};

verus! {

// ---------------------------------------------------------------------------
// Abstract kinds and certificates.

/// The kind of a slot of a frame.
pub enum Kind {
    /// A smi or an object reference.
    Val,
    /// The method id `t` (a smi), pushed by LOAD_METHOD.
    Method(int),
    /// A block reference to slot `slot` (frame-relative) of the frame
    /// `depth` contexts out: 0 is the current frame, 1 the frame the
    /// current block was created in, and so on.
    Block(int, int),
    /// A block reference received as a block parameter: its frame is below
    /// the current one; it can be invoked or passed on as a block argument.
    Param,
    /// A word of the unwinding token of a finally code (its two token
    /// slots, format note 23).
    Token,
}

pub struct Context {
    pub outer: int,
    pub slot: int,
    pub kinds: Seq<Kind>,
}

pub struct Cert {
    pub maps: Seq<Seq<Option<Seq<Kind>>>>,
    pub block_params: Seq<Seq<bool>>,
    pub contexts: Seq<Option<Context>>,
    pub sel_rep: Seq<int>,
    pub global_count: int,
    /// The primitive table of the program's policy: the arity of primitive
    /// `index` of module `module` if the policy allows it, -1 if it denies
    /// it (its PRIMITIVE fails with PERMISSION_DENIED), -2 if the policy has
    /// no such primitive (its module denied as a whole: the PRIMITIVE raises
    /// PRIMITIVE_LOOKUP_FAILED) (trusted input: `PrimitivePolicy::verifier_arities`, from the
    /// arities of src/primitive.h, `v2::prim_arity`).
    pub prim_arity: Seq<Seq<int>>,
}

/// A primitive the table allows: present and not denied.
pub open spec fn prim_allowed(pa: Seq<Seq<int>>, module: int, index: int) -> bool {
    0 <= module < pa.len() && 0 <= index < pa[module].len() && pa[module][index] >= 0
}

/// The table lists the primitive: allowed with arity `a`, denied (-1) or
/// absent (-2).
pub open spec fn prim_listed(pa: Seq<Seq<int>>, module: int, index: int, a: int) -> bool {
    0 <= module < pa.len() && 0 <= index < pa[module].len()
        && (pa[module][index] == a || pa[module][index] == -1 || pa[module][index] == -2)
}

/// The byte that marks a denied primitive in the executable table.
pub const X_PRIM_DENIED: u8 = 0xff;
/// The byte that marks a primitive the policy does not have at all.
pub const X_PRIM_ABSENT: u8 = 0xfe;

/// An entry of the executable table as the abstract table has it.
pub open spec fn prim_entry(a: u8) -> int {
    if a == X_PRIM_DENIED { -1 } else if a == X_PRIM_ABSENT { -2 } else { a as int }
}

/// The core primitive module and the task primitives completed by the
/// machine (`v2::prim::task_new_step`, `task_transfer_step`); checked
/// against the primitive names of the dump by `toit_spec_verify`.
pub spec const PRIM_CORE: int = 0;
pub spec const PRIM_TASK_NEW: int = 115;
pub spec const PRIM_TASK_TRANSFER: int = 116;
pub const X_PRIM_TASK_NEW: u16 = 115;
pub const X_PRIM_TASK_TRANSFER: u16 = 116;

pub open spec fn is_val(k: Kind) -> bool {
    k is Val || k is Method
}

pub open spec fn is_ref(k: Kind) -> bool {
    k is Block || k is Param
}

pub open spec fn is_local_ref(k: Kind) -> bool {
    match k { Kind::Block(d, _) => d == 0, _ => false }
}

pub open spec fn kind_method(k: Kind) -> int {
    match k { Kind::Method(t) => t, _ => -1 }
}

pub open spec fn map_at(c: Cert, m: int, off: int) -> Option<Seq<Kind>> {
    if 0 <= m < c.maps.len() && 0 <= off < c.maps[m].len() { c.maps[m][off] } else { None }
}

pub open spec fn ctx_of(c: Cert, t: int) -> Option<Context> {
    if 0 <= t < c.contexts.len() { c.contexts[t] } else { None }
}

pub open spec fn is_block_param(c: Cert, m: int, i: int) -> bool {
    0 <= m < c.block_params.len() && 0 <= i < c.block_params[m].len() && c.block_params[m][i]
}

pub open spec fn top_kind(k: Seq<Kind>, n: int) -> Kind {
    k[k.len() - 1 - n]
}

pub open spec fn class_count(p: Program2) -> int {
    p.class_bits.len() as int
}

pub open spec fn ifc(p: Program2, cl: int) -> int {
    instance_field_count(p1(p), cl)
}

pub open spec fn is_instance_class(p: Program2, cl: int) -> bool {
    0 <= cl < class_count(p) && class_tag(p1(p), cl) == INSTANCE_TAG
}

/// The VM's `TASK_TAG`: tasks are instances with their own tag.
pub spec const TASK_TAG: u16 = 8;

/// Objects of the class have instance fields (instances and tasks).
pub open spec fn is_field_class(p: Program2, cl: int) -> bool {
    0 <= cl < class_count(p) && (class_tag(p1(p), cl) == INSTANCE_TAG || class_tag(p1(p), cl) == TASK_TAG)
}

// ---------------------------------------------------------------------------
// Instruction operands.

pub open spec fn instr_at(p: Program2, m: int, off: int) -> int {
    info(p, m).entry + off
}

/// The opcode at offset `off` of method `m` as the verifier types it: an
/// unchecked twin (format note 20) as its base instruction.
pub open spec fn op_of(p: Program2, m: int, off: int) -> u8 {
    base_op(raw_op_of(p, m, off))
}

/// The opcode byte at offset `off` of method `m`.
pub open spec fn raw_op_of(p: Program2, m: int, off: int) -> u8 {
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
// Block slots and contexts.

/// Slot `i` of `fk` (the kinds of a frame of method `om`) holds a block
/// method whose context is that slot of a frame of `om`.
pub open spec fn block_slot(p: Program2, c: Cert, om: int, fk: Seq<Kind>, i: int) -> bool {
    &&& 0 <= i < fk.len()
    &&& match fk[i] {
        Kind::Method(t) => valid_method(p, t) && info(p, t).kind == KIND_BLOCK && match ctx_of(c, t) {
            Some(ctx) => ctx.outer == om && ctx.slot == i,
            None => false,
        },
        _ => false,
    }
}

/// The kinds of the frame `depth` contexts out from method `m`.
pub open spec fn ctx_kinds(c: Cert, m: int, depth: nat) -> Option<Seq<Kind>>
    decreases depth,
{
    if depth == 0 {
        None
    } else {
        match ctx_of(c, m) {
            None => None,
            Some(ctx) => if depth == 1 { Some(ctx.kinds) } else { ctx_kinds(c, ctx.outer, (depth - 1) as nat) },
        }
    }
}

/// The method of the frame `depth` contexts out from method `m`.
pub open spec fn ctx_method(c: Cert, m: int, depth: nat) -> int
    decreases depth,
{
    if depth == 0 {
        m
    } else {
        match ctx_of(c, m) {
            None => -1,
            Some(ctx) => ctx_method(c, ctx.outer, (depth - 1) as nat),
        }
    }
}

/// The kinds of the frame a block reference of depth `d` points into.
pub open spec fn ref_kinds(c: Cert, m: int, k: Seq<Kind>, d: int) -> Option<Seq<Kind>> {
    if d == 0 { Some(k) } else if d > 0 { ctx_kinds(c, m, d as nat) } else { None }
}

pub open spec fn ref_method(c: Cert, m: int, d: int) -> int {
    if d >= 0 { ctx_method(c, m, d as nat) } else { -1 }
}

/// A slot of an outer frame read through LOAD_OUTER, seen from here.
pub open spec fn shift(k: Kind, depth: int) -> Kind {
    match k {
        Kind::Block(d, s) => Kind::Block(d + depth, s),
        Kind::Method(_) => Kind::Val,
        _ => k,
    }
}

/// Block references point to block slots: of this frame below them, or
/// of an outer frame reachable through the contexts.
pub open spec fn wf_kind(p: Program2, c: Cert, m: int, k: Seq<Kind>, j: int) -> bool {
    match k[j] {
        Kind::Block(d, i) => if d == 0 {
            i < j && block_slot(p, c, m, k, i)
        } else {
            d > 0 && match ctx_kinds(c, m, d as nat) {
                Some(fk) => block_slot(p, c, ctx_method(c, m, d as nat), fk, i),
                None => false,
            }
        },
        _ => true,
    }
}

pub open spec fn wf_kinds(p: Program2, c: Cert, m: int, k: Seq<Kind>) -> bool {
    forall|j: int| 0 <= j < k.len() ==> #[trigger] wf_kind(p, c, m, k, j)
}

/// Every block slot of the frame has the kinds of its context below it.
pub open spec fn ctx_ok_at(p: Program2, c: Cert, m: int, k: Seq<Kind>, i: int) -> bool {
    block_slot(p, c, m, k, i) ==> k.subrange(0, i + 1) == ctx_of(c, kind_method(k[i]))->0.kinds
}

/// Some block reference of this frame points to slot `i` or above.
pub open spec fn live_from(k: Seq<Kind>, i: int) -> bool {
    exists|j: int| 0 <= j < k.len() && match #[trigger] k[j] { Kind::Block(d, s) => d == 0 && s >= i, _ => false }
}

pub open spec fn ctx_ok_upto(p: Program2, c: Cert, m: int, k: Seq<Kind>, n: int) -> bool {
    forall|i: int| 0 <= i <= n && i < k.len() ==> #[trigger] ctx_ok_at(p, c, m, k, i)
}

/// The block slots that references of this frame can reach (directly or
/// through the contexts of the blocks they point to) have their contexts'
/// kinds below them.
pub open spec fn ctx_ok(p: Program2, c: Cert, m: int, k: Seq<Kind>) -> bool {
    forall|i: int| 0 <= i < k.len() && live_from(k, i) ==> #[trigger] ctx_ok_at(p, c, m, k, i)
}

pub open spec fn referenced(k: Seq<Kind>, i: int) -> bool {
    exists|j: int| 0 <= j < k.len() && #[trigger] k[j] == Kind::Block(0, i)
}

pub open spec fn below_token(k: Seq<Kind>, i: int) -> bool {
    exists|j: int| i < j < k.len() && (#[trigger] k[j]) is Token
}

/// Methods whose parameter 0 is pinned: `this` of a method with a receiver
/// range, and the block's own reference of a block.
pub open spec fn pinned0(p: Program2, m: int) -> bool {
    has_receiver_range(info(p, m)) || info(p, m).kind == KIND_BLOCK
}

/// Slot `i` may be overwritten with a value of kind `v`: it is not pinned,
/// not referenced, not a token; below a token (inside a finally code that
/// may resume a non-local branch to this frame) only plain value slots are
/// overwritten, with plain values, so the kinds below a token never change.
pub open spec fn writable(p: Program2, m: int, k: Seq<Kind>, i: int, v: Kind) -> bool {
    &&& 0 <= i < k.len()
    &&& !(i == 0 && pinned0(p, m))
    &&& !referenced(k, i)
    &&& !(k[i] is Token)
    &&& !(v is Token)
    &&& (below_token(k, i) ==> k[i] is Val && v is Val)
}

/// A call that takes the top `n` slots as arguments leaves a pinned
/// parameter 0 in the frame.
pub open spec fn leaves0(p: Program2, m: int, h: int, n: int) -> bool {
    pinned0(p, m) && arity(p, m) >= 1 ==> h - n >= 1
}

/// The arguments on top of `k` fit the parameters of `t`; block arguments
/// of this frame point below the arguments.
pub open spec fn arg_ok(c: Cert, t: int, k: Seq<Kind>, n: int, x: int) -> bool {
    let kd = k[k.len() - n + x];
    &&& if is_block_param(c, t, x) { is_ref(kd) } else { is_val(kd) }
    &&& match kd { Kind::Block(d, i) => d == 0 ==> i < k.len() - n, _ => true }
}

pub open spec fn args_ok(c: Cert, t: int, k: Seq<Kind>, n: int) -> bool {
    &&& 0 <= n <= k.len()
    &&& forall|x: int| 0 <= x < n ==> #[trigger] arg_ok(c, t, k, n, x)
}

pub open spec fn value_operands(k: Seq<Kind>, n: int) -> bool {
    0 <= n <= k.len() && forall|i: int| 0 <= i < n ==> is_val(#[trigger] top_kind(k, i))
}

pub open spec fn pop_push(k: Seq<Kind>, n: int, top: Option<Kind>) -> Seq<Kind> {
    let k1 = k.subrange(0, k.len() - n);
    match top { Some(t) => k1.push(t), None => k1 }
}

/// A virtual call of selector `sel` with `n` arguments: the receiver is a
/// value, the dispatch row fits the table, and if any method has the
/// selector the arguments fit it.
pub open spec fn sel_ok(p: Program2, c: Cert, sel: int, n: int, k: Seq<Kind>) -> bool {
    &&& 1 <= n <= k.len()
    &&& 0 <= sel < 0xffff
    &&& sel < c.sel_rep.len()
    &&& class_count(p) + sel <= p.dispatch.len()
    &&& is_val(top_kind(k, n - 1))
    &&& {
        let r = c.sel_rep[sel];
        r == -1 || (valid_method(p, r) && arity(p, r) == n && args_ok(c, r, k, n))
    }
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
/// receiver range of instance classes that all have field `f`.
pub open spec fn this_field_ok(p: Program2, m: int, f: int) -> bool {
    let i = info(p, m);
    &&& has_receiver_range(i)
    &&& arity(p, m) >= 1
    &&& (i.kind == KIND_METHOD || i.kind == KIND_FIELD_ACCESSOR)
    &&& i.recv_end as int <= class_count(p)
    &&& forall|cl: int| i.recv_start <= cl < i.recv_end ==>
            #[trigger] is_field_class(p, cl) && f < ifc(p, cl)
}

/// The receiver range of `i` includes the task class.
pub open spec fn range_has_task(p: Program2, i: MethodInfo) -> bool {
    i.recv_start as int <= builtin(p1(p), TASK_CLASS) < i.recv_end as int
}

/// LOAD_FIELD_THIS f: `this` has field `f`, which is not the stack of a
/// task (`v2::spec::field_readable`).
pub open spec fn this_load_ok(p: Program2, m: int, f: int) -> bool {
    this_field_ok(p, m, f) && !(range_has_task(p, info(p, m)) && f == TASK_STACK_FIELD)
}

/// STORE_FIELD_THIS f: `this` has field `f`, which is not a field of a
/// task the machine owns (`v2::spec::field_writable`).
pub open spec fn this_store_ok(p: Program2, m: int, f: int) -> bool {
    this_field_ok(p, m, f) && !(range_has_task(p, info(p, m)) && f <= TASK_ID_FIELD)
}

pub open spec fn branch_kind(op: u8) -> int {
    if BRANCH <= op && op <= BRANCH_IF_NOT_NULL { op - BRANCH }
    else if BRANCH_S <= op && op <= BRANCH_IF_NOT_NULL_S { op - BRANCH_S }
    else if op == BRANCH_BACK_S { 0 }
    else { op - BRANCH_BACK }
}

/// A short branch (format note 22): a one-byte distance.
pub open spec fn is_short_branch(op: u8) -> bool {
    BRANCH_S <= op && op <= BRANCH_BACK_S
}

/// A forward branch, long or short.
pub open spec fn is_fwd_branch(op: u8) -> bool {
    (BRANCH <= op && op <= BRANCH_IF_NOT_NULL) || (BRANCH_S <= op && op <= BRANCH_IF_NOT_NULL_S)
}

/// An unconditional branch (a terminator), long or short.
pub open spec fn is_uncond_branch(op: u8) -> bool {
    op == BRANCH || op == BRANCH_BACK || op == BRANCH_S || op == BRANCH_BACK_S
}

/// A conditional branch: it pops the condition, a value.
pub open spec fn is_cond_branch(op: u8) -> bool {
    (BRANCH_IF_TRUE <= op && op <= BRANCH_IF_NOT_NULL) || (BRANCH_BACK_IF_TRUE <= op && op <= BRANCH_BACK_IF_NOT_NULL)
        || (BRANCH_IF_TRUE_S <= op && op <= BRANCH_IF_NOT_NULL_S)
}

/// The distance operand of the branch at offset `off` of `m`: one byte for
/// a short branch, a u16 otherwise.
pub open spec fn branch_dist(p: Program2, m: int, off: int) -> int {
    if is_short_branch(op_of(p, m, off)) { b1_of(p, m, off) } else { w1_of(p, m, off) }
}

/// The target offset of the branch at offset `off` of `m`.
pub open spec fn branch_target(p: Program2, m: int, off: int) -> int {
    if is_fwd_branch(op_of(p, m, off)) { off + branch_dist(p, m, off) } else { off - branch_dist(p, m, off) }
}

/// Byte `j` of the instruction at offset `off` of `m`.
pub open spec fn bk_of(p: Program2, m: int, off: int, j: int) -> int {
    p.bytecodes[instr_at(p, m, off) + j] as int
}

/// The loop steps (proposal, format note 19).
pub open spec fn is_loop(op: u8) -> bool {
    op == LOOP_REPEAT || op == LOOP_ARRAY
}

/// A loop step's operands: the counter `c` (overwritten), the block `b`
/// (copied) and the slots `x`, `y` it reads, counted from the top before
/// the pop of the top slot; the counter and the read slots hold values.
pub open spec fn loop_ok(p: Program2, m: int, k: Seq<Kind>, c: int, b: int, x: int, y: int) -> bool {
    let h = k.len() as int;
    &&& 1 <= c < h && 1 <= b < h && 1 <= x < h && 1 <= y < h
    &&& is_val(top_kind(k, c)) && is_val(top_kind(k, x)) && is_val(top_kind(k, y))
    &&& !(top_kind(k, b) is Token)
    &&& writable(p, m, k, h - 1 - c, Kind::Val)
}

/// The kinds at the target of a taken loop step: the counter is a value,
/// the top is popped, a copy of the block and a value are pushed.
pub open spec fn loop_kinds(k: Seq<Kind>, c: int, b: int) -> Seq<Kind> {
    let h = k.len() as int;
    k.update(h - 1 - c, Kind::Val).subrange(0, h - 1).push(top_kind(k, b)).push(Kind::Val)
}

/// The operands `(c, b, x, y)` of the loop step at offset `off` of `m`: its
/// operand byte `n` is the counter, `n + 1` the block, `n + 2` (LOOP_REPEAT:
/// the limit) and `n + 3` (LOOP_ARRAY) the slots it reads.
pub open spec fn loop_operands(p: Program2, m: int, off: int) -> (int, int, int, int) {
    let n = bk_of(p, m, off, 3);
    (n, n + 1, n + 2, if op_of(p, m, off) == LOOP_ARRAY { n + 3 } else { n + 2 })
}

/// HASH_FIND n m (proposal, format note 19): the probe state (slots `n`,
/// `n + 1`, `n + 2`, overwritten), the hash (`m`) and the collection
/// (`m + 2`) hold values.
pub open spec fn hf_ok(p: Program2, m: int, k: Seq<Kind>, n: int, mm: int) -> bool {
    let h = k.len() as int;
    &&& 0 <= n && n + 2 < h && 0 <= mm && mm + 2 < h
    &&& is_val(top_kind(k, n)) && is_val(top_kind(k, n + 1)) && is_val(top_kind(k, n + 2))
    &&& is_val(top_kind(k, mm)) && is_val(top_kind(k, mm + 2))
    &&& writable(p, m, k, h - 1 - n, Kind::Val)
    &&& writable(p, m, k, h - 2 - n, Kind::Val)
    &&& writable(p, m, k, h - 3 - n, Kind::Val)
}

/// The kinds after a candidate: the probe state holds values, the key and
/// its position are pushed. (A miss pushes a value and branches.)
pub open spec fn hf_kinds(k: Seq<Kind>, n: int) -> Seq<Kind> {
    let h = k.len() as int;
    k.update(h - 1 - n, Kind::Val).update(h - 2 - n, Kind::Val).update(h - 3 - n, Kind::Val)
        .push(Kind::Val).push(Kind::Val)
}

/// The fall-through successor kinds of an instruction, `None` for
/// terminators and rejected instructions.
pub open spec fn post(p: Program2, c: Cert, m: int, off: int, k: Seq<Kind>, trusted: bool) -> Option<Seq<Kind>> {
    let op = op_of(p, m, off);
    let b1 = b1_of(p, m, off);
    let w1 = w1_of(p, m, off);
    let h = k.len() as int;
    if op == LOAD_LOCAL || op == LOAD_LOCAL_WIDE || (LOAD_LOCAL_0 <= op && op <= LOAD_LOCAL_5) {
        let n = if op == LOAD_LOCAL { b1 } else if op == LOAD_LOCAL_WIDE { w1 } else { op - LOAD_LOCAL_0 };
        if n < h && !(top_kind(k, n) is Token) { Some(k.push(top_kind(k, n))) } else { None }
    } else if op == POP_LOAD_LOCAL {
        if b1 + 1 < h && !(top_kind(k, b1 + 1) is Token) { Some(k.update(h - 1, top_kind(k, b1 + 1))) } else { None }
    } else if op == STORE_LOCAL || op == STORE_LOCAL_POP {
        let i = h - 1 - b1;
        let v = top_kind(k, 0);
        if 1 <= b1 && b1 < h && writable(p, m, k, i, v) {
            let k1 = k.update(i, v);
            Some(if op == STORE_LOCAL_POP { k1.drop_last() } else { k1 })
        } else { None }
    } else if op == LOAD_OUTER || op == STORE_OUTER || op == LOAD_OUTER_BLOCK {
        let r = if op == STORE_OUTER { 1int } else { 0int };
        if r >= h { None } else {
            match top_kind(k, r) {
                Kind::Block(d, j) => match ref_kinds(c, m, k, d) {
                    None => None,
                    Some(fk) => {
                        let i = j - b1;
                        let om = ref_method(c, m, d);
                        if !(0 <= i <= j && j < fk.len()) {
                            None
                        } else if op == LOAD_OUTER {
                            if fk[i] is Token { None } else { Some(k.update(h - 1, shift(fk[i], d))) }
                        } else if op == LOAD_OUTER_BLOCK {
                            if block_slot(p, c, om, fk, i) { Some(k.update(h - 1, Kind::Block(d, i))) } else { None }
                        } else if d >= 1 && fk[i] is Val && is_val(top_kind(k, 0)) && valid_method(p, om)
                                && !(i == 0 && pinned0(p, om)) {
                            Some(pop_push(k, 2, Some(Kind::Val)))
                        } else { None }
                    },
                },
                _ => None,
            }
        }
    } else if op == LOAD_BLOCK {
        let i = h - 1 - b1;
        if block_slot(p, c, m, k, i) { Some(k.push(Kind::Block(0, i))) } else { None }
    } else if op == LOAD_FIELD || op == LOAD_FIELD_WIDE {
        if value_operands(k, 1) && leaves0(p, m, h, 1) { Some(k.update(h - 1, Kind::Val)) } else { None }
    } else if op == LOAD_FIELD_LOCAL || op == POP_LOAD_FIELD_LOCAL {
        let slot = if op == POP_LOAD_FIELD_LOCAL { b1 % 16 + 1 } else { b1 % 16 };
        if slot < h && is_val(top_kind(k, slot)) {
            Some(if op == LOAD_FIELD_LOCAL { k.push(Kind::Val) } else { k.update(h - 1, Kind::Val) })
        } else { None }
    } else if op == STORE_FIELD || op == STORE_FIELD_WIDE || op == STORE_FIELD_POP {
        if value_operands(k, 2) && leaves0(p, m, h, 2) {
            Some(if op == STORE_FIELD_POP { pop_push(k, 2, None) } else { pop_push(k, 2, Some(Kind::Val)) })
        } else { None }
    } else if op == LOAD_FIELD_THIS {
        if this_load_ok(p, m, b1) { Some(k.push(Kind::Val)) } else { None }
    } else if op == STORE_FIELD_THIS {
        if this_store_ok(p, m, b1) && value_operands(k, 1) { Some(k) } else { None }
    } else if op == LOAD_LITERAL || op == LOAD_LITERAL_WIDE {
        if (if op == LOAD_LITERAL { b1 } else { w1 }) < p.literals.len() { Some(k.push(Kind::Val)) } else { None }
    } else if op == LOAD_NULL || op == LOAD_SMI_0 || op == LOAD_SMI_1 || op == LOAD_SMI_U8 || op == LOAD_SMI_U16 {
        Some(k.push(Kind::Val))
    } else if op == LOAD_SMI_U32 {
        if smi_ok(p1(p), u32_at(p1(p), instr_at(p, m, off) + 1)) { Some(k.push(Kind::Val)) } else { None }
    } else if op == LOAD_SMIS_0 {
        Some(k + Seq::new(b1 as nat, |i: int| Kind::Val))
    } else if op == LOAD_METHOD {
        let t = u32_at(p1(p), instr_at(p, m, off) + 1);
        if valid_method(p, t) && smi_ok(p1(p), t) { Some(k.push(Kind::Method(t))) } else { None }
    } else if op == LOAD_GLOBAL_VAR || op == LOAD_GLOBAL_VAR_LAZY {
        if b1 < c.global_count { Some(k.push(Kind::Val)) } else { None }
    } else if op == LOAD_GLOBAL_VAR_WIDE || op == LOAD_GLOBAL_VAR_LAZY_WIDE {
        if w1 < c.global_count { Some(k.push(Kind::Val)) } else { None }
    } else if op == STORE_GLOBAL_VAR || op == STORE_GLOBAL_VAR_WIDE {
        if (if op == STORE_GLOBAL_VAR { b1 } else { w1 }) < c.global_count && value_operands(k, 1) { Some(k) } else { None }
    } else if op == LOAD_GLOBAL_VAR_DYNAMIC {
        if value_operands(k, 1) && leaves0(p, m, h, 1) { Some(k.update(h - 1, Kind::Val)) } else { None }
    } else if op == STORE_GLOBAL_VAR_DYNAMIC {
        if value_operands(k, 2) { Some(pop_push(k, 2, None)) } else { None }
    } else if op == POP || op == POP_1 {
        let n = if op == POP { b1 } else { 1 };
        if n <= h { Some(k.subrange(0, h - n)) } else { None }
    } else if op == ALLOCATE || op == ALLOCATE_WIDE {
        let cl = if op == ALLOCATE { b1 } else { w1 };
        if is_instance_class(p, cl) && ifc(p, cl) >= 0 { Some(k.push(Kind::Val)) } else { None }
    } else if IS_CLASS <= op && op <= AS_INTERFACE_WIDE {
        // IS_* replaces the operand: not a pinned parameter 0.
        if value_operands(k, 1) && (op > IS_INTERFACE_WIDE || leaves0(p, m, h, 1))
            && typecheck_index_ok(p, op, if op % 2 == 0 { b1 } else { w1 }) {
            Some(if op <= IS_INTERFACE_WIDE { k.update(h - 1, Kind::Val) } else { k })
        } else { None }
    } else if op == AS_LOCAL {
        if b1 / 32 < h && is_val(top_kind(k, b1 / 32)) && 2 * (b1 % 32) + 1 < p.class_check_ids.len() { Some(k) } else { None }
    } else if op == INVOKE_STATIC {
        let t = dispatch_target(p, w1);
        if valid_method(p, t) && args_ok(c, t, k, arity(p, t)) && leaves0(p, m, h, arity(p, t)) {
            Some(pop_push(k, arity(p, t), Some(Kind::Val)))
        } else { None }
    } else if op == INVOKE_BLOCK {
        if 1 <= b1 <= h && is_ref(top_kind(k, b1 - 1)) && value_operands(k, b1 - 1) && leaves0(p, m, h, b1)
            && match top_kind(k, b1 - 1) { Kind::Block(d, i) => d == 0 ==> i < h - b1, _ => true } {
            Some(pop_push(k, b1, Some(Kind::Val)))
        } else { None }
    } else if op == INVOKE_VIRTUAL || op == INVOKE_VIRTUAL_WIDE {
        let n = if op == INVOKE_VIRTUAL { b1 + 1 } else { w1 + 1 };
        let sel = if op == INVOKE_VIRTUAL { u16_at(p1(p), instr_at(p, m, off) + 2) } else { u16_at(p1(p), instr_at(p, m, off) + 3) };
        if sel_ok(p, c, sel, n, k) && leaves0(p, m, h, n) { Some(pop_push(k, n, Some(Kind::Val))) } else { None }
    } else if op == INVOKE_VIRTUAL_GET || op == INVOKE_SIZE {
        if sel_ok(p, c, w1, 1, k) && leaves0(p, m, h, 1) { Some(k.update(h - 1, Kind::Val)) } else { None }
    } else if op == INVOKE_VIRTUAL_SET {
        if value_operands(k, 2) && sel_ok(p, c, w1, 2, k) && leaves0(p, m, h, 2) { Some(pop_push(k, 2, Some(Kind::Val))) } else { None }
    } else if INVOKE_EQ <= op && op <= INVOKE_AT_PUT {
        let n = if op == INVOKE_AT_PUT { 3int } else { 2int };
        let sel = p.invoke_offsets[op - INVOKE_EQ] as int;
        if value_operands(k, n) && (sel < 0 || sel_ok(p, c, sel, n, k)) && leaves0(p, m, h, n) {
            Some(pop_push(k, n, Some(Kind::Val)))
        } else { None }
    } else if op == IDENTICAL {
        if value_operands(k, 2) && leaves0(p, m, h, 2) { Some(pop_push(k, 2, Some(Kind::Val))) } else { None }
    } else if is_cond_branch(op) {
        if value_operands(k, 1) { Some(k.drop_last()) } else { None }
    } else if op == PRIMITIVE {
        // On an empty expression stack: the arguments are exactly the
        // parameters.
        let module = b1;
        let index = u16_at(p1(p), instr_at(p, m, off) + 2);
        if h == arity(p, m) && info(p, m).kind == KIND_METHOD
            && 0 <= module < c.prim_arity.len() && 0 <= index < c.prim_arity[module].len()
            // Allowed by the policy with the method's arity, denied (-1) or
            // absent (-2): a denied or absent primitive is not called; its
            // PRIMITIVE fails with PERMISSION_DENIED (`prim::prim_denied`) or
            // raises PRIMITIVE_LOOKUP_FAILED (`prim::prim_missing`).
            && prim_listed(c.prim_arity, module, index, arity(p, m))
            && (module == PRIM_CORE && index == PRIM_TASK_NEW ==> arity(p, m) == 1)
            // A new task resumes the transferring frame with fresh arguments
            // (`v2::prim::resume`): its parameters must be plain values.
            && (module == PRIM_CORE && index == PRIM_TASK_TRANSFER ==>
                    arity(p, m) == 2 && k[0] is Val && k[1] is Val && !has_receiver_range(info(p, m))) {
            Some(k.push(Kind::Val))
        } else { None }
    } else if op == TRY {
        if 1 <= h && block_slot(p, c, m, k, h - 1) && arity(p, kind_method(k[h - 1])) == 1
            && ctx_ok_upto(p, c, m, k, h - 1) {
            Some(k.push(Kind::Val).push(Kind::Token).push(Kind::Token).push(Kind::Val))
        } else { None }
    } else if op == UNWIND {
        // The value slot below the token words is the exception or return
        // value the unwinding resumes with (format note 23).
        if 4 <= h && top_kind(k, 1) is Token && top_kind(k, 2) is Token && is_val(top_kind(k, 3)) {
            Some(k.subrange(0, h - 4))
        } else { None }
    } else if is_loop(op) {
        let (lc, lb, lx, ly) = loop_operands(p, m, off);
        if loop_ok(p, m, k, lc, lb, lx, ly) { Some(k.subrange(0, h - 1)) } else { None }
    } else if op == HASH_FIND {
        let (n, mm) = (bk_of(p, m, off, 3), bk_of(p, m, off, 4));
        if hf_ok(p, m, k, n, mm) { Some(hf_kinds(k, n)) } else { None }
    } else if op == HALT {
        // HALT 2 and 3 (deep sleep, reset) only for trusted programs.
        if b1 == 0 { Some(k.push(Kind::Val)) }
        else if b1 == 1 && value_operands(k, 1) { Some(k.drop_last()) }
        else if trusted && b1 == 2 && 1 <= h { Some(k.drop_last()) }
        else if trusted && b1 >= 3 { Some(k) }
        else { None }
    } else {
        None
    }
}

/// The opcodes after which control does not fall through.
pub open spec fn is_terminator(op: u8) -> bool {
    op == RETURN || op == RETURN_NULL || op == THROW || op == BRANCH || op == BRANCH_BACK
        || op == INVOKE_STATIC_TAIL || op == INVOKE_LAMBDA_TAIL || op == INVOKE_INITIALIZER_TAIL
        || op == NON_LOCAL_RETURN || op == NON_LOCAL_BRANCH
        || op == BRANCH_S || op == BRANCH_BACK_S
}

pub open spec fn is_branch(op: u8) -> bool {
    (BRANCH <= op && op <= BRANCH_BACK_IF_NOT_NULL) || is_short_branch(op)
}

/// The frame shape every map of `m` keeps: a pinned parameter 0 stays,
/// a block's parameter 0 is its own reference.
pub open spec fn shape_ok(p: Program2, c: Cert, m: int, k: Seq<Kind>) -> bool {
    &&& (pinned0(p, m) && arity(p, m) >= 1 ==> k.len() >= 1)
    &&& (info(p, m).kind == KIND_BLOCK ==> k.len() >= 1 && match ctx_of(c, m) {
            Some(ctx) => k[0] == Kind::Block(1, ctx.slot),
            None => false,
        })
}

/// The conditions of a terminator (the successor of a branch is its
/// target).
pub open spec fn terminator_ok(p: Program2, c: Cert, m: int, off: int, k: Seq<Kind>) -> bool {
    let op = op_of(p, m, off);
    let b1 = b1_of(p, m, off);
    let w1 = w1_of(p, m, off);
    let h = k.len() as int;
    if op == RETURN {
        1 <= h && is_val(top_kind(k, 0))
    } else if op == RETURN_NULL {
        true
    } else if op == THROW {
        value_operands(k, 1)
    } else if op == INVOKE_STATIC_TAIL {
        let t = dispatch_target(p, w1);
        // Block arguments of the current frame would dangle.
        &&& valid_method(p, t)
        &&& args_ok(c, t, k, arity(p, t))
        &&& forall|j: int| h - arity(p, t) <= j < h ==> !is_local_ref(#[trigger] k[j])
    } else if op == INVOKE_LAMBDA_TAIL {
        info(p, m).kind == KIND_METHOD && h == arity(p, m) && h >= 1
            && forall|i: int| 0 <= i < h ==> is_val(#[trigger] k[i])
    } else if op == INVOKE_INITIALIZER_TAIL {
        value_operands(k, 1)
    } else if op == NON_LOCAL_RETURN {
        2 <= h && is_val(top_kind(k, 1)) && match top_kind(k, 0) { Kind::Block(d, _) => d >= 1, _ => false }
    } else if op == NON_LOCAL_BRANCH {
        1 <= h && match top_kind(k, 0) {
            Kind::Block(d, j) => d >= 1 && {
                let om = ctx_method(c, m, d as nat);
                let target = u32_at(p1(p), instr_at(p, m, off) + 2);
                match (ctx_kinds(c, m, d as nat), map_at(c, om, target)) {
                    (Some(fk), Some(t)) => valid_method(p, om) && 0 <= j + 1 - b1 && j < fk.len()
                        && t == fk.subrange(0, j + 1 - b1),
                    _ => false,
                }
            },
            _ => false,
        }
    } else if is_uncond_branch(op) {
        true
    } else {
        false
    }
}

/// The instruction at offset `off` of `m` with kinds `k` is accepted, and
/// its successors' maps agree.
pub open spec fn instr_ok(p: Program2, c: Cert, m: int, off: int, k: Seq<Kind>, trusted: bool) -> bool {
    let i = info(p, m);
    let op = op_of(p, m, off);
    let w1 = w1_of(p, m, off);
    let next_off = off + len_of(p, m, off);
    &&& 0 <= off
    &&& i.entry + off < i.end
    &&& op < OPCODE_COUNT2
    &&& raw_op_of(p, m, off) < OPCODE_COUNT2
    // The unchecked twins only in the unchecked mode (trusted programs).
    &&& (is_twin(raw_op_of(p, m, off)) ==> p.unchecked)
    &&& i.entry + off + len_of(p, m, off) <= i.end
    &&& wf_kinds(p, c, m, k)
    &&& ctx_ok(p, c, m, k)
    &&& shape_ok(p, c, m, k)
    &&& k.len() <= arity(p, m) + i.max_height
    &&& if is_terminator(op) { terminator_ok(p, c, m, off, k) } else { post(p, c, m, off, k, trusted) is Some }
    &&& match post(p, c, m, off, k, trusted) {
            Some(k2) => map_at(c, m, next_off) == Some(k2),
            None => true,
        }
    &&& if is_branch(op) {
            (is_fwd_branch(op) ==> branch_dist(p, m, off) > 0)
                && map_at(c, m, branch_target(p, m, off)) == Some(if is_uncond_branch(op) { k } else { k.drop_last() })
        } else { true }
    &&& if is_loop(op) {
            let (lc, lb, lx, ly) = loop_operands(p, m, off);
            map_at(c, m, off - w1) == Some(loop_kinds(k, lc, lb))
        } else { true }
    &&& if op == HASH_FIND { w1 > 0 && map_at(c, m, off + w1) == Some(k.push(Kind::Val)) } else { true }
}

/// The kinds at the entry of method `m`.
pub open spec fn entry_kinds(p: Program2, c: Cert, m: int) -> Seq<Kind> {
    let a = arity(p, m);
    if info(p, m).kind == KIND_BLOCK {
        Seq::new(a as nat, |i: int| if i == 0 {
            match ctx_of(c, m) { Some(ctx) => Kind::Block(1, ctx.slot), None => Kind::Param }
        } else { Kind::Val })
    } else {
        Seq::new(a as nat, |i: int| if is_block_param(c, m, i) { Kind::Param } else { Kind::Val })
    }
}

/// A block method without a context is never created (LOAD_BLOCK, TRY
/// and LOAD_OUTER_BLOCK need one), so it never runs and is not checked.
pub open spec fn dead_block(p: Program2, c: Cert, m: int) -> bool {
    info(p, m).kind == KIND_BLOCK && c.contexts[m] is None
}

pub open spec fn method_ok(p: Program2, c: Cert, m: int, trusted: bool) -> bool {
    let i = info(p, m);
    &&& i.entry < i.end <= p.bytecodes.len()
    &&& c.maps[m].len() == i.end - i.entry
    &&& c.block_params[m].len() == i.arity
    &&& (c.contexts[m] is Some ==> i.kind == KIND_BLOCK)
    &&& !dead_block(p, c, m) ==> {
        &&& c.maps[m][0] == Some(entry_kinds(p, c, m))
        &&& forall|off: int| 0 <= off < c.maps[m].len() && (#[trigger] c.maps[m][off]) is Some ==>
                instr_ok(p, c, m, off, c.maps[m][off]->0, trusted)
    }
}

// ---------------------------------------------------------------------------
// Table checks.

pub open spec fn no_block_params(c: Cert, m: int) -> bool {
    forall|i: int| 0 <= i < c.block_params[m].len() ==> !(#[trigger] c.block_params[m][i])
}

/// A builtin class of the machine's own objects (Object, Stack, Double,
/// Smi): not an instance class with fields, so the machine objects never
/// pose as instances.
pub open spec fn machine_class_ok(p: Program2, k: int) -> bool {
    let cl = builtin(p1(p), k);
    0 <= cl < class_count(p) && !(is_field_class(p, cl) && ifc(p, cl) >= 1)
}

/// The entry method `k` exists, is a plain method of arity `a` without
/// block parameters.
pub open spec fn entry_ok(p: Program2, c: Cert, k: int, a: int) -> bool {
    let e = entry_method(p, k);
    valid_method(p, e) && info(p, e).kind == KIND_METHOD && arity(p, e) == a && no_block_params(c, e)
}

/// The task class is the only class with the machine's `TASK_TAG` (the
/// machine recognizes tasks by their tag, the spec by the builtin class
/// id), so ALLOCATE cannot create a task.
pub open spec fn task_class_ok(p: Program2) -> bool {
    let tc = builtin(p1(p), TASK_CLASS);
    &&& 0 <= tc < class_count(p)
    &&& class_tag(p1(p), tc) == TASK_TAG
    &&& builtin(p1(p), EXCEPTION_CLASS) != tc
    &&& forall|cl: int| 0 <= cl < class_count(p) && #[trigger] class_tag(p1(p), cl) == TASK_TAG ==> cl == tc
}

pub open spec fn dispatch_entry_ok(p: Program2, d: int) -> bool {
    let t = p.dispatch[d] as int;
    t == -1 || (valid_method(p, t) && (info(p, t).kind == KIND_METHOD || info(p, t).kind == KIND_FIELD_ACCESSOR) && {
        // Virtual dispatch respects declared receiver ranges.
        let cl = d - info(p, t).selector as int;
        (info(p, t).selector != 0xffff && 0 <= cl < class_count(p) && has_receiver_range(info(p, t)))
            ==> info(p, t).recv_start as int <= cl < info(p, t).recv_end as int
    })
}

pub open spec fn method_table_ok(p: Program2, c: Cert, m: int) -> bool {
    let i = info(p, m);
    let s = i.selector as int;
    &&& c.block_params[m].len() == i.arity
    // Methods sharing a selector agree on arity and block parameters.
    &&& (s != 0xffff ==> s < c.sel_rep.len() && {
            let r = c.sel_rep[s];
            valid_method(p, r) && arity(p, r) == arity(p, m) && c.block_params[r] == c.block_params[m]
                && class_count(p) + s <= p.dispatch.len()
        })
    &&& (has_receiver_range(i) ==> arity(p, m) >= 1 && !c.block_params[m][0])
    &&& (i.kind == KIND_BLOCK ==> arity(p, m) >= 1 && no_block_params(c, m))
    &&& (i.kind == KIND_LAMBDA ==> no_block_params(c, m))
    &&& match c.contexts[m] {
            Some(ctx) => valid_method(p, ctx.outer),
            None => true,
        }
}

pub open spec fn sel_rep_ok(p: Program2, c: Cert, s: int) -> bool {
    let r = c.sel_rep[s];
    r == -1 || (valid_method(p, r) && info(p, r).selector as int == s)
}

pub open spec fn tables_ok(p: Program2, c: Cert) -> bool {
    &&& c.maps.len() == p.methods.len()
    &&& c.block_params.len() == p.methods.len()
    &&& c.contexts.len() == p.methods.len()
    &&& 0 <= c.global_count
    &&& c.sel_rep.len() <= 0xffff
    &&& forall|s: int| 0 <= s < c.sel_rep.len() ==> #[trigger] sel_rep_ok(p, c, s)
    &&& forall|d: int| 0 <= d < p.dispatch.len() ==> #[trigger] dispatch_entry_ok(p, d)
    &&& forall|m: int| 0 <= m < p.methods.len() ==> #[trigger] method_table_ok(p, c, m)
    &&& forall|k: int| 0 <= k < p.interface_check_offsets.len() ==>
            class_count(p) + (#[trigger] p.interface_check_offsets[k]) as int <= p.dispatch.len()
    // The builtin classes the machine allocates or dispatches on.
    &&& machine_class_ok(p, OBJECT_CLASS)
    &&& machine_class_ok(p, STACK_CLASS)
    &&& machine_class_ok(p, DOUBLE_CLASS)
    &&& machine_class_ok(p, SMI_CLASS)
    &&& is_field_class(p, builtin(p1(p), EXCEPTION_CLASS)) && ifc(p, builtin(p1(p), EXCEPTION_CLASS)) >= 2
    &&& is_field_class(p, builtin(p1(p), TASK_CLASS)) && ifc(p, builtin(p1(p), TASK_CLASS)) >= 2
    &&& task_class_ok(p)
    // The entry points the machine calls: main(task), the task entry
    // (resumed after its first instruction, LOAD_NULL), and the lazy
    // global initializer (id, initializer).
    &&& entry_ok(p, c, ENTRY_MAIN, 1) && !has_receiver_range(info(p, entry_method(p, ENTRY_MAIN)))
    &&& entry_ok(p, c, ENTRY_TASK, 1) && !has_receiver_range(info(p, entry_method(p, ENTRY_TASK)))
    &&& map_at(c, entry_method(p, ENTRY_TASK), 1) == Some(seq![Kind::Val, Kind::Val])
    &&& entry_ok(p, c, RUN_GLOBAL_INITIALIZER, 2)
}

/// The verifier accepts program `p` with certificate `c`. Trusted programs
/// (the system) may use HALT 2 and 3.
pub open spec fn accepts(p: Program2, c: Cert, trusted: bool) -> bool {
    &&& crate::v2::exec::wf_program2(p)
    // The unchecked mode (field accesses not checked) is for trusted
    // programs only (verified/core/EXPERIMENT-trusted.md).
    &&& (p.unchecked ==> trusted)
    &&& tables_ok(p, c)
    &&& forall|m: int| 0 <= m < p.methods.len() ==> #[trigger] method_ok(p, c, m, trusted)
}

} // verus!
