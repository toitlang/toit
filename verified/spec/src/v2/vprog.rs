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

//! The program as the verifier reads it: borrowed tables.
//!
//! `VProgram` holds slices of the tables instead of owned vectors, so the
//! VM can hand the verifier its own memory (the bytecodes in flash, the
//! decoded method table, the dispatch table, ...) without copying it.
//! `vview(p)` is the same `Program2` that `pview2` gives for an
//! `ExecProgram` with the same contents (`vprogram_of` builds one from an
//! `ExecProgram` and proves it).
//!
//! The method table is the VM's own layout (`VMethod`, identical to
//! `toit::V2Method` and the core's `ffi::V2Method`, `#[repr(C)]`); every
//! method has the program's global max height, as in the loader and in
//! the VM.

use vstd::prelude::*;
use alloc::vec::Vec;
use crate::types::*;
use crate::v2::types::*;

verus! {

/// An entry of the method table in the VM's layout (`toit::V2Method`).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct VMethod {
    pub entry: u32,
    pub end: u32,
    pub selector: u16,
    pub aux: u16,
    pub recv_start: u16,
    pub recv_end: u16,
    pub arity: u8,
    pub kind: u8,
    pub unused: u16,
}

pub open spec fn minfo(m: VMethod, max_height: u16) -> MethodInfo {
    MethodInfo {
        arity: m.arity,
        kind: m.kind,
        max_height,
        selector: m.selector,
        aux: m.aux,
        recv_start: m.recv_start,
        recv_end: m.recv_end,
        entry: m.entry as usize,
        end: m.end as usize,
    }
}

pub struct VProgram<'a> {
    pub word_bits: u8,
    /// The program's global max height (every method's `max_height`).
    pub max_height: u16,
    pub bytecodes: &'a [u8],
    pub methods: &'a [VMethod],
    pub dispatch: &'a [i32],
    pub class_bits: &'a [u16],
    pub class_check_ids: &'a [u16],
    pub interface_check_offsets: &'a [u16],
    pub invoke_offsets: &'a [i32],
    pub entry_points: &'a [i32],
    pub builtin: &'a [u16],
    pub roots: &'a [Value],
    pub literals: &'a [Value],
}

pub open spec fn vview(p: &VProgram) -> Program2 {
    Program2 {
        word_bits: p.word_bits,
        bytecodes: p.bytecodes@,
        methods: Seq::new(p.methods@.len(), |i: int| minfo(p.methods@[i], p.max_height)),
        dispatch: p.dispatch@,
        class_bits: p.class_bits@,
        class_check_ids: p.class_check_ids@,
        interface_check_offsets: p.interface_check_offsets@,
        invoke_offsets: p.invoke_offsets@,
        entry_points: p.entry_points@,
        builtin: p.builtin@,
        roots: p.roots@,
        literals: p.literals@,
    }
}

/// Method `m` of the abstract program.
pub open spec fn vinfo(p: &VProgram, m: int) -> MethodInfo {
    vview(p).methods[m]
}

/// `info(vview(p), m)`.
pub fn x_info(p: &VProgram, m: usize) -> (r: MethodInfo)
    requires m < p.methods@.len(),
    ensures r == vview(p).methods[m as int], r == vinfo(p, m as int),
{
    let v = crate::xvec::ix(p.methods, m);
    MethodInfo {
        arity: v.arity,
        kind: v.kind,
        max_height: p.max_height,
        selector: v.selector,
        aux: v.aux,
        recv_start: v.recv_start,
        recv_end: v.recv_end,
        entry: v.entry as usize,
        end: v.end as usize,
    }
}

/// The method table of an `ExecProgram` in the VM's layout, if every
/// method has the max height `h` and its bounds fit 32 bits.
pub fn vmethods_of(e: &ExecProgram, h: u16) -> (r: Option<Vec<VMethod>>)
    ensures
        r is Some ==> r->0@.len() == e.methods@.len()
            && forall|i: int| 0 <= i < e.methods@.len() ==> #[trigger] minfo(r->0@[i], h) == e.methods@[i],
{
    let mut r: Vec<VMethod> = Vec::new();
    let mut i = 0;
    while i < e.methods.len()
        invariant
            0 <= i <= e.methods@.len(), r@.len() == i,
            forall|j: int| 0 <= j < i ==> #[trigger] minfo(r@[j], h) == e.methods@[j],
        decreases e.methods@.len() - i,
    {
        let m = e.methods[i];
        if m.max_height != h || m.entry > 0xffff_ffff || m.end > 0xffff_ffff {
            return None;
        }
        r.push(VMethod {
            entry: m.entry as u32,
            end: m.end as u32,
            selector: m.selector,
            aux: m.aux,
            recv_start: m.recv_start,
            recv_end: m.recv_end,
            arity: m.arity,
            kind: m.kind,
            unused: 0,
        });
        proof { assert(minfo(r@[i as int], h) == e.methods@[i as int]); }
        i += 1;
    }
    Some(r)
}

/// The program view of an `ExecProgram` (the dump path), with its method
/// table in the VM's layout (from `vmethods_of`).
pub fn vprogram_of<'a>(e: &'a ExecProgram, methods: &'a Vec<VMethod>, h: u16) -> (r: VProgram<'a>)
    requires
        methods@.len() == e.methods@.len(),
        forall|i: int| 0 <= i < e.methods@.len() ==> #[trigger] minfo(methods@[i], h) == e.methods@[i],
    ensures vview(&r) == pview2(e),
{
    let r = VProgram {
        word_bits: e.word_bits,
        max_height: h,
        bytecodes: e.bytecodes.as_slice(),
        methods: methods.as_slice(),
        dispatch: e.dispatch.as_slice(),
        class_bits: e.class_bits.as_slice(),
        class_check_ids: e.class_check_ids.as_slice(),
        interface_check_offsets: e.interface_check_offsets.as_slice(),
        invoke_offsets: e.invoke_offsets.as_slice(),
        entry_points: e.entry_points.as_slice(),
        builtin: e.builtin.as_slice(),
        roots: e.roots.as_slice(),
        literals: e.literals.as_slice(),
    };
    proof { assert(vview(&r).methods =~= pview2(e).methods); }
    r
}

/// The max height of an `ExecProgram`'s methods (all equal in format 2).
pub fn max_height_of(e: &ExecProgram) -> u16 {
    if e.methods.len() > 0 { e.methods[0].max_height } else { 0 }
}

} // verus!
