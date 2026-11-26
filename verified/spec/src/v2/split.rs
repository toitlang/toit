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

//! `accepts`, one method at a time.
//!
//! A certificate (`Cert`) has small global parts (block-parameter masks,
//! contexts, selector representatives, the global count, the primitive
//! table) and the maps, one array per method. The rules of a method read
//! only its own maps, except for two lookups in other methods: the target
//! map of a NON_LOCAL_BRANCH (in an outer method) and the map at offset 1
//! of the task entry (`tables_ok`). So the maps need not exist all at
//! once: `GCert` is the global part plus `pins`, the maps of other methods
//! that are looked up; method `m` is checked against `local_cert(g, m,
//! maps of m)`, which has `m`'s maps and only the pins elsewhere, and the
//! pins must agree with the maps of their methods.
//!
//! `split_ok(p, g, ms, trusted)` is that predicate, for the maps `ms` of
//! every method (the single-pass checker `v2::walk` builds them as ghost
//! state while it checks each method in one walk). The two theorems:
//!
//! * `lemma_split_sound`: `split_ok(p, g, ms, t)` implies
//!   `accepts(p, with_maps(g, ms), t)`: the certificate assembled from the
//!   pieces is accepted, so `theorem_soundness` applies to it
//!   (`theorem_soundness_split`).
//! * `lemma_split_complete`: every accepted certificate `c` gives a
//!   `split_ok` (its global part, every map as a pin, its maps), and
//!   `with_maps` gives `c` back. Hence `exists c. accepts(p, c, t)` iff
//!   `exists g, ms. split_ok(p, g, ms, t)`.
//!
//! Both rest on `lemma_method_ok_mono` and `lemma_tables_ok_mono`: the
//! rules only test maps of other methods for equality with a given
//! sequence, so a certificate whose maps agree wherever another's are
//! present accepts at least as much.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::verifier::*;
use crate::v2::sound::*;
use crate::v2::prim::*;
use crate::v2::theorem::*;
use crate::v2::bytecodes::*;
#[cfg(verus_only)]
use crate::spec_common::{u32_at, ENTRY_TASK};

verus! {

/// Offsets of the pins: method bodies are shorter (`wf_program2` bounds
/// the bytecodes by 2^28).
pub spec const PIN_SPAN: int = 0x1000_0000;

/// The global part of a certificate, and the pinned maps of other methods.
pub struct GCert {
    pub n: int,
    pub block_params: Seq<Seq<bool>>,
    pub contexts: Seq<Option<Context>>,
    pub sel_rep: Seq<int>,
    pub global_count: int,
    pub prim_arity: Seq<Seq<int>>,
    /// `pins(m, off)`: the map of method `m` at offset `off`, if pinned.
    pub pins: spec_fn(int, int) -> Option<Seq<Kind>>,
}

pub type Maps = Seq<Option<Seq<Kind>>>;

pub open spec fn with_maps(g: GCert, maps: Seq<Maps>) -> Cert {
    Cert {
        maps,
        block_params: g.block_params,
        contexts: g.contexts,
        sel_rep: g.sel_rep,
        global_count: g.global_count,
        prim_arity: g.prim_arity,
    }
}

pub open spec fn pin_at(g: GCert, m: int, o: int) -> Option<Seq<Kind>> {
    (g.pins)(m, o)
}

/// Every method's maps hold only its pins.
pub open spec fn pin_maps(g: GCert) -> Seq<Maps> {
    Seq::new(g.n as nat, |m: int| Seq::new(PIN_SPAN as nat, |o: int| pin_at(g, m, o)))
}

/// The certificate method `m` is checked against: its own maps `mm`, the
/// pins elsewhere.
pub open spec fn local_cert(g: GCert, m: int, mm: Maps) -> Cert {
    with_maps(g, if 0 <= m < g.n { pin_maps(g).update(m, mm) } else { pin_maps(g) })
}

/// The certificate the tables are checked against: only pins.
pub open spec fn tables_cert(g: GCert) -> Cert {
    with_maps(g, pin_maps(g))
}

/// Every pin is the map of its method at its offset.
pub open spec fn pins_agree(g: GCert, ms: Seq<Maps>) -> bool {
    forall|m: int, o: int| #[trigger] pin_at(g, m, o) is Some ==>
        0 <= m < ms.len() && 0 <= o < ms[m].len() && ms[m][o] == pin_at(g, m, o)
}

/// `accepts`, split by method.
pub open spec fn split_ok(p: Program2, g: GCert, ms: Seq<Maps>, trusted: bool) -> bool {
    &&& crate::v2::exec::wf_program2(p)
    &&& (p.unchecked ==> trusted)
    &&& g.n == p.methods.len()
    &&& ms.len() == g.n
    &&& tables_ok(p, tables_cert(g))
    &&& pins_agree(g, ms)
    &&& forall|m: int| 0 <= m < g.n ==> #[trigger] method_ok(p, local_cert(g, m, ms[m]), m, trusted)
}

// ---------------------------------------------------------------------------
// The rules do not read the maps of other methods except for equality.

/// Same global parts.
pub open spec fn same_g(c1: Cert, c2: Cert) -> bool {
    &&& c1.block_params == c2.block_params
    &&& c1.contexts == c2.contexts
    &&& c1.sel_rep == c2.sel_rep
    &&& c1.global_count == c2.global_count
    &&& c1.prim_arity == c2.prim_arity
}

/// `c2` has the maps of `c1` wherever `c1` has one.
pub open spec fn sub_maps(c1: Cert, c2: Cert) -> bool {
    &&& c1.maps.len() == c2.maps.len()
    &&& forall|m: int, o: int| #[trigger] map_at(c1, m, o) is Some ==> map_at(c2, m, o) == map_at(c1, m, o)
}

pub proof fn lemma_ctx_same(c1: Cert, c2: Cert, m: int, d: nat)
    requires same_g(c1, c2),
    ensures ctx_kinds(c1, m, d) == ctx_kinds(c2, m, d), ctx_method(c1, m, d) == ctx_method(c2, m, d),
    decreases d,
{
    if d > 0 {
        assert(ctx_of(c1, m) == ctx_of(c2, m));
        match ctx_of(c1, m) {
            None => {},
            Some(ctx) => {
                lemma_ctx_same(c1, c2, ctx.outer, (d - 1) as nat);
            },
        }
    }
}

pub proof fn lemma_ctx_same_all(c1: Cert, c2: Cert)
    requires same_g(c1, c2),
    ensures
        forall|m: int, d: nat| #[trigger] ctx_kinds(c1, m, d) == ctx_kinds(c2, m, d),
        forall|m: int, d: nat| #[trigger] ctx_method(c1, m, d) == ctx_method(c2, m, d),
{
    assert forall|m: int, d: nat| #[trigger] ctx_kinds(c1, m, d) == ctx_kinds(c2, m, d) by {
        lemma_ctx_same(c1, c2, m, d);
    }
    assert forall|m: int, d: nat| #[trigger] ctx_method(c1, m, d) == ctx_method(c2, m, d) by {
        lemma_ctx_same(c1, c2, m, d);
    }
}

pub proof fn lemma_frame_same(p: Program2, c1: Cert, c2: Cert, m: int, k: Seq<Kind>)
    requires same_g(c1, c2),
    ensures
        wf_kinds(p, c1, m, k) == wf_kinds(p, c2, m, k),
        ctx_ok(p, c1, m, k) == ctx_ok(p, c2, m, k),
        shape_ok(p, c1, m, k) == shape_ok(p, c2, m, k),
        forall|n: int| #[trigger] ctx_ok_upto(p, c1, m, k, n) == ctx_ok_upto(p, c2, m, k, n),
{
    lemma_ctx_same_all(c1, c2);
    assert forall|j: int| #[trigger] wf_kind(p, c1, m, k, j) == wf_kind(p, c2, m, k, j) by {}
    assert forall|i: int| #[trigger] ctx_ok_at(p, c1, m, k, i) == ctx_ok_at(p, c2, m, k, i) by {}
    if wf_kinds(p, c1, m, k) {
        assert forall|j: int| 0 <= j < k.len() implies #[trigger] wf_kind(p, c2, m, k, j) by { assert(wf_kind(p, c1, m, k, j)); }
    }
    if wf_kinds(p, c2, m, k) {
        assert forall|j: int| 0 <= j < k.len() implies #[trigger] wf_kind(p, c1, m, k, j) by { assert(wf_kind(p, c2, m, k, j)); }
    }
    if ctx_ok(p, c1, m, k) {
        assert forall|i: int| 0 <= i < k.len() && live_from(k, i) implies #[trigger] ctx_ok_at(p, c2, m, k, i) by {
            assert(ctx_ok_at(p, c1, m, k, i));
        }
    }
    if ctx_ok(p, c2, m, k) {
        assert forall|i: int| 0 <= i < k.len() && live_from(k, i) implies #[trigger] ctx_ok_at(p, c1, m, k, i) by {
            assert(ctx_ok_at(p, c2, m, k, i));
        }
    }
    assert forall|n: int| #[trigger] ctx_ok_upto(p, c1, m, k, n) == ctx_ok_upto(p, c2, m, k, n) by {
        if ctx_ok_upto(p, c1, m, k, n) {
            assert forall|i: int| 0 <= i <= n && i < k.len() implies #[trigger] ctx_ok_at(p, c2, m, k, i) by {
                assert(ctx_ok_at(p, c1, m, k, i));
            }
        }
        if ctx_ok_upto(p, c2, m, k, n) {
            assert forall|i: int| 0 <= i <= n && i < k.len() implies #[trigger] ctx_ok_at(p, c1, m, k, i) by {
                assert(ctx_ok_at(p, c2, m, k, i));
            }
        }
    }
}

pub proof fn lemma_args_same(c1: Cert, c2: Cert, t: int, k: Seq<Kind>, n: int)
    requires same_g(c1, c2),
    ensures args_ok(c1, t, k, n) == args_ok(c2, t, k, n),
{
    assert forall|x: int| #[trigger] arg_ok(c1, t, k, n, x) == arg_ok(c2, t, k, n, x) by {}
    if args_ok(c1, t, k, n) {
        assert forall|x: int| 0 <= x < n implies #[trigger] arg_ok(c2, t, k, n, x) by { assert(arg_ok(c1, t, k, n, x)); }
    }
    if args_ok(c2, t, k, n) {
        assert forall|x: int| 0 <= x < n implies #[trigger] arg_ok(c1, t, k, n, x) by { assert(arg_ok(c2, t, k, n, x)); }
    }
}

pub proof fn lemma_post_same(p: Program2, c1: Cert, c2: Cert, m: int, off: int, k: Seq<Kind>, trusted: bool)
    requires same_g(c1, c2),
    ensures post(p, c1, m, off, k, trusted) == post(p, c2, m, off, k, trusted),
{
    lemma_ctx_same_all(c1, c2);
    lemma_frame_same(p, c1, c2, m, k);
    assert forall|t: int, n: int| #[trigger] args_ok(c1, t, k, n) == args_ok(c2, t, k, n) by {
        lemma_args_same(c1, c2, t, k, n);
    }
    assert forall|sel: int, n: int| #[trigger] sel_ok(p, c1, sel, n, k) == sel_ok(p, c2, sel, n, k) by {}
}

pub proof fn lemma_instr_ok_mono(p: Program2, c1: Cert, c2: Cert, m: int, off: int, k: Seq<Kind>, trusted: bool)
    requires
        same_g(c1, c2),
        sub_maps(c1, c2),
        0 <= m < c1.maps.len(),
        c1.maps[m] == c2.maps[m],
        instr_ok(p, c1, m, off, k, trusted),
    ensures instr_ok(p, c2, m, off, k, trusted),
{
    lemma_ctx_same_all(c1, c2);
    lemma_frame_same(p, c1, c2, m, k);
    lemma_post_same(p, c1, c2, m, off, k, trusted);
    assert forall|o: int| #[trigger] map_at(c1, m, o) == map_at(c2, m, o) by {}
    let op = op_of(p, m, off);
    if is_terminator(op) {
        let h = k.len() as int;
        if op == INVOKE_STATIC_TAIL {
            lemma_args_same(c1, c2, dispatch_target(p, w1_of(p, m, off)), k, arity(p, dispatch_target(p, w1_of(p, m, off))));
        }
        if op == NON_LOCAL_BRANCH {
            match top_kind(k, 0) {
                Kind::Block(d, j) => {
                    let om = ctx_method(c1, m, d as nat);
                    let target = u32_at(p1(p), instr_at(p, m, off) + 2);
                    if map_at(c1, om, target) is Some {
                        assert(map_at(c2, om, target) == map_at(c1, om, target));
                    }
                },
                _ => {},
            }
        }
        assert(terminator_ok(p, c2, m, off, k));
    }
}

pub proof fn lemma_method_ok_mono(p: Program2, c1: Cert, c2: Cert, m: int, trusted: bool)
    requires
        same_g(c1, c2),
        sub_maps(c1, c2),
        0 <= m < c1.maps.len(),
        c1.maps[m] == c2.maps[m],
        method_ok(p, c1, m, trusted),
    ensures method_ok(p, c2, m, trusted),
{
    let i = info(p, m);
    assert(entry_kinds(p, c1, m) =~= entry_kinds(p, c2, m));
    if !dead_block(p, c2, m) {
        assert forall|off: int| 0 <= off < c2.maps[m].len() && (#[trigger] c2.maps[m][off]) is Some implies
            instr_ok(p, c2, m, off, c2.maps[m][off]->0, trusted) by {
            lemma_instr_ok_mono(p, c1, c2, m, off, c2.maps[m][off]->0, trusted);
        }
    }
}

pub proof fn lemma_tables_ok_mono(p: Program2, c1: Cert, c2: Cert)
    requires same_g(c1, c2), sub_maps(c1, c2), tables_ok(p, c1),
    ensures tables_ok(p, c2),
{
    let e = entry_method(p, ENTRY_TASK);
    assert(map_at(c1, e, 1) is Some);
    assert(map_at(c2, e, 1) == map_at(c1, e, 1));
    assert forall|mm: int| 0 <= mm < p.methods.len() implies #[trigger] method_table_ok(p, c2, mm) by {
        assert(method_table_ok(p, c1, mm));
    }
    assert forall|s: int| 0 <= s < c2.sel_rep.len() implies #[trigger] sel_rep_ok(p, c2, s) by {
        assert(sel_rep_ok(p, c1, s));
    }
}

// ---------------------------------------------------------------------------
// The theorems.

pub proof fn lemma_split_sound(p: Program2, g: GCert, ms: Seq<Maps>, trusted: bool)
    requires split_ok(p, g, ms, trusted),
    ensures accepts(p, with_maps(g, ms), trusted),
{
    let c = with_maps(g, ms);
    let tc = tables_cert(g);
    assert(same_g(tc, c));
    assert forall|m: int, o: int| #[trigger] map_at(tc, m, o) is Some implies map_at(c, m, o) == map_at(tc, m, o) by {
        assert(pin_at(g, m, o) is Some);
    }
    lemma_tables_ok_mono(p, tc, c);
    assert forall|m: int| 0 <= m < p.methods.len() implies #[trigger] method_ok(p, c, m, trusted) by {
        let lc = local_cert(g, m, ms[m]);
        assert(method_ok(p, lc, m, trusted));
        assert(same_g(lc, c));
        assert forall|m2: int, o: int| #[trigger] map_at(lc, m2, o) is Some implies map_at(c, m2, o) == map_at(lc, m2, o) by {
            if m2 != m {
                assert(pin_at(g, m2, o) is Some);
            }
        }
        lemma_method_ok_mono(p, lc, c, m, trusted);
    }
}

/// The global part of `c`, with every map of `c` as a pin.
pub open spec fn gcert_of(c: Cert) -> GCert {
    GCert {
        n: c.maps.len() as int,
        block_params: c.block_params,
        contexts: c.contexts,
        sel_rep: c.sel_rep,
        global_count: c.global_count,
        prim_arity: c.prim_arity,
        pins: |m: int, o: int| map_at(c, m, o),
    }
}

pub proof fn lemma_split_complete(p: Program2, c: Cert, trusted: bool)
    requires accepts(p, c, trusted),
    ensures split_ok(p, gcert_of(c), c.maps, trusted), with_maps(gcert_of(c), c.maps) == c,
{
    let g = gcert_of(c);
    assert(with_maps(g, c.maps) == c);
    // Every map of an accepted certificate is inside its method's body.
    assert forall|m: int, o: int| #[trigger] map_at(c, m, o) is Some implies o < PIN_SPAN by {
        assert(method_ok(p, c, m, trusted));
    }
    assert forall|m: int, o: int| #[trigger] pin_at(g, m, o) == map_at(c, m, o) by {
    }
    let tc = tables_cert(g);
    assert(same_g(c, tc));
    lemma_tables_ok_mono(p, c, tc);
    assert forall|m: int| 0 <= m < g.n implies #[trigger] method_ok(p, local_cert(g, m, c.maps[m]), m, trusted) by {
        let lc = local_cert(g, m, c.maps[m]);
        assert(same_g(c, lc));
        assert forall|m2: int, o: int| #[trigger] map_at(c, m2, o) is Some implies map_at(lc, m2, o) == map_at(c, m2, o) by {
            if m2 != m {
                assert(pin_at(g, m2, o) == map_at(c, m2, o));
            }
        }
        lemma_method_ok_mono(p, c, lc, m, trusted);
    }
}

/// `theorem_soundness` for a certificate checked one method at a time.
pub proof fn theorem_soundness_split(p: Program2, g: GCert, ms: Seq<Maps>, trusted: bool,
    heap0: Seq<HeapObj>, globals0: Seq<Value>, s: State2)
    requires
        split_ok(p, g, ms, trusted),
        loaded_ok(p, with_maps(g, ms), heap0, globals0),
        reachable(p, heap0, globals0, s),
        !p.unchecked,
    ensures
        !(step(p, s) is Stuck),
        forall|s1: State2, module: u8, index: u16, o: Outcome2|
            step(p, s) == Outcome2::Primitive(s1, module, index) && #[trigger] completion(p, s1, module, index, o)
                ==> !(o is Stuck),
        machine_objects_ok(p, s),
        step(p, s) is Primitive ==> prim_listed(g.prim_arity, (step(p, s)->Primitive_1) as int,
            (step(p, s)->Primitive_2) as int, frame_height(s)),
{
    lemma_split_sound(p, g, ms, trusted);
    theorem_soundness(p, with_maps(g, ms), trusted, heap0, globals0, s);
}

} // verus!
