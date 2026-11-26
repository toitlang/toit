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

//! The shipped certificate (format/18-shipped-certificate.md): the
//! compiler's toolchain ships the certificate with the program and the
//! device only checks it.
//!
//! `verify_shipped(p, cert, global_count, prim_arity, trusted)` reads the
//! global part of the certificate in place (`XGlobal` borrows the byte
//! tables of `cert`, which may be memory-mapped flash) and decodes the maps
//! of one method at a time from the certificate's stream
//! (`ShippedOracle`), and hands both to the proven checker
//! `check::verify`. It is proven to return true only if some certificate
//! `c` with the given trusted fields is accepted (`accepts`), so
//! `theorem_soundness` applies. Nothing about the decoder needs to be
//! correct for that: the checker decides whatever it decodes; Verus proves
//! that the decoding is total (no out-of-bounds access, no overflow, it
//! terminates). A wrong or malicious certificate can only be rejected.
//!
//! The stream holds, per method, only the maps the checker cannot
//! recompute by falling through: the decoder walks the method from its
//! entry, places the successor kinds of each instruction (`x_post`) at the
//! next instruction, and takes a shipped map wherever one is given (branch
//! targets, code after a terminator, non-local branch targets).
//!
//! The decoder fails with `Dec::Bad` (a malformed certificate: rejected)
//! or `Dec::Oom` (an allocation failed: the checker returns `Err(Oom)`, the
//! verdict rejects); it has no panic paths (`crate::xvec`).

use vstd::prelude::*;
use alloc::vec::Vec;
use crate::xvec::*;
use crate::cvec::{CBuild, CHUNK};
use crate::types::*;
use crate::v2::check::*;
use crate::v2::verifier::*;
use crate::v2::split::*;
use crate::v2::vprog::*;
use crate::v2::bytecodes::*;
#[cfg(verus_only)]
use crate::v2::exec::wf_program2;

verus! {

/// "TCRT", little endian.
pub const CERT_MAGIC: u32 = 0x5452_4354;
pub const CERT_VERSION: u32 = 1;
/// Magic, version, method count, and six sections (offset, length).
pub const CERT_HEADER_SIZE: usize = 60;
/// The sections, in header order.
pub const SEC_MW: usize = 0;
pub const SEC_CREC: usize = 1;
pub const SEC_SEL: usize = 2;
pub const SEC_PINS: usize = 3;
pub const SEC_NODES: usize = 4;
pub const SEC_MAPS: usize = 5;
/// At most this many kinds in a shipped list (the checker's frames are
/// far lower; `x_post` takes frames up to 2^20).
pub const MAX_KINDS: usize = 0x1_0000;

/// Section `i` of the certificate, if it lies inside it.
pub fn x_section<'a>(s: &'a [u8], i: usize) -> (r: Option<&'a [u8]>)
    requires i < 6,
{
    let off = x_rd(s, 12 + 8 * i) as usize;
    let len = x_rd(s, 16 + 8 * i) as usize;
    if off <= s.len() && len <= s.len() - off {
        Some(subslice(s, off, off + len))
    } else {
        None
    }
}

/// The global part of a shipped certificate and its maps stream; the
/// trusted fields are the caller's.
pub fn parse_cert<'a>(p: &VProgram<'a>, cert: &'a [u8], global_count: u64, prim_arity: &'a [Vec<u8>])
    -> (r: Option<(XGlobal<'a>, &'a [u8])>)
    ensures
        match r {
            Some((g, _)) => g.global_count == global_count && g.prim_arity@ == prim_arity@,
            None => true,
        },
{
    if cert.len() < CERT_HEADER_SIZE { return None; }
    if x_rd(cert, 0) != CERT_MAGIC || x_rd(cert, 4) != CERT_VERSION { return None; }
    if x_rd(cert, 8) as usize != p.methods.len() { return None; }
    let mw = x_section(cert, SEC_MW)?;
    let crec = x_section(cert, SEC_CREC)?;
    let sel = x_section(cert, SEC_SEL)?;
    let pins = x_section(cert, SEC_PINS)?;
    let nodes = x_section(cert, SEC_NODES)?;
    let maps = x_section(cert, SEC_MAPS)?;
    let g = XGlobal {
        n: p.methods.len(),
        methods: p.methods,
        mw,
        crec,
        sel,
        pins,
        nodes,
        global_count,
        prim_arity,
    };
    Some((g, maps))
}

/// An unsigned LEB128 number below 2^32 at `pos` (at most 5 bytes): the
/// number and the position after it.
pub fn x_varint(s: &[u8], pos: usize) -> (r: Option<(u32, usize)>)
    ensures
        match r {
            Some((_, q)) => pos < q <= s@.len(),
            None => true,
        },
{
    let mut v: u64 = 0;
    let mut mult: u64 = 1;
    let mut q = pos;
    let mut i: usize = 0;
    while i < 5
        invariant
            0 <= i <= 5, q == pos + i, q <= s@.len() || i == 0,
            1 <= mult <= 0x8_0000_0000, v < mult,
            i == 0 ==> mult == 1,
            i == 1 ==> mult == 0x80,
            i == 2 ==> mult == 0x4000,
            i == 3 ==> mult == 0x20_0000,
            i == 4 ==> mult == 0x1000_0000,
            i == 5 ==> mult == 0x8_0000_0000,
        decreases 5 - i,
    {
        if q >= s.len() { return None; }
        let b = ix(s, q);
        let d = (b % 128) as u64;
        assert(d * mult <= 127 * mult) by (nonlinear_arith) requires d <= 127, mult >= 1;
        v = v + d * mult;
        q = q + 1;
        if b < 128 {
            if v > 0xffff_ffff { return None; }
            return Some((v as u32, q));
        }
        mult = mult * 128;
        i = i + 1;
    }
    None
}

/// A kind of the stream: a number whose low 2 bits are the tag (0: value,
/// block parameter or token by the rest 0, 1, 2; 1: method; 2: block of
/// depth 0; 3: block of the depth that follows), the rest the operand.
pub fn x_read_kind(s: &[u8], pos: usize) -> (r: Option<(XKind, usize)>)
    ensures
        match r {
            Some((_, q)) => pos < q <= s@.len(),
            None => true,
        },
{
    let (v, q) = x_varint(s, pos)?;
    let tag = v % 4;
    let x = v / 4;
    if tag == 0 {
        if x == 0 { Some((XKind::Val, q)) }
        else if x == 1 { Some((XKind::Param, q)) }
        else if x == 2 { Some((XKind::Token, q)) }
        else { None }
    } else if tag == 1 {
        Some((XKind::Method(x), q))
    } else if tag == 2 {
        Some((XKind::Block(0, x), q))
    } else {
        let (d, q2) = x_varint(s, q)?;
        Some((XKind::Block(d, x), q2))
    }
}

/// Why decoding stopped: a malformed certificate (rejected) or a failed
/// allocation.
#[derive(Clone, Copy)]
pub enum Dec {
    Bad,
    Oom,
}

/// `o`'s value, or `Dec::Bad`.
pub fn dec_some<T>(o: Option<T>) -> (r: Result<T, Dec>)
    ensures r matches Ok(x) ==> o == Some(x),
{
    match o { Some(x) => Ok(x), None => Err(Dec::Bad) }
}

/// `try_push` for the decoder.
pub fn dec_push<T>(v: &mut Vec<T>, x: T) -> (r: Result<(), Dec>)
    ensures r is Ok ==> final(v)@ == old(v)@.push(x),
{
    match try_push(v, x) { Ok(()) => Ok(()), Err(_) => Err(Dec::Oom) }
}

/// A list of kinds being decoded, with the node of each slot.
pub struct XList {
    pub kinds: Vec<XKind>,
    pub ids: Vec<u32>,
}

pub open spec fn list_ok(l: &XList) -> bool {
    l.kinds@.len() == l.ids@.len() && l.kinds@.len() <= MAX_KINDS
}

/// The top node of a list (`EMPTY_MAP` for the empty list).
pub fn x_top(l: &XList) -> (r: u32)
    requires list_ok(l),
{
    if l.ids.len() == 0 { EMPTY_MAP } else { vix(&l.ids, l.ids.len() - 1) }
}

/// The first `n` slots of `l` (sharing its nodes).
pub fn x_list_prefix(l: &XList, n: usize) -> (res: Result<XList, Dec>)
    requires list_ok(l), n <= l.kinds@.len(),
    ensures res matches Ok(r) ==> list_ok(&r) && r.kinds@.len() == n,
{
    let mut kinds: Vec<XKind> = Vec::new();
    let mut ids: Vec<u32> = Vec::new();
    let mut i = 0;
    while i < n
        invariant list_ok(l), n <= l.kinds@.len(), 0 <= i <= n, kinds@.len() == i, ids@.len() == i,
        decreases n - i,
    {
        dec_push(&mut kinds, vix(&l.kinds, i))?;
        dec_push(&mut ids, vix(&l.ids, i))?;
        i += 1;
    }
    Ok(XList { kinds, ids })
}

/// Pushes kind `k` on `l` as a new node of `nodes`; `Dec::Bad` if `nodes`
/// is full (`limit`).
pub fn x_list_push(l: &mut XList, nodes: &mut CBuild<XNode>, k: XKind, limit: usize) -> (r: Result<(), Dec>)
    requires list_ok(&*old(l)), old(l).kinds@.len() < MAX_KINDS, limit < EMPTY_MAP as usize, old(nodes).ok(),
    ensures final(nodes).ok(), r is Ok ==> list_ok(&*final(l)) && final(l).kinds@.len() == old(l).kinds@.len() + 1,
{
    let id = nodes.len();
    if id >= limit { return Err(Dec::Bad); }
    let parent = if l.ids.len() == 0 { id as u32 } else { vix(&l.ids, l.ids.len() - 1) };
    match nodes.try_push(XNode { parent, kind: k }) { Ok(()) => {}, Err(_) => return Err(Dec::Oom) }
    dec_push(&mut l.kinds, k)?;
    dec_push(&mut l.ids, id as u32)?;
    Ok(())
}

/// The list of kinds `k2`, sharing the longest common prefix with `l`.
pub fn x_intern(l: &XList, k2: &Vec<XKind>, nodes: &mut CBuild<XNode>, limit: usize) -> (res: Result<XList, Dec>)
    requires list_ok(l), limit < EMPTY_MAP as usize, old(nodes).ok(),
    ensures final(nodes).ok(), res matches Ok(r) ==> list_ok(&r),
{
    if k2.len() > MAX_KINDS { return Err(Dec::Bad); }
    let mut c = 0;
    while c < l.kinds.len() && c < k2.len() && x_kind_eq(vix(&l.kinds, c), vix(k2, c))
        invariant list_ok(l), 0 <= c <= l.kinds@.len(), c <= k2@.len(),
        decreases k2@.len() - c,
    {
        c += 1;
    }
    let mut r = x_list_prefix(l, c)?;
    let mut i = c;
    while i < k2.len()
        invariant list_ok(&r), c <= i <= k2@.len(), k2@.len() <= MAX_KINDS, r.kinds@.len() == i, limit < EMPTY_MAP as usize, nodes.ok(),
        decreases k2@.len() - i,
    {
        x_list_push(&mut r, nodes, vix(k2, i), limit)?;
        i += 1;
    }
    Ok(r)
}

/// `out` becomes the first `n` slots of `l` (sharing its nodes); `out`'s
/// buffers are reused, so that the walk allocates only while they grow.
pub fn x_list_prefix_into(l: &XList, n: usize, out: &mut XList) -> (res: Result<(), Dec>)
    requires list_ok(l), n <= l.kinds@.len(),
    ensures res is Ok ==> list_ok(&*final(out)) && final(out).kinds@.len() == n,
{
    out.kinds.clear();
    out.ids.clear();
    let mut i = 0;
    while i < n
        invariant list_ok(l), n <= l.kinds@.len(), 0 <= i <= n, out.kinds@.len() == i, out.ids@.len() == i,
        decreases n - i,
    {
        dec_push(&mut out.kinds, vix(&l.kinds, i))?;
        dec_push(&mut out.ids, vix(&l.ids, i))?;
        i += 1;
    }
    Ok(())
}

/// `x_intern` into `out` (its buffers reused).
pub fn x_intern_into(l: &XList, k2: &Vec<XKind>, nodes: &mut CBuild<XNode>, limit: usize, out: &mut XList) -> (res: Result<(), Dec>)
    requires list_ok(l), limit < EMPTY_MAP as usize, old(nodes).ok(),
    ensures final(nodes).ok(), res is Ok ==> list_ok(&*final(out)),
{
    if k2.len() > MAX_KINDS { return Err(Dec::Bad); }
    let mut c = 0;
    while c < l.kinds.len() && c < k2.len() && x_kind_eq(vix(&l.kinds, c), vix(k2, c))
        invariant list_ok(l), 0 <= c <= l.kinds@.len(), c <= k2@.len(),
        decreases k2@.len() - c,
    {
        c += 1;
    }
    x_list_prefix_into(l, c, out)?;
    let mut i = c;
    while i < k2.len()
        invariant list_ok(&*out), c <= i <= k2@.len(), k2@.len() <= MAX_KINDS, out.kinds@.len() == i, limit < EMPTY_MAP as usize, nodes.ok(),
        decreases k2@.len() - i,
    {
        x_list_push(out, nodes, vix(k2, i), limit)?;
        i += 1;
    }
    Ok(())
}

/// The maps of the methods, decoded from the stream one method at a time
/// in method order.
pub struct ShippedOracle<'a> {
    pub s: &'a [u8],
    pub pos: usize,
    /// The method whose maps come next in the stream.
    pub next: usize,
    pub trusted: bool,
    pub failed: bool,
    /// The last method whose maps were asked for (diagnostics).
    pub last: usize,
    /// The decoder's buffers, kept from one method to the next: the
    /// previous map, the successor map and the successor kinds.
    pub b_prev: XList,
    pub b_next: XList,
    pub b_post: Vec<XKind>,
}

/// A map nobody can accept for a method with a non-empty body.
pub fn x_bad_maps() -> (r: XMaps) {
    XMaps { idx: CVec::new(), nodes: CVec::new() }
}

/// The maps the decoder built.
fn x_built(idx: CBuild<u32>, nodes: CBuild<XNode>) -> (r: Result<XMaps, Dec>)
    requires idx.ok(), nodes.ok(),
{
    let idx = match idx.try_finish() { Ok(v) => v, Err(_) => return Err(Dec::Oom) };
    let nodes = match nodes.try_finish() { Ok(v) => v, Err(_) => return Err(Dec::Oom) };
    Ok(XMaps { idx, nodes })
}

/// Reads the next shipped map: drop `d` slots of `prev`, push the kinds
/// that follow. Returns the list and the position after it.
pub fn x_read_map(s: &[u8], pos: usize, prev: &XList, nodes: &mut CBuild<XNode>, limit: usize) -> (r: Result<(XList, usize), Dec>)
    requires list_ok(prev), limit < EMPTY_MAP as usize, old(nodes).ok(),
    ensures final(nodes).ok(), r matches Ok((l, q)) ==> list_ok(&l) && pos < q <= s@.len(),
{
    let (d, q) = dec_some(x_varint(s, pos))?;
    let (n, q) = dec_some(x_varint(s, q))?;
    if d as usize > prev.kinds.len() { return Err(Dec::Bad); }
    let keep = prev.kinds.len() - d as usize;
    if n as usize > MAX_KINDS - keep { return Err(Dec::Bad); }
    let mut l = x_list_prefix(prev, keep)?;
    let mut q = q;
    let mut i: usize = 0;
    while i < n as usize
        invariant
            list_ok(&l), l.kinds@.len() == keep + i, keep + n as usize <= MAX_KINDS, 0 <= i <= n as usize,
            pos < q <= s@.len(), limit < EMPTY_MAP as usize, nodes.ok(),
        decreases n as usize - i,
    {
        let (k, q2) = dec_some(x_read_kind(s, q))?;
        x_list_push(&mut l, nodes, k, limit)?;
        q = q2;
        i += 1;
    }
    Ok((l, q))
}

/// The kinds at the entry of method `m` as a list.
pub fn x_entry_list(p: &VProgram, g: &XGlobal, m: usize, nodes: &mut CBuild<XNode>, limit: usize) -> (r: Result<XList, Dec>)
    requires m < p.methods@.len(), limit < EMPTY_MAP as usize, old(nodes).ok(),
    ensures final(nodes).ok(), r matches Ok(r) ==> list_ok(&r),
{
    let empty = XMaps { idx: CVec::new(), nodes: CVec::new() };
    let c = XCert { g, cur: m, maps: &empty };
    let e = match x_entry_kinds(p, &c, m) { Ok(e) => e, Err(_) => return Err(Dec::Oom) };
    let l = XList { kinds: Vec::new(), ids: Vec::new() };
    x_intern(&l, &e, nodes, limit)
}

impl<'a> ShippedOracle<'a> {
    pub fn new(s: &'a [u8], trusted: bool) -> ShippedOracle<'a> {
        ShippedOracle {
            s, pos: 0, next: 0, trusted, failed: false, last: 0,
            b_prev: XList { kinds: Vec::new(), ids: Vec::new() },
            b_next: XList { kinds: Vec::new(), ids: Vec::new() },
            b_post: Vec::new(),
        }
    }

    /// Decodes method `m`'s maps.
    fn decode(&mut self, p: &VProgram, g: &XGlobal, m: usize) -> (r: Result<XMaps, Dec>)
        requires wf_program2(vview(p)), g_ok(g), m < p.methods@.len(), g.n == p.methods@.len(),
    {
        let info = x_info(p, m);
        if !(info.entry < info.end && info.end <= p.bytecodes.len()) { return Err(Dec::Bad); }
        let entry = info.entry;
        let end = info.end;
        let size = end - entry;
        let s = self.s;
        let (count, q) = dec_some(x_varint(s, self.pos))?;
        let mut pos = q;
        // The map index grows with the walk (the offsets it places maps at
        // increase): `NO_MAP` up to an offset, then its map.
        let mut idx: CBuild<u32> = match CBuild::try_new(size) { Ok(v) => v, Err(_) => return Err(Dec::Oom) };
        // A whole chunk for the nodes (a smaller first block would grow past
        // a chunk when it fills).
        let mut nodes: CBuild<XNode> = match CBuild::try_new(CHUNK) { Ok(v) => v, Err(_) => return Err(Dec::Oom) };
        // A block that is never created is not checked: no maps.
        let empty = XMaps { idx: CVec::new(), nodes: CVec::new() };
        let c = XCert { g, cur: m, maps: &empty };
        if info.kind == 3 && x_ctx_of(&c, m).is_none() {
            if count != 0 { return Err(Dec::Bad); }
            if idx.try_fill_to(NO_MAP, size).is_err() { return Err(Dec::Oom); }
            self.pos = pos;
            return x_built(idx, nodes);
        }
        // The node budget: well above what compiled code needs (infer.rs).
        let limit: usize = if size < 0x0100_0000 { size * 16 + 4096 } else { 0x1000_0000 };
        let mut left = count;
        // The next shipped map's offset (`have`), read ahead of its kinds.
        let mut have = false;
        let mut e: usize = 0;
        if left > 0 {
            let (d, q) = dec_some(x_varint(s, pos))?;
            pos = q;
            e = d as usize;
            have = true;
            left = left - 1;
        }
        // The map placed at the previous instruction, the map placed at
        // this one (`cur`, if `have_cur`) and the buffers of the successor
        // map (`next`): swapped, not reallocated, from one instruction to
        // the next.
        // (The buffers are the oracle's, put back after the method.)
        let mut prev = XList { kinds: Vec::new(), ids: Vec::new() };
        core::mem::swap(&mut prev, &mut self.b_prev);
        prev.kinds.clear();
        prev.ids.clear();
        let mut cur: XList = x_entry_list(p, g, m, &mut nodes, limit)?;
        let mut have_cur = true;
        let mut next = XList { kinds: Vec::new(), ids: Vec::new() };
        core::mem::swap(&mut next, &mut self.b_next);
        next.kinds.clear();
        next.ids.clear();
        // The successor kinds (`x_post_into`), reused too.
        let mut k2: Vec<XKind> = Vec::new();
        core::mem::swap(&mut k2, &mut self.b_post);
        let mut off: usize = 0;
        while off < size
            invariant
                wf_program2(vview(p)), g_ok(g), m < p.methods@.len(), g.n == p.methods@.len(),
                entry == vinfo(p, m as int).entry, end == vinfo(p, m as int).end, entry < end <= p.bytecodes@.len(),
                size == end - entry, idx.ok(), nodes.ok(), idx.items().len() <= size, idx.items().len() <= off, pos <= s@.len(),
                list_ok(&prev), list_ok(&cur), list_ok(&next),
                limit < EMPTY_MAP as usize, have ==> e <= u32::MAX as usize,
            decreases (if off <= size { size - off } else { 0 }), (if have { 1int } else { 0int }) + left as int,
        {
            // Shipped maps behind the walk are skipped.
            if have && e < off {
                let (_, q) = x_read_map(s, pos, &prev, &mut nodes, limit)?;
                pos = q;
                if left > 0 {
                    let (d, q) = dec_some(x_varint(s, pos))?;
                    pos = q;
                    if d as usize >= u32::MAX as usize - e { return Err(Dec::Bad); }
                    e = e + 1 + d as usize;
                    if e > u32::MAX as usize { return Err(Dec::Bad); }
                    left = left - 1;
                } else {
                    have = false;
                }
                continue;
            }
            if have && e == off {
                let (l, q) = x_read_map(s, pos, &prev, &mut nodes, limit)?;
                pos = q;
                cur = l;
                if left > 0 {
                    let (d, q) = dec_some(x_varint(s, pos))?;
                    pos = q;
                    if d as usize >= u32::MAX as usize - e { return Err(Dec::Bad); }
                    e = e + 1 + d as usize;
                    left = left - 1;
                } else {
                    have = false;
                }
            } else if !have_cur {
                if !have { break; }
                // Jump to the next shipped map.
                off = e;
                continue;
            }
            // `cur` is the map placed at `off`.
            have_cur = false;
            if idx.try_fill_to(NO_MAP, off).is_err() { return Err(Dec::Oom); }
            if idx.try_push(x_top(&cur)).is_err() { return Err(Dec::Oom); }
            let bci = entry + off;
            let op = ix(p.bytecodes, bci);
            if op >= OPCODE_COUNT2 {
                core::mem::swap(&mut prev, &mut cur);
                off = off + 1;
                continue;
            }
            let len = exec_opcode_length2(op);
            if len > end - bci {
                core::mem::swap(&mut prev, &mut cur);
                off = off + 1;
                continue;
            }
            let mut found = false;
            if !x_is_terminator(op) && cur.kinds.len() <= 0x10_0000 {
                let c = XCert { g, cur: m, maps: &empty };
                match x_post_into(p, &c, m, off, &cur.kinds, self.trusted, &mut k2) {
                    Ok(true) => {
                        x_intern_into(&cur, &k2, &mut nodes, limit, &mut next)?;
                        found = true;
                    },
                    Ok(false) => {},
                    Err(_) => return Err(Dec::Oom),
                }
            }
            // The placed map becomes `prev`, the successor (if any) `cur`.
            core::mem::swap(&mut prev, &mut cur);
            if found {
                core::mem::swap(&mut cur, &mut next);
                have_cur = true;
            }
            off = off + len;
        }
        // The shipped maps past the end are read (and ignored).
        while have || left > 0
            invariant pos <= s@.len(), list_ok(&prev), limit < EMPTY_MAP as usize, idx.ok(), nodes.ok(), idx.items().len() <= size,
            decreases (if have { 1int } else { 0int }) + left as int,
        {
            let (_, q) = x_read_map(s, pos, &prev, &mut nodes, limit)?;
            pos = q;
            if left > 0 {
                let (_, q) = dec_some(x_varint(s, pos))?;
                pos = q;
                left = left - 1;
            } else {
                have = false;
            }
        }
        if idx.try_fill_to(NO_MAP, size).is_err() { return Err(Dec::Oom); }
        self.pos = pos;
        self.b_prev = prev;
        self.b_next = next;
        self.b_post = k2;
        x_built(idx, nodes)
    }
}

impl<'a> MapOracle for ShippedOracle<'a> {
    fn method_maps(&mut self, p: &VProgram, g: &XGlobal, m: usize) -> Result<XMaps, Oom> {
        self.last = m;
        if self.failed || m != self.next {
            self.failed = true;
            return Ok(x_bad_maps());
        }
        self.next = m + 1;
        match self.decode(p, g, m) {
            Ok(maps) => Ok(maps),
            Err(Dec::Bad) => {
                self.failed = true;
                Ok(x_bad_maps())
            },
            Err(Dec::Oom) => Err(Oom),
        }
    }
}

pub open spec fn prim_view(prim_arity: Seq<Vec<u8>>) -> Seq<Seq<int>> {
    prim_arity.map_values(|v: Vec<u8>| v@.map_values(|a: u8| a as int))
}

/// The verdict on program `p` with the shipped certificate `cert`: true
/// only if some certificate with the trusted fields `global_count` and
/// `prim_arity` is accepted. Also returns the method the checker stopped
/// at (diagnostics). `Err(Oom)`: an allocation failed (rejected).
pub fn verify_shipped(p: &VProgram, cert: &[u8], global_count: u64, prim_arity: &[Vec<u8>], trusted: bool)
    -> (res: Result<(bool, usize), Oom>)
    ensures
        res matches Ok(r) ==> (r.0 ==> exists|c: Cert| accepts(vview(p), c, trusted) && #[trigger] c.global_count == global_count as int
            && c.prim_arity == prim_view(prim_arity@)),
{
    let (g, maps) = match parse_cert(p, cert, global_count, prim_arity) {
        Some(x) => x,
        None => return Ok((false, 0)),
    };
    let (ok, at, Ghost(ms)) = crate::v2::walk::walk(p, &g, maps, trusted, &mut crate::v2::walk::NoProgress)?;
    if ok {
        proof {
            lemma_split_sound(vview(p), g@, ms, trusted);
            let c = with_maps(g@, ms);
            assert(c.global_count == global_count as int);
            assert(c.prim_arity == prim_view(prim_arity@));
        }
    }
    Ok((ok, at))
}

/// The two-pass checker (decode the maps, then `check::verify`): the
/// differential test's reference until the old path is removed.
pub fn verify_shipped_two_pass(p: &VProgram, cert: &[u8], global_count: u64, prim_arity: &[Vec<u8>], trusted: bool)
    -> (res: Result<(bool, usize), Oom>)
    ensures
        res matches Ok(r) ==> (r.0 ==> exists|c: Cert| accepts(vview(p), c, trusted) && #[trigger] c.global_count == global_count as int
            && c.prim_arity == prim_view(prim_arity@)),
{
    let (g, maps) = match parse_cert(p, cert, global_count, prim_arity) {
        Some(x) => x,
        None => return Ok((false, 0)),
    };
    let mut o = ShippedOracle::new(maps, trusted);
    let (ok, Ghost(ms)) = verify(p, &g, &mut o, trusted)?;
    if ok {
        proof {
            lemma_split_sound(vview(p), g@, ms, trusted);
            let c = with_maps(g@, ms);
            assert(c.global_count == global_count as int);
            assert(c.prim_arity == prim_view(prim_arity@));
        }
    }
    Ok((ok, o.last))
}

} // verus!
