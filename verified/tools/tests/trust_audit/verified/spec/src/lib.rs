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

//! Fixture: the spec crate side (no extra cfgs, so toit_vcore_hosted is not
//! a Verus cfg here), allowlist cases and the cross-check with
//! `verus --no-cheating`.

#![cfg_attr(not(verus_keep_ghost), no_std)]

use vstd::prelude::*;

verus! {

#[verifier::external_body]
pub fn listed(x: u8) -> u8 {
    x
}

#[verifier::external_body]
pub fn count_changed(x: u8) -> u8 {
    unsafe { }
    unsafe { }
    x
}

#[verifier::external_body]
pub fn no_justification() {
}

#[cfg(toit_vcore_hosted)]
fn hosted_is_plain_here() {
}

proof fn rejected_but_unflagged()
    ensures true,
{
}

proof fn rejected_and_flagged()
    ensures true,
{
    assume(false);
}

pub fn exec_entry(v: &Vec<u8>) -> (r: usize)
    ensures r == v.len(),
{
    v.len()
}

pub fn not_an_entry(v: &Vec<u8>) -> usize {
    v.len()
}

proof fn same_name_hides()
    ensures true,
{
}

fn mentions_same_name_hides() {
    let same_name_hides = 0;
}

pub mod nested {
    pub mod deeper {
        pub fn in_nested_module(x: u8) -> (r: u8)
            ensures r == x,
        {
            x
        }
    }
}

} // verus!

// Not verified: the reference interpreter's helpers.
pub fn interp_helper() {}
