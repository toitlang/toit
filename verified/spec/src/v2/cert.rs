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
//! tables of `cert`, which may be memory-mapped flash) and hands it with
//! the maps stream to the single-pass checker `v2::walk::walk`, which
//! checks each method in one walk. It is proven to return true only if
//! some certificate `c` with the given trusted fields is accepted
//! (`accepts`), so `theorem_soundness` applies. Nothing about the stream's
//! decoding needs to be correct for that; Verus proves that it is total (no
//! out-of-bounds access, no overflow, it terminates). A wrong or malicious
//! certificate can only be rejected.
//!
//! The stream holds, per method, only the maps the walk cannot compute by
//! falling through: the walk places the successor kinds of each
//! instruction (`x_post`) at the next instruction and takes a shipped map
//! wherever one is given (branch targets, code after a terminator,
//! non-local branch targets), which must agree with the successor where
//! one falls through.

use vstd::prelude::*;
use alloc::vec::Vec;
use crate::xvec::*;
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

pub open spec fn prim_view(prim_arity: Seq<Vec<u8>>) -> Seq<Seq<int>> {
    prim_arity.map_values(|v: Vec<u8>| v@.map_values(|a: u8| a as int))
}

/// The verdict on program `p` with the shipped certificate `cert`: true
/// only if some certificate with the trusted fields `global_count` and
/// `prim_arity` is accepted. Also returns the method and the offset the
/// checker stopped at (diagnostics). `Err(Oom)`: an allocation failed (rejected).
pub fn verify_shipped(p: &VProgram, cert: &[u8], global_count: u64, prim_arity: &[Vec<u8>], trusted: bool)
    -> (res: Result<(bool, usize, usize), Oom>)
    ensures
        res matches Ok(r) ==> (r.0 ==> exists|c: Cert| accepts(vview(p), c, trusted) && #[trigger] c.global_count == global_count as int
            && c.prim_arity == prim_view(prim_arity@)),
{
    let (g, maps) = match parse_cert(p, cert, global_count, prim_arity) {
        Some(x) => x,
        None => return Ok((false, 0, 0)),
    };
    let (ok, at, off, Ghost(ms)) = crate::v2::walk::walk(p, &g, maps, trusted, &mut crate::v2::walk::NoProgress)?;
    if ok {
        proof {
            lemma_split_sound(vview(p), g@, ms, trusted);
            let c = with_maps(g@, ms);
            assert(c.global_count == global_count as int);
            assert(c.prim_arity == prim_view(prim_arity@));
        }
    }
    Ok((ok, at, off))
}


} // verus!
