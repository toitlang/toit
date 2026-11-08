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

//! The executable structural verifier: `verify(p, c, trusted)` is proven
//! to return exactly `v2::verifier::accepts(p, c, trusted)`.
//!
//! The certificate is computed by `v2::infer` (untrusted). The checker
//! works one method at a time, one instruction at a time; it does not
//! recurse and allocates only the successor kinds of the instruction it
//! checks. The certificate is an array per method indexed by offset.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::bytecodes::*;
use crate::v2::verifier::*;
#[cfg(verus_only)]
use crate::v2::exec::wf_program2;
#[cfg(verus_only)]
use crate::spec_common::{instance_field_count, u16_at, u32_at, class_tag, smi_ok, builtin, INSTANCE_TAG,
    EXCEPTION_CLASS, STACK_CLASS, TASK_CLASS, DOUBLE_CLASS, SMI_CLASS, ENTRY_MAIN, ENTRY_TASK,
    RUN_GLOBAL_INITIALIZER};

verus! {

#[derive(PartialEq, Eq, Clone, Copy, Debug)]
pub enum XKind {
    Val,
    Method(u32),
    Block(u32, u32),
    Param,
    Token,
}

impl View for XKind {
    type V = Kind;
    open spec fn view(&self) -> Kind {
        match *self {
            XKind::Val => Kind::Val,
            XKind::Method(t) => Kind::Method(t as int),
            XKind::Block(d, s) => Kind::Block(d as int, s as int),
            XKind::Param => Kind::Param,
            XKind::Token => Kind::Token,
        }
    }
}

pub struct XContext {
    pub outer: u32,
    pub slot: u32,
    pub kinds: Vec<XKind>,
}

pub struct XCert {
    pub maps: Vec<Vec<Option<Vec<XKind>>>>,
    pub block_params: Vec<Vec<bool>>,
    pub contexts: Vec<Option<XContext>>,
    pub sel_rep: Vec<i64>,
    pub global_count: u64,
    pub prim_arity: Vec<Vec<u8>>,
}

pub open spec fn kv(k: Vec<XKind>) -> Seq<Kind> {
    k@.map_values(|x: XKind| x@)
}

pub open spec fn okv(o: Option<Vec<XKind>>) -> Option<Seq<Kind>> {
    match o { Some(k) => Some(kv(k)), None => None }
}

pub open spec fn ctxv(o: Option<XContext>) -> Option<Context> {
    match o { Some(x) => Some(Context { outer: x.outer as int, slot: x.slot as int, kinds: kv(x.kinds) }), None => None }
}

impl View for XCert {
    type V = Cert;
    open spec fn view(&self) -> Cert {
        Cert {
            maps: self.maps@.map_values(|v: Vec<Option<Vec<XKind>>>| v@.map_values(|o: Option<Vec<XKind>>| okv(o))),
            block_params: self.block_params@.map_values(|v: Vec<bool>| v@),
            contexts: self.contexts@.map_values(|o: Option<XContext>| ctxv(o)),
            sel_rep: self.sel_rep@.map_values(|r: i64| r as int),
            global_count: self.global_count as int,
            prim_arity: self.prim_arity@.map_values(|v: Vec<u8>| v@.map_values(|a: u8| a as int)),
        }
    }
}

// ---------------------------------------------------------------------------
// Small helpers.

pub fn x_kinds_eq(a: &Vec<XKind>, b: &Vec<XKind>) -> (r: bool)
    ensures r == (kv(*a) == kv(*b)),
{
    if a.len() != b.len() {
        return false;
    }
    let mut i = 0;
    while i < a.len() {
        if a[i] != b[i] {
            return false;
        }
        i += 1;
    }
    true
}

pub fn x_info(p: &ExecProgram, m: usize) -> (r: MethodInfo)
    requires m < p.methods.len(),
    ensures r == info(pview2(p), m as int),
{
    p.methods[m]
}

pub fn x_u16(p: &ExecProgram, i: usize) -> (r: i64)
    requires i + 2 <= p.bytecodes.len(),
    ensures r as int == u16_at(p1(pview2(p)), i as int), 0 <= r < 0x10000,
{
    (p.bytecodes[i] as i64) + 256 * (p.bytecodes[i + 1] as i64)
}

pub fn x_u32(p: &ExecProgram, i: usize) -> (r: i64)
    requires i + 4 <= p.bytecodes.len(),
    ensures r as int == u32_at(p1(pview2(p)), i as int), 0 <= r < 0x1_0000_0000,
{
    x_u16(p, i) + 65536 * x_u16(p, i + 2)
}

pub fn x_class_count(p: &ExecProgram) -> (r: i64)
    ensures r as int == class_count(pview2(p)),
{
    p.class_bits.len() as i64
}

pub fn x_is_instance_class(p: &ExecProgram, cl: i64) -> (r: bool)
    ensures r == is_instance_class(pview2(p), cl as int),
{
    0 <= cl && cl < p.class_bits.len() as i64 && (p.class_bits[cl as usize] & 0xf) == 2
}

pub fn x_is_field_class(p: &ExecProgram, cl: i64) -> (r: bool)
    ensures r == is_field_class(pview2(p), cl as int),
{
    0 <= cl && cl < p.class_bits.len() as i64
        && ((p.class_bits[cl as usize] & 0xf) == 2 || (p.class_bits[cl as usize] & 0xf) == 8)
}

pub fn x_ifc(p: &ExecProgram, cl: usize) -> (r: i64)
    requires cl < p.class_bits.len(),
    ensures r as int == ifc(pview2(p), cl as int),
{
    (((p.class_bits[cl] >> 5u16) & 0x7ff) as i64) - 1
}

pub fn x_smi_ok(p: &ExecProgram, v: i64) -> (r: bool)
    requires 0 <= v < 0x1_0000_0000,
    ensures r == smi_ok(p1(pview2(p)), v as int),
{
    p.word_bits != 32 || v <= 0x3fff_ffff
}

pub fn x_valid(p: &ExecProgram, t: i64) -> (r: bool)
    ensures r == valid_method(pview2(p), t as int),
{
    0 <= t && t < p.methods.len() as i64
}

pub fn x_is_val(k: XKind) -> (r: bool)
    ensures r == is_val(k@),
{
    match k { XKind::Val => true, XKind::Method(_) => true, _ => false }
}

pub fn x_is_ref(k: XKind) -> (r: bool)
    ensures r == is_ref(k@),
{
    match k { XKind::Block(_, _) => true, XKind::Param => true, _ => false }
}

pub fn x_is_block_param(c: &XCert, m: usize, i: usize) -> (r: bool)
    ensures r == is_block_param(c@, m as int, i as int),
{
    m < c.block_params.len() && i < c.block_params[m].len() && c.block_params[m][i]
}

pub fn x_ctx_of(c: &XCert, t: usize) -> (r: Option<&XContext>)
    ensures ctxv(match r { Some(x) => Some(*x), None => None }) == ctx_of(c@, t as int),
{
    if t < c.contexts.len() {
        match &c.contexts[t] {
            Some(x) => Some(x),
            None => None,
        }
    } else {
        None
    }
}

// ---------------------------------------------------------------------------
// Block slots and contexts.

pub fn x_block_slot(p: &ExecProgram, c: &XCert, om: i64, fk: &Vec<XKind>, i: i64) -> (r: bool)
    ensures r == block_slot(pview2(p), c@, om as int, kv(*fk), i as int),
{
    if i < 0 || i as usize >= fk.len() {
        return false;
    }
    match fk[i as usize] {
        XKind::Method(t) => {
            if !(x_valid(p, t as i64) && p.methods[t as usize].kind == 3) {
                return false;
            }
            match x_ctx_of(c, t as usize) {
                Some(ctx) => ctx.outer as i64 == om && ctx.slot as i64 == i,
                None => false,
            }
        },
        _ => false,
    }
}

/// The context `depth` levels out: its kinds and method.
pub fn x_ctx_kinds<'a>(c: &'a XCert, m: i64, depth: u32) -> (r: (Option<&'a Vec<XKind>>, i64))
    requires depth >= 1,
    ensures
        okv(match r.0 { Some(k) => Some(*k), None => None }) == ctx_kinds(c@, m as int, depth as nat),
        r.1 as int == ctx_method(c@, m as int, depth as nat),
{
    let mut cur = m;
    let mut d = depth;
    loop {
        if cur < 0 || cur as usize >= c.contexts.len() {
            return (None, -1);
        }
        match &c.contexts[cur as usize] {
            None => return (None, -1),
            Some(ctx) => {
                if d == 1 {
                    return (Some(&ctx.kinds), ctx.outer as i64);
                }
                cur = ctx.outer as i64;
                d = d - 1;
            },
        }
    }
}

pub fn x_wf_kinds(p: &ExecProgram, c: &XCert, m: i64, k: &Vec<XKind>) -> (r: bool)
    ensures r == wf_kinds(pview2(p), c@, m as int, kv(*k)),
{
    let mut j = 0;
    while j < k.len() {
        match k[j] {
            XKind::Block(d, i) => {
                if d == 0 {
                    if !((i as usize) < j && x_block_slot(p, c, m, k, i as i64)) {
                        return false;
                    }
                } else {
                    let (fk, om) = x_ctx_kinds(c, m, d);
                    match fk {
                        None => return false,
                        Some(fk) => if !x_block_slot(p, c, om, fk, i as i64) { return false; },
                    }
                }
            },
            _ => {},
        }
        j += 1;
    }
    true
}

pub fn x_ctx_ok_at(p: &ExecProgram, c: &XCert, m: i64, k: &Vec<XKind>, i: usize) -> (r: bool)
    requires i < k.len(),
    ensures r == ctx_ok_at(pview2(p), c@, m as int, kv(*k), i as int),
{
    if !x_block_slot(p, c, m, k, i as i64) {
        return true;
    }
    let t = match k[i] { XKind::Method(t) => t, _ => 0 };
    match x_ctx_of(c, t as usize) {
        Some(ctx) => {
            let ck = &ctx.kinds;
            if ck.len() != i + 1 {
                return false;
            }
            let mut j = 0;
            while j <= i {
                if k[j] != ck[j] {
                    return false;
                }
                j += 1;
            }
            true
        },
        None => true,
    }
}

pub fn x_ctx_ok_upto(p: &ExecProgram, c: &XCert, m: i64, k: &Vec<XKind>, n: usize) -> (r: bool)
    ensures r == ctx_ok_upto(pview2(p), c@, m as int, kv(*k), n as int),
{
    let mut i = 0;
    while i <= n && i < k.len() {
        if !x_ctx_ok_at(p, c, m, k, i) {
            return false;
        }
        i += 1;
    }
    true
}

pub fn x_ctx_ok(p: &ExecProgram, c: &XCert, m: i64, k: &Vec<XKind>) -> (r: bool)
    ensures r == ctx_ok(pview2(p), c@, m as int, kv(*k)),
{
    // The highest slot a reference of this frame points to.
    let mut top: i64 = -1;
    let mut j = 0;
    while j < k.len() {
        match k[j] {
            XKind::Block(0, s) => if s as i64 > top { top = s as i64; },
            _ => {},
        }
        j += 1;
    }
    if top < 0 {
        return true;
    }
    x_ctx_ok_upto(p, c, m, k, top as usize)
}

pub fn x_referenced(k: &Vec<XKind>, i: usize) -> (r: bool)
    ensures r == referenced(kv(*k), i as int),
{
    let mut j = 0;
    while j < k.len() {
        if (i as u64) < 0x1_0000_0000u64 && k[j] == XKind::Block(0, i as u32) {
            return true;
        }
        j += 1;
    }
    false
}

pub fn x_below_token(k: &Vec<XKind>, i: usize) -> (r: bool)
    ensures r == below_token(kv(*k), i as int),
{
    let mut j = i + 1;
    while j < k.len() {
        if k[j] == XKind::Token {
            return true;
        }
        j += 1;
    }
    false
}

pub fn x_pinned0(p: &ExecProgram, m: usize) -> (r: bool)
    requires m < p.methods.len(),
    ensures r == pinned0(pview2(p), m as int),
{
    p.methods[m].recv_start != 0xffff || p.methods[m].kind == 3
}

pub fn x_writable(p: &ExecProgram, m: usize, k: &Vec<XKind>, i: usize, v: XKind) -> (r: bool)
    requires m < p.methods.len(),
    ensures r == writable(pview2(p), m as int, kv(*k), i as int, v@),
{
    if i >= k.len() { return false; }
    if i == 0 && x_pinned0(p, m) { return false; }
    if x_referenced(k, i) { return false; }
    if k[i] == XKind::Token || v == XKind::Token { return false; }
    if x_below_token(k, i) && !(k[i] == XKind::Val && x_is_val(v)) { return false; }
    true
}

pub fn x_args_ok(c: &XCert, t: usize, k: &Vec<XKind>, n: usize) -> (r: bool)
    ensures r == args_ok(c@, t as int, kv(*k), n as int),
{
    if n > k.len() { return false; }
    let base = k.len() - n;
    let mut x = 0;
    while x < n {
        let kd = k[base + x];
        if x_is_block_param(c, t, x) {
            if !x_is_ref(kd) { return false; }
        } else {
            if !x_is_val(kd) { return false; }
        }
        match kd {
            XKind::Block(d, i) => if d == 0 && (i as usize) >= base { return false; },
            _ => {},
        }
        x += 1;
    }
    true
}

pub fn x_value_operands(k: &Vec<XKind>, n: usize) -> (r: bool)
    ensures r == value_operands(kv(*k), n as int),
{
    if n > k.len() { return false; }
    let mut i = 0;
    while i < n {
        if !x_is_val(k[k.len() - 1 - i]) { return false; }
        i += 1;
    }
    true
}

pub fn x_sel_ok(p: &ExecProgram, c: &XCert, sel: i64, n: usize, k: &Vec<XKind>) -> (r: bool)
    ensures r == sel_ok(pview2(p), c@, sel as int, n as int, kv(*k)),
{
    if !(1 <= n && n <= k.len()) { return false; }
    if !(0 <= sel && sel < 0xffff) { return false; }
    if sel as usize >= c.sel_rep.len() { return false; }
    if (p.class_bits.len() as u64) + (sel as u64) > p.dispatch.len() as u64 { return false; }
    if !x_is_val(k[k.len() - n]) { return false; }
    let r = c.sel_rep[sel as usize];
    if r == -1 { return true; }
    x_valid(p, r) && p.methods[r as usize].arity as usize == n && x_args_ok(c, r as usize, k, n)
}

pub fn x_typecheck_index_ok(p: &ExecProgram, op: u8, enc: i64) -> (r: bool)
    requires 0 <= enc < 0x10000,
    ensures r == typecheck_index_ok(pview2(p), op, enc as int),
{
    let index = enc / 2;
    if op == IS_INTERFACE || op == IS_INTERFACE_WIDE || op == AS_INTERFACE || op == AS_INTERFACE_WIDE {
        (index as usize) < p.interface_check_offsets.len()
    } else {
        ((2 * index + 1) as usize) < p.class_check_ids.len()
    }
}

pub fn x_this_field_ok(p: &ExecProgram, m: usize, f: i64) -> (r: bool)
    requires m < p.methods.len(),
    ensures r == this_field_ok(pview2(p), m as int, f as int),
{
    let i = p.methods[m];
    if i.recv_start == 0xffff || i.arity < 1 || !(i.kind == 0 || i.kind == 1) {
        return false;
    }
    if i.recv_end as usize > p.class_bits.len() {
        return false;
    }
    let mut cl = i.recv_start;
    while cl < i.recv_end {
        if !x_is_field_class(p, cl as i64) || !(f < x_ifc(p, cl as usize)) {
            return false;
        }
        cl += 1;
    }
    true
}

pub fn x_push(k: &Vec<XKind>, v: XKind) -> (r: Vec<XKind>)
    ensures kv(r) == kv(*k).push(v@),
{
    let mut r = k.clone();
    r.push(v);
    r
}

pub fn x_prefix(k: &Vec<XKind>, n: usize) -> (r: Vec<XKind>)
    requires n <= k.len(),
    ensures kv(r) == kv(*k).subrange(0, n as int),
{
    let mut r = Vec::with_capacity(n);
    let mut i = 0;
    while i < n {
        r.push(k[i]);
        i += 1;
    }
    r
}

pub fn x_update(k: &Vec<XKind>, i: usize, v: XKind) -> (r: Vec<XKind>)
    requires i < k.len(),
    ensures kv(r) == kv(*k).update(i as int, v@),
{
    let mut r = k.clone();
    r.set(i, v);
    r
}

pub fn x_shift(k: XKind, d: u32) -> (r: Option<XKind>)
    ensures r is Some ==> r->0@ == shift(k@, d as int),
{
    match k {
        XKind::Block(d1, s) => if d1 <= u32::MAX - d { Some(XKind::Block(d1 + d, s)) } else { None },
        XKind::Method(_) => Some(XKind::Val),
        _ => Some(k),
    }
}

pub fn x_dispatch_target(p: &ExecProgram, d: i64) -> (r: i64)
    ensures r as int == dispatch_target(pview2(p), d as int),
{
    if 0 <= d && (d as usize) < p.dispatch.len() { p.dispatch[d as usize] as i64 } else { -1 }
}

// ---------------------------------------------------------------------------
// Instructions.

/// `post`: the fall-through successor kinds.
pub fn x_post(p: &ExecProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool) -> (r: Option<Vec<XKind>>)
    requires
        wf_program2(pview2(p)),
        m < p.methods.len(),
        p.methods[m as int].entry + off + opcode_length2(p.bytecodes[p.methods[m as int].entry + off]) <= p.methods[m as int].end,
        p.bytecodes[p.methods[m as int].entry + off] < OPCODE_COUNT2,
    ensures okv(r) == post(pview2(p), c@, m as int, off as int, kv(*k), trusted),
{
    let bci = p.methods[m].entry + off;
    let op = p.bytecodes[bci];
    let len = crate::v2::bytecodes::exec_opcode_length2(op);
    let b1: i64 = if len >= 2 { p.bytecodes[bci + 1] as i64 } else { 0 };
    let w1: i64 = if len >= 3 { x_u16(p, bci + 1) } else { 0 };
    let h = k.len();
    if op == LOAD_LOCAL || op == LOAD_LOCAL_WIDE || (LOAD_LOCAL_0 <= op && op <= LOAD_LOCAL_5) {
        let n = if op == LOAD_LOCAL { b1 } else if op == LOAD_LOCAL_WIDE { w1 } else { (op - LOAD_LOCAL_0) as i64 };
        if (n as usize) < h && k[h - 1 - n as usize] != XKind::Token { Some(x_push(k, k[h - 1 - n as usize])) } else { None }
    } else if op == POP_LOAD_LOCAL {
        if (b1 as usize) + 1 < h && k[h - 2 - b1 as usize] != XKind::Token { Some(x_update(k, h - 1, k[h - 2 - b1 as usize])) } else { None }
    } else if op == STORE_LOCAL || op == STORE_LOCAL_POP {
        if 1 <= b1 && (b1 as usize) < h {
            let i = h - 1 - b1 as usize;
            let v = k[h - 1];
            if x_writable(p, m, k, i, v) {
                let mut k1 = x_update(k, i, v);
                if op == STORE_LOCAL_POP { k1.pop(); }
                Some(k1)
            } else { None }
        } else { None }
    } else if op == LOAD_OUTER || op == STORE_OUTER || op == LOAD_OUTER_BLOCK {
        let r: usize = if op == STORE_OUTER { 1 } else { 0 };
        if r >= h { return None; }
        match k[h - 1 - r] {
            XKind::Block(d, j) => {
                let (fk, om): (Option<&Vec<XKind>>, i64) = if d == 0 { (Some(k), m as i64) } else { x_ctx_kinds(c, m as i64, d) };
                match fk {
                    None => None,
                    Some(fk) => {
                        if !((b1 as u64) <= (j as u64) && (j as usize) < fk.len()) {
                            return None;
                        }
                        let i = (j as i64 - b1) as usize;
                        if op == LOAD_OUTER {
                            if fk[i] == XKind::Token { None } else {
                                match x_shift(fk[i], d) {
                                    Some(sk) => Some(x_update(k, h - 1, sk)),
                                    None => None,
                                }
                            }
                        } else if op == LOAD_OUTER_BLOCK {
                            if x_block_slot(p, c, om, fk, i as i64) { Some(x_update(k, h - 1, XKind::Block(d, i as u32))) } else { None }
                        } else if d >= 1 && fk[i] == XKind::Val && x_is_val(k[h - 1]) && x_valid(p, om)
                                && !(i == 0 && x_pinned0(p, om as usize)) {
                            let mut k1 = x_prefix(k, h - 2);
                            k1.push(XKind::Val);
                            Some(k1)
                        } else { None }
                    },
                }
            },
            _ => None,
        }
    } else if op == LOAD_BLOCK {
        let i = h as i64 - 1 - b1;
        if x_block_slot(p, c, m as i64, k, i) { Some(x_push(k, XKind::Block(0, i as u32))) } else { None }
    } else if op == LOAD_FIELD || op == LOAD_FIELD_WIDE {
        if x_value_operands(k, 1) { Some(x_update(k, h - 1, XKind::Val)) } else { None }
    } else if op == LOAD_FIELD_LOCAL || op == POP_LOAD_FIELD_LOCAL {
        let slot = if op == POP_LOAD_FIELD_LOCAL { (b1 % 16 + 1) as usize } else { (b1 % 16) as usize };
        if slot < h && x_is_val(k[h - 1 - slot]) {
            Some(if op == LOAD_FIELD_LOCAL { x_push(k, XKind::Val) } else { x_update(k, h - 1, XKind::Val) })
        } else { None }
    } else if op == STORE_FIELD || op == STORE_FIELD_WIDE || op == STORE_FIELD_POP {
        if x_value_operands(k, 2) {
            let mut k1 = x_prefix(k, h - 2);
            if op != STORE_FIELD_POP { k1.push(XKind::Val); }
            Some(k1)
        } else { None }
    } else if op == LOAD_FIELD_THIS {
        if x_this_field_ok(p, m, b1) { Some(x_push(k, XKind::Val)) } else { None }
    } else if op == STORE_FIELD_THIS {
        if x_this_field_ok(p, m, b1) && x_value_operands(k, 1) { Some(k.clone()) } else { None }
    } else if op == LOAD_LITERAL || op == LOAD_LITERAL_WIDE {
        let i = if op == LOAD_LITERAL { b1 } else { w1 };
        if (i as usize) < p.literals.len() { Some(x_push(k, XKind::Val)) } else { None }
    } else if op == LOAD_NULL || op == LOAD_SMI_0 || op == LOAD_SMI_1 || op == LOAD_SMI_U8 || op == LOAD_SMI_U16 {
        Some(x_push(k, XKind::Val))
    } else if op == LOAD_SMI_U32 {
        if x_smi_ok(p, x_u32(p, bci + 1)) { Some(x_push(k, XKind::Val)) } else { None }
    } else if op == LOAD_SMIS_0 {
        let mut k1 = k.clone();
        let mut i = 0;
        while i < b1 {
            k1.push(XKind::Val);
            i += 1;
        }
        Some(k1)
    } else if op == LOAD_METHOD {
        let t = x_u32(p, bci + 1);
        if x_valid(p, t) && x_smi_ok(p, t) { Some(x_push(k, XKind::Method(t as u32))) } else { None }
    } else if op == LOAD_GLOBAL_VAR || op == LOAD_GLOBAL_VAR_LAZY {
        if (b1 as u64) < c.global_count { Some(x_push(k, XKind::Val)) } else { None }
    } else if op == LOAD_GLOBAL_VAR_WIDE || op == LOAD_GLOBAL_VAR_LAZY_WIDE {
        if (w1 as u64) < c.global_count { Some(x_push(k, XKind::Val)) } else { None }
    } else if op == STORE_GLOBAL_VAR || op == STORE_GLOBAL_VAR_WIDE {
        let g = if op == STORE_GLOBAL_VAR { b1 } else { w1 };
        if (g as u64) < c.global_count && x_value_operands(k, 1) { Some(k.clone()) } else { None }
    } else if op == LOAD_GLOBAL_VAR_DYNAMIC {
        if x_value_operands(k, 1) { Some(x_update(k, h - 1, XKind::Val)) } else { None }
    } else if op == STORE_GLOBAL_VAR_DYNAMIC {
        if x_value_operands(k, 2) { Some(x_prefix(k, h - 2)) } else { None }
    } else if op == POP || op == POP_1 {
        let n = if op == POP { b1 as usize } else { 1 };
        if n <= h { Some(x_prefix(k, h - n)) } else { None }
    } else if op == ALLOCATE || op == ALLOCATE_WIDE {
        let cl = if op == ALLOCATE { b1 } else { w1 };
        if x_is_instance_class(p, cl) && x_ifc(p, cl as usize) >= 0 { Some(x_push(k, XKind::Val)) } else { None }
    } else if IS_CLASS <= op && op <= AS_INTERFACE_WIDE {
        if x_value_operands(k, 1) && x_typecheck_index_ok(p, op, if op % 2 == 0 { b1 } else { w1 }) {
            Some(if op <= IS_INTERFACE_WIDE { x_update(k, h - 1, XKind::Val) } else { k.clone() })
        } else { None }
    } else if op == AS_LOCAL {
        if ((b1 / 32) as usize) < h && x_is_val(k[h - 1 - (b1 / 32) as usize]) && ((2 * (b1 % 32) + 1) as usize) < p.class_check_ids.len() {
            Some(k.clone())
        } else { None }
    } else if op == INVOKE_STATIC {
        let t = x_dispatch_target(p, w1);
        if x_valid(p, t) && x_args_ok(c, t as usize, k, p.methods[t as usize].arity as usize) {
            let a = p.methods[t as usize].arity as usize;
            let mut k1 = x_prefix(k, h - a);
            k1.push(XKind::Val);
            Some(k1)
        } else { None }
    } else if op == INVOKE_BLOCK {
        if 1 <= b1 && (b1 as usize) <= h && x_is_ref(k[h - b1 as usize]) && x_value_operands(k, (b1 - 1) as usize)
            && match k[h - b1 as usize] { XKind::Block(d, i) => !(d == 0 && (i as usize) >= h - b1 as usize), _ => true } {
            let mut k1 = x_prefix(k, h - b1 as usize);
            k1.push(XKind::Val);
            Some(k1)
        } else { None }
    } else if op == INVOKE_VIRTUAL || op == INVOKE_VIRTUAL_WIDE {
        let n = if op == INVOKE_VIRTUAL { b1 + 1 } else { w1 + 1 };
        let sel = if op == INVOKE_VIRTUAL { x_u16(p, bci + 2) } else { x_u16(p, bci + 3) };
        if x_sel_ok(p, c, sel, n as usize, k) {
            let mut k1 = x_prefix(k, h - n as usize);
            k1.push(XKind::Val);
            Some(k1)
        } else { None }
    } else if op == INVOKE_VIRTUAL_GET || op == INVOKE_SIZE {
        if x_sel_ok(p, c, w1, 1, k) { Some(x_update(k, h - 1, XKind::Val)) } else { None }
    } else if op == INVOKE_VIRTUAL_SET {
        if x_value_operands(k, 2) && x_sel_ok(p, c, w1, 2, k) {
            let mut k1 = x_prefix(k, h - 2);
            k1.push(XKind::Val);
            Some(k1)
        } else { None }
    } else if INVOKE_EQ <= op && op <= INVOKE_AT_PUT {
        let n: usize = if op == INVOKE_AT_PUT { 3 } else { 2 };
        let sel = p.invoke_offsets[(op - INVOKE_EQ) as usize] as i64;
        if x_value_operands(k, n) && (sel < 0 || x_sel_ok(p, c, sel, n, k)) {
            let mut k1 = x_prefix(k, h - n);
            k1.push(XKind::Val);
            Some(k1)
        } else { None }
    } else if op == IDENTICAL {
        if x_value_operands(k, 2) {
            let mut k1 = x_prefix(k, h - 2);
            k1.push(XKind::Val);
            Some(k1)
        } else { None }
    } else if (BRANCH_IF_TRUE <= op && op <= BRANCH_IF_NOT_NULL) || (BRANCH_BACK_IF_TRUE <= op && op <= BRANCH_BACK_IF_NOT_NULL) {
        if x_value_operands(k, 1) { Some(x_prefix(k, h - 1)) } else { None }
    } else if op == PRIMITIVE {
        let index = x_u16(p, bci + 2);
        let a = p.methods[m].arity as usize;
        if !(h == a && p.methods[m].kind == 0) { return None; }
        if !((b1 as usize) < c.prim_arity.len() && (index as usize) < c.prim_arity[b1 as usize].len()
            && c.prim_arity[b1 as usize][index as usize] as usize == a) {
            return None;
        }
        if b1 == 0 && index == X_PRIM_TASK_NEW as i64 && a != 1 { return None; }
        if b1 == 0 && index == X_PRIM_TASK_TRANSFER as i64 && a != 2 { return None; }
        Some(x_push(k, XKind::Val))
    } else if op == TRY {
        if 1 <= h && x_block_slot(p, c, m as i64, k, (h - 1) as i64) {
            let t = match k[h - 1] { XKind::Method(t) => t, _ => 0 };
            if p.methods[t as usize].arity == 1 && x_ctx_ok_upto(p, c, m as i64, k, h - 1) {
                let mut k1 = k.clone();
                k1.push(XKind::Val);
                k1.push(XKind::Token);
                k1.push(XKind::Val);
                Some(k1)
            } else { None }
        } else { None }
    } else if op == UNWIND {
        if 3 <= h && k[h - 2] == XKind::Token { Some(x_prefix(k, h - 3)) } else { None }
    } else if op == HALT {
        if b1 == 0 { Some(x_push(k, XKind::Val)) }
        else if b1 == 1 && x_value_operands(k, 1) { Some(x_prefix(k, h - 1)) }
        else if trusted && b1 == 2 && 1 <= h { Some(x_prefix(k, h - 1)) }
        else if trusted && b1 >= 3 { Some(k.clone()) }
        else { None }
    } else {
        None
    }
}

pub fn x_is_terminator(op: u8) -> (r: bool)
    ensures r == is_terminator(op),
{
    op == RETURN || op == RETURN_NULL || op == THROW || op == BRANCH || op == BRANCH_BACK
        || op == INVOKE_STATIC_TAIL || op == INVOKE_LAMBDA_TAIL || op == INVOKE_INITIALIZER_TAIL
        || op == NON_LOCAL_RETURN || op == NON_LOCAL_BRANCH
}

pub fn x_map_at<'a>(c: &'a XCert, m: i64, off: i64) -> (r: Option<&'a Vec<XKind>>)
    ensures okv(match r { Some(k) => Some(*k), None => None }) == map_at(c@, m as int, off as int),
{
    if 0 <= m && (m as usize) < c.maps.len() && 0 <= off && (off as usize) < c.maps[m as usize].len() {
        match &c.maps[m as usize][off as usize] {
            Some(k) => Some(k),
            None => None,
        }
    } else {
        None
    }
}

pub fn x_map_is(c: &XCert, m: i64, off: i64, k: &Vec<XKind>) -> (r: bool)
    ensures r == (map_at(c@, m as int, off as int) == Some(kv(*k))),
{
    match x_map_at(c, m, off) {
        Some(k2) => x_kinds_eq(k2, k),
        None => false,
    }
}

pub fn x_terminator_ok(p: &ExecProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>) -> (r: bool)
    requires
        wf_program2(pview2(p)),
        m < p.methods.len(),
        p.methods[m as int].entry + off + opcode_length2(p.bytecodes[p.methods[m as int].entry + off]) <= p.methods[m as int].end,
        p.bytecodes[p.methods[m as int].entry + off] < OPCODE_COUNT2,
    ensures r == terminator_ok(pview2(p), c@, m as int, off as int, kv(*k)),
{
    let bci = p.methods[m].entry + off;
    let op = p.bytecodes[bci];
    let h = k.len();
    if op == RETURN {
        1 <= h && x_is_val(k[h - 1])
    } else if op == RETURN_NULL {
        true
    } else if op == THROW {
        x_value_operands(k, 1)
    } else if op == INVOKE_STATIC_TAIL {
        let t = x_dispatch_target(p, x_u16(p, bci + 1));
        if !x_valid(p, t) { return false; }
        let a = p.methods[t as usize].arity as usize;
        if !x_args_ok(c, t as usize, k, a) { return false; }
        let mut j = h - a;
        while j < h {
            match k[j] { XKind::Block(0, _) => return false, _ => {} }
            j += 1;
        }
        true
    } else if op == INVOKE_LAMBDA_TAIL {
        if !(p.methods[m].kind == 0 && h == p.methods[m].arity as usize && h >= 1) { return false; }
        let mut i = 0;
        while i < h {
            if !x_is_val(k[i]) { return false; }
            i += 1;
        }
        true
    } else if op == INVOKE_INITIALIZER_TAIL {
        x_value_operands(k, 1)
    } else if op == NON_LOCAL_RETURN {
        2 <= h && x_is_val(k[h - 2]) && match k[h - 1] { XKind::Block(d, _) => d >= 1, _ => false }
    } else if op == NON_LOCAL_BRANCH {
        if h < 1 { return false; }
        match k[h - 1] {
            XKind::Block(d, j) => {
                if d < 1 { return false; }
                let (fk, om) = x_ctx_kinds(c, m as i64, d);
                let b1 = p.bytecodes[bci + 1] as i64;
                let target = x_u32(p, bci + 2);
                match (fk, x_map_at(c, om, target)) {
                    (Some(fk), Some(t)) => {
                        if !(x_valid(p, om) && b1 <= j as i64 + 1 && (j as usize) < fk.len()) { return false; }
                        let n = (j as i64 + 1 - b1) as usize;
                        if t.len() != n { return false; }
                        let mut i = 0;
                        while i < n {
                            if t[i] != fk[i] { return false; }
                            i += 1;
                        }
                        true
                    },
                    _ => false,
                }
            },
            _ => false,
        }
    } else if op == BRANCH || op == BRANCH_BACK {
        true
    } else {
        false
    }
}

pub fn x_shape_ok(p: &ExecProgram, c: &XCert, m: usize, k: &Vec<XKind>) -> (r: bool)
    requires m < p.methods.len(),
    ensures r == shape_ok(pview2(p), c@, m as int, kv(*k)),
{
    if x_pinned0(p, m) && p.methods[m].arity >= 1 && k.len() < 1 { return false; }
    if p.methods[m].kind == 3 {
        if k.len() < 1 { return false; }
        match x_ctx_of(c, m) {
            Some(ctx) => k[0] == XKind::Block(1, ctx.slot),
            None => false,
        }
    } else {
        true
    }
}

pub fn x_instr_ok(p: &ExecProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool) -> (r: bool)
    requires wf_program2(pview2(p)), m < p.methods.len(),
    ensures r == instr_ok(pview2(p), c@, m as int, off as int, kv(*k), trusted),
{
    let i = p.methods[m];
    if !(off < i.end - i.entry) { return false; }
    let bci = i.entry + off;
    let op = p.bytecodes[bci];
    if op >= OPCODE_COUNT2 { return false; }
    let len = crate::v2::bytecodes::exec_opcode_length2(op);
    if bci + len > i.end { return false; }
    if !x_wf_kinds(p, c, m as i64, k) || !x_ctx_ok(p, c, m as i64, k) || !x_shape_ok(p, c, m, k) {
        return false;
    }
    if k.len() > i.arity as usize + i.max_height as usize { return false; }
    let post = x_post(p, c, m, off, k, trusted);
    if x_is_terminator(op) {
        if !x_terminator_ok(p, c, m, off, k) { return false; }
    } else if post.is_none() {
        return false;
    }
    match &post {
        Some(k2) => if !x_map_is(c, m as i64, (off + len) as i64, k2) { return false; },
        None => {},
    }
    if BRANCH <= op && op <= BRANCH_BACK_IF_NOT_NULL {
        let w1 = x_u16(p, bci + 1);
        let t = if op <= BRANCH_IF_NOT_NULL { off as i64 + w1 } else { off as i64 - w1 };
        if op <= BRANCH_IF_NOT_NULL && w1 <= 0 { return false; }
        if op == BRANCH || op == BRANCH_BACK {
            if !x_map_is(c, m as i64, t, k) { return false; }
        } else {
            if k.len() < 1 { return false; }
            let k1 = x_prefix(k, k.len() - 1);
            if !x_map_is(c, m as i64, t, &k1) { return false; }
        }
    }
    true
}

pub fn x_entry_kinds(p: &ExecProgram, c: &XCert, m: usize) -> (r: Vec<XKind>)
    requires m < p.methods.len(),
    ensures kv(r) == entry_kinds(pview2(p), c@, m as int),
{
    let a = p.methods[m].arity as usize;
    let mut r = Vec::with_capacity(a);
    let mut i = 0;
    while i < a {
        if p.methods[m].kind == 3 {
            if i == 0 {
                match x_ctx_of(c, m) {
                    Some(ctx) => r.push(XKind::Block(1, ctx.slot)),
                    None => r.push(XKind::Param),
                }
            } else {
                r.push(XKind::Val);
            }
        } else if x_is_block_param(c, m, i) {
            r.push(XKind::Param);
        } else {
            r.push(XKind::Val);
        }
        i += 1;
    }
    r
}

pub fn x_method_ok(p: &ExecProgram, c: &XCert, m: usize, trusted: bool) -> (r: bool)
    requires wf_program2(pview2(p)), m < p.methods.len(), tables_ok(pview2(p), c@),
    ensures r == method_ok(pview2(p), c@, m as int, trusted),
{
    let i = p.methods[m];
    if !(i.entry < i.end && i.end <= p.bytecodes.len()) { return false; }
    if c.maps[m].len() != i.end - i.entry { return false; }
    if c.block_params[m].len() != i.arity as usize { return false; }
    if c.contexts[m].is_some() && i.kind != 3 { return false; }
    if i.kind == 3 && c.contexts[m].is_none() { return true; }
    let e = x_entry_kinds(p, c, m);
    if !x_map_is(c, m as i64, 0, &e) { return false; }
    let mut off = 0;
    while off < c.maps[m].len() {
        match &c.maps[m][off] {
            Some(k) => if !x_instr_ok(p, c, m, off, k, trusted) { return false; },
            None => {},
        }
        off += 1;
    }
    true
}

// ---------------------------------------------------------------------------
// Tables.

pub fn x_no_block_params(c: &XCert, m: usize) -> (r: bool)
    requires m < c.block_params.len(),
    ensures r == no_block_params(c@, m as int),
{
    let mut i = 0;
    while i < c.block_params[m].len() {
        if c.block_params[m][i] { return false; }
        i += 1;
    }
    true
}

pub fn x_machine_class_ok(p: &ExecProgram, k: usize) -> (r: bool)
    requires k < p.builtin.len(),
    ensures r == machine_class_ok(pview2(p), k as int),
{
    let cl = p.builtin[k] as i64;
    0 <= cl && (cl as usize) < p.class_bits.len() && !(x_is_field_class(p, cl) && x_ifc(p, cl as usize) >= 1)
}

pub fn x_entry_method(p: &ExecProgram, k: usize) -> (r: i64)
    requires k < p.entry_points.len(),
    ensures r as int == entry_method(pview2(p), k as int),
{
    let d = p.entry_points[k] as i64;
    if 0 <= d && (d as usize) < p.dispatch.len() { p.dispatch[d as usize] as i64 } else { -1 }
}

pub fn x_entry_ok(p: &ExecProgram, c: &XCert, k: usize, a: u8) -> (r: bool)
    requires k < p.entry_points.len(), c.block_params.len() == p.methods.len(),
    ensures r == entry_ok(pview2(p), c@, k as int, a as int),
{
    let e = x_entry_method(p, k);
    x_valid(p, e) && p.methods[e as usize].kind == 0 && p.methods[e as usize].arity == a
        && x_no_block_params(c, e as usize)
}

pub fn x_dispatch_entry_ok(p: &ExecProgram, d: usize) -> (r: bool)
    requires d < p.dispatch.len(),
    ensures r == dispatch_entry_ok(pview2(p), d as int),
{
    let t = p.dispatch[d] as i64;
    if t == -1 { return true; }
    if !x_valid(p, t) { return false; }
    let i = p.methods[t as usize];
    if !(i.kind == 0 || i.kind == 1) { return false; }
    let cl = d as i64 - i.selector as i64;
    if i.selector != 0xffff && 0 <= cl && cl < p.class_bits.len() as i64 && i.recv_start != 0xffff {
        i.recv_start as i64 <= cl && cl < i.recv_end as i64
    } else {
        true
    }
}

pub fn x_bools_eq(a: &Vec<bool>, b: &Vec<bool>) -> (r: bool)
    ensures r == (a@ == b@),
{
    if a.len() != b.len() { return false; }
    let mut i = 0;
    while i < a.len() {
        if a[i] != b[i] { return false; }
        i += 1;
    }
    true
}

pub fn x_method_table_ok(p: &ExecProgram, c: &XCert, m: usize) -> (r: bool)
    requires
        m < p.methods.len(),
        c.block_params.len() == p.methods.len(),
        c.contexts.len() == p.methods.len(),
    ensures r == method_table_ok(pview2(p), c@, m as int),
{
    let i = p.methods[m];
    let s = i.selector as usize;
    if c.block_params[m].len() != i.arity as usize { return false; }
    if i.selector != 0xffff {
        if s >= c.sel_rep.len() { return false; }
        let r = c.sel_rep[s];
        if !(x_valid(p, r) && p.methods[r as usize].arity == i.arity
            && x_bools_eq(&c.block_params[r as usize], &c.block_params[m])
            && (p.class_bits.len() as u64) + (s as u64) <= p.dispatch.len() as u64) {
            return false;
        }
    }
    if i.recv_start != 0xffff && !(i.arity >= 1 && !c.block_params[m][0]) { return false; }
    if i.kind == 3 && !(i.arity >= 1 && x_no_block_params(c, m)) { return false; }
    if i.kind == 2 && !x_no_block_params(c, m) { return false; }
    match &c.contexts[m] {
        Some(ctx) => x_valid(p, ctx.outer as i64),
        None => true,
    }
}

pub fn x_tables_ok(p: &ExecProgram, c: &XCert) -> (r: bool)
    requires wf_program2(pview2(p)),
    ensures r == tables_ok(pview2(p), c@),
{
    let n = p.methods.len();
    if !(c.maps.len() == n && c.block_params.len() == n && c.contexts.len() == n) { return false; }
    if c.sel_rep.len() > 0xffff { return false; }
    let mut s = 0;
    while s < c.sel_rep.len() {
        let r = c.sel_rep[s];
        if !(r == -1 || (x_valid(p, r) && p.methods[r as usize].selector as usize == s)) { return false; }
        s += 1;
    }
    let mut d = 0;
    while d < p.dispatch.len() {
        if !x_dispatch_entry_ok(p, d) { return false; }
        d += 1;
    }
    let mut m = 0;
    while m < n {
        if !x_method_table_ok(p, c, m) { return false; }
        m += 1;
    }
    let mut k = 0;
    while k < p.interface_check_offsets.len() {
        if (p.class_bits.len() as u64) + (p.interface_check_offsets[k] as u64) > p.dispatch.len() as u64 { return false; }
        k += 1;
    }
    if !(x_machine_class_ok(p, 15) && x_machine_class_ok(p, 11) && x_machine_class_ok(p, 16) && x_machine_class_ok(p, 18)) {
        return false;
    }
    let ex = p.builtin[22] as i64;
    if !(x_is_field_class(p, ex) && x_ifc(p, ex as usize) >= 2) { return false; }
    let tc = p.builtin[19] as i64;
    if !(x_is_field_class(p, tc) && x_ifc(p, tc as usize) >= 2) { return false; }
    if !(x_entry_ok(p, c, 0, 1) && p.methods[x_entry_method(p, 0) as usize].recv_start == 0xffff) { return false; }
    if !(x_entry_ok(p, c, 2, 1) && p.methods[x_entry_method(p, 2) as usize].recv_start == 0xffff) { return false; }
    let mut two = Vec::new();
    two.push(XKind::Val);
    two.push(XKind::Val);
    if !x_map_is(c, x_entry_method(p, 2), 1, &two) { return false; }
    x_entry_ok(p, c, 8, 2)
}

pub fn x_wf_program2(p: &ExecProgram) -> (r: bool)
    ensures r == wf_program2(pview2(p)),
{
    if !(p.word_bits == 32 || p.word_bits == 64) { return false; }
    if !(p.bytecodes.len() < 0x1000_0000 && p.methods.len() < 0x1000_0000 && p.dispatch.len() < 0x1000_0000) {
        return false;
    }
    let mut m = 0;
    while m < p.methods.len() {
        if !(p.methods[m].entry <= p.methods[m].end && p.methods[m].end <= p.bytecodes.len()) { return false; }
        m += 1;
    }
    p.roots.len() == 35 && p.invoke_offsets.len() == 19 && p.builtin.len() == 23 && p.entry_points.len() == 9
        && p.literals.len() >= 7
}

/// The structural verifier.
pub fn verify(p: &ExecProgram, c: &XCert, trusted: bool) -> (r: bool)
    ensures r == accepts(pview2(p), c@, trusted),
{
    if !x_wf_program2(p) { return false; }
    if !x_tables_ok(p, c) { return false; }
    let mut m = 0;
    while m < p.methods.len() {
        if !x_method_ok(p, c, m, trusted) { return false; }
        m += 1;
    }
    true
}

} // verus!
