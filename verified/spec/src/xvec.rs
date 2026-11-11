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

//! TRUSTED: vector and slice accessors without panic paths, for the code
//! devices run (the checker of shipped certificates, the heap check and
//! their glue; verified/vmverify/README.md, "No panics on devices").
//!
//! - Element access (`ix`, `ix_ref`, `vix`, `vput`, `subslice`): `v[i]` compiles to a
//!   bounds check whose failure calls `core::panicking::panic_bounds_check`,
//!   which links the formatting machinery and the panic locations even
//!   where Verus has proven the index in bounds. These take the index as a
//!   precondition, which Verus discharges at every call site, and skip the
//!   check.
//! - Growth (`try_push`, `try_with_capacity`): `Vec::push` aborts when the
//!   allocation fails (`handle_alloc_error`); on a device a verification
//!   that runs out of memory must reject the program instead. These reserve
//!   fallibly and report `Oom`, which the checker passes up (its results
//!   are exact unless it ran out of memory: `Result<_, Oom>`).
//!
//! Each body is a few lines of plain Rust whose contract is the one of the
//! standard library operation it replaces (vstd's `Vec::push`, `Vec::set`,
//! `Vec::index`, `slice_subrange`); listed in verified/TRUSTED.toml.

use vstd::prelude::*;
use alloc::vec::Vec;

verus! {

/// A fallible allocation failed: the verification rejects the program.
#[derive(Clone, Copy)]
pub struct Oom;

/// `s[i]` without the bounds check.
#[verifier::external_body]
#[inline(always)]
pub fn ix<T: Copy>(s: &[T], i: usize) -> (r: T)
    requires i < s@.len(),
    ensures r == s@[i as int],
{
    // SAFETY: `i < s.len()` (the precondition).
    unsafe { *s.get_unchecked(i) }
}

/// `&s[i]` without the bounds check.
#[verifier::external_body]
#[inline(always)]
pub fn ix_ref<T>(s: &[T], i: usize) -> (r: &T)
    requires i < s@.len(),
    ensures *r == s@[i as int],
{
    // SAFETY: `i < s.len()` (the precondition).
    unsafe { s.get_unchecked(i) }
}

/// `v[i]` without the bounds check.
#[verifier::external_body]
#[inline(always)]
pub fn vix<T: Copy>(v: &Vec<T>, i: usize) -> (r: T)
    requires i < v@.len(),
    ensures r == v@[i as int],
{
    // SAFETY: `i < v.len()` (the precondition).
    unsafe { *v.get_unchecked(i) }
}

/// `v.set(i, x)` without the bounds check.
#[verifier::external_body]
#[inline(always)]
pub fn vput<T>(v: &mut Vec<T>, i: usize, x: T)
    requires i < old(v)@.len(),
    ensures final(v)@ == old(v)@.update(i as int, x),
{
    // SAFETY: `i < v.len()` (the precondition).
    unsafe { *v.get_unchecked_mut(i) = x; }
}

/// `&s[i..j]` without the bounds check.
#[verifier::external_body]
#[inline(always)]
pub fn subslice<T>(s: &[T], i: usize, j: usize) -> (r: &[T])
    requires i <= j <= s@.len(),
    ensures r@ == s@.subrange(i as int, j as int),
{
    // SAFETY: `i <= j <= s.len()` (the precondition).
    unsafe { s.get_unchecked(i..j) }
}

/// `v.push(x)`, or `Err(Oom)` (and `v` unchanged) if the allocation fails.
/// The capacity grows as `Vec::push` grows it (`try_reserve(1)`).
#[verifier::external_body]
pub fn try_push<T>(v: &mut Vec<T>, x: T) -> (r: Result<(), Oom>)
    ensures
        r is Ok ==> final(v)@ == old(v)@.push(x),
        r is Err ==> final(v)@ == old(v)@,
{
    if v.len() == v.capacity() && v.try_reserve(1).is_err() {
        return Err(Oom);
    }
    // SAFETY: `len < capacity` here, so slot `len` is allocated and
    // uninitialized; it becomes the last element.
    unsafe {
        let len = v.len();
        v.as_mut_ptr().add(len).write(x);
        v.set_len(len + 1);
    }
    Ok(())
}

/// A copy of `s` (`s.to_vec()`), or `Err(Oom)`.
#[verifier::external_body]
pub fn try_copy<T: Copy>(s: &[T]) -> (r: Result<Vec<T>, Oom>)
    ensures r matches Ok(v) ==> v@ == s@,
{
    let mut v: Vec<T> = Vec::new();
    if v.try_reserve_exact(s.len()).is_err() {
        return Err(Oom);
    }
    // SAFETY: the capacity is at least `s.len()`; the elements are `Copy`
    // and the regions are distinct allocations.
    unsafe {
        core::ptr::copy_nonoverlapping(s.as_ptr(), v.as_mut_ptr(), s.len());
        v.set_len(s.len());
    }
    Ok(v)
}

/// `n` copies of `x` (`vec![x; n]`), or `Err(Oom)`.
#[verifier::external_body]
pub fn try_filled<T: Copy>(x: T, n: usize) -> (r: Result<Vec<T>, Oom>)
    ensures r matches Ok(v) ==> v@ == Seq::new(n as nat, |i: int| x),
{
    let mut v: Vec<T> = Vec::new();
    if v.try_reserve_exact(n).is_err() {
        return Err(Oom);
    }
    // SAFETY: the capacity is at least `n`; each slot below `n` is written
    // before the length covers it.
    unsafe {
        let p = v.as_mut_ptr();
        for i in 0..n {
            p.add(i).write(x);
        }
        v.set_len(n);
    }
    Ok(v)
}

/// An empty vector with room for `n` elements, or `Err(Oom)`.
#[verifier::external_body]
pub fn try_with_capacity<T>(n: usize) -> (r: Result<Vec<T>, Oom>)
    ensures r matches Ok(v) ==> v@.len() == 0,
{
    let mut v = Vec::new();
    if v.try_reserve_exact(n).is_err() {
        return Err(Oom);
    }
    Ok(v)
}

} // verus!
