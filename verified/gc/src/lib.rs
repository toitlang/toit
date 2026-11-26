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

//! The copying collector for sandboxed processes, proved (README.md next to
//! Cargo.toml): a Cheney copy of everything reachable from the roots, from
//! a list of pages (from-space) into pages taken one at a time from a page
//! source (to-space), with next-fit placement, forwarding headers and a scan
//! pointer that walks the to-space pages in order.
//!
//! The top-level statement is `cheney::collect`'s contract (`collected`):
//! the abstract heap is unchanged (object ids are stable); the copied
//! objects are exactly the from-space objects reachable from the roots;
//! each is at a distinct new tagged address, where its words are its
//! abstract words with every reference encoded under the new address map;
//! every root holds its abstract value under the new map; the pages used
//! are at most twice the from-space pages plus one. `bridge` shows that
//! this implies the core's `gcbridge::collected` for the spec's heap.
//!
//! Modules:
//! - `model`: the abstract heap (objects as words: references and raw
//!   words), the from-space description, the encoding.
//! - `layout`: object sizes and reference slots from the header (the one
//!   place that knows object layouts).
//! - `space`: the page tables, the from-space membership test, the page
//!   source (trusted boundary) and to-space placement.
//! - `cheney`: copy, forward, roots, scan, the collection.
//! - `bridge` (Verus only, with the spec and core crates): the connection
//!   to `toit_verified_core::gcbridge::collected`.

#![no_std]
#![allow(unused_imports)]

use vstd::prelude::*;
use vstd::raw_ptr::*;

pub mod model;
pub mod layout;
pub mod space;
pub mod cheney;
pub mod copy;
pub mod collect;
pub mod statement;
pub mod fin;
pub mod tail;
#[cfg(all(verus_keep_ghost, toit_gc_bridge))]
pub mod bridge;

verus! {

// TRUSTED (as verified/core/src/abs.rs, compile-time checked by Verus for
// the target it verifies for): the word is 8 bytes on 64-bit targets and 4
// on 32-bit ones. check.sh verifies the crate for both.
#[cfg(target_pointer_width = "64")]
global size_of usize == 8;
#[cfg(target_pointer_width = "32")]
global size_of usize == 4;

/// Bytes per word.
#[cfg(target_pointer_width = "64")]
pub const W: usize = 8;
#[cfg(target_pointer_width = "32")]
pub const W: usize = 4;

/// The heap tag of an object reference (`Object::HEAP_TAG`).
pub const HEAP_TAG: usize = 1;

pub proof fn lemma_w()
    ensures W == size_of::<usize>(), W == 4 || W == 8, W % 2 == 0,
{
}

// ---------------------------------------------------------------------------
// Addresses. Word `i` of the memory at `base` is the pointer with base's
// provenance and address `base + i * W` (`<*mut T>::with_addr`, whose
// specification is vstd's). No wrapping: every address computed is inside
// a page, which lies in the address space.

pub open spec fn at(base: *mut usize, i: int) -> *mut usize {
    ptr_mut_from_data::<usize>(PtrData::<usize> {
        addr: (base@.addr + i * W) as usize,
        provenance: base@.provenance,
        metadata: (),
    })
}

/// The pointer to word `i` of the memory at `base`.
#[inline(always)]
pub fn word_ptr(base: *mut usize, i: usize) -> (p: *mut usize)
    requires base@.addr + i * W <= usize::MAX,
    ensures p == at(base, i as int),
{
    proof { lemma_w(); }
    base.with_addr(base.addr() + i * W)
}

/// A permission of word `i` of `base`, under key `key`.
pub open spec fn wperm_ok<K>(perms: Map<K, PointsTo<usize>>, key: K, base: *mut usize, i: int) -> bool {
    perms.contains_key(key) && perms[key].ptr() == at(base, i)
}

/// Reads word `i` of `base` through the permission under `key`.
#[inline(always)]
pub fn rd<K>(base: *mut usize, i: usize, Ghost(key): Ghost<K>, Tracked(perms): Tracked<&Map<K, PointsTo<usize>>>) -> (v: usize)
    requires
        wperm_ok(*perms, key, base, i as int), perms[key].is_init(),
        base@.addr + i * W <= usize::MAX,
    ensures v == perms[key].value(),
{
    *ptr_ref(word_ptr(base, i), Tracked(perms.tracked_borrow(key)))
}

/// Writes word `i` of `base` through the permission under `key`.
#[inline(always)]
pub fn wr<K>(base: *mut usize, i: usize, v: usize, Ghost(key): Ghost<K>, Tracked(perms): Tracked<&mut Map<K, PointsTo<usize>>>)
    requires
        wperm_ok(*old(perms), key, base, i as int),
        base@.addr + i * W <= usize::MAX,
    ensures
        final(perms).dom() == old(perms).dom(),
        final(perms)[key].ptr() == old(perms)[key].ptr(),
        final(perms)[key].is_init(),
        final(perms)[key].value() == v,
        forall|k: K| k != key ==> #[trigger] final(perms)[k] == old(perms)[k],
{
    ptr_mut_write(word_ptr(base, i), Tracked(perms.tracked_borrow_mut(key)), v);
}

} // verus!
