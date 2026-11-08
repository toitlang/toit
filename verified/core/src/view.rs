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

//! TRUSTED: the only place that touches raw pointers.
//!
//! Each view wraps memory owned by the C++ VM and exposes it to verified
//! code as a ghost sequence. Every `external_body` item here is listed with
//! its assumed contract in `TRUSTED.md`. Keep this file small.

use vstd::prelude::*;

verus! {

/// The stack object's word array `[limit_, base_)`.
#[verifier::external_body]
pub struct StackView {
    ptr: *mut usize,
    len: usize,
}

impl StackView {
    /// Ghost contents of the stack array.
    pub uninterp spec fn view(&self) -> Seq<usize>;

    #[verifier::external_body]
    pub fn len(&self) -> (r: usize)
        ensures
            r == self@.len(),
    {
        self.len
    }

    #[verifier::external_body]
    pub fn read(&self, i: usize) -> (r: usize)
        requires
            i < self@.len(),
        ensures
            r == self@[i as int],
    {
        unsafe { *self.ptr.add(i) }
    }

    #[verifier::external_body]
    pub fn write(&mut self, i: usize, v: usize)
        requires
            i < old(self)@.len(),
        ensures
            final(self)@ == old(self)@.update(i as int, v),
    {
        unsafe { *self.ptr.add(i) = v }
    }
}

/// The program's bytecodes (read only).
#[verifier::external_body]
pub struct CodeView {
    ptr: *const u8,
    len: usize,
}

impl CodeView {
    pub uninterp spec fn view(&self) -> Seq<u8>;

    #[verifier::external_body]
    pub fn len(&self) -> (r: usize)
        ensures
            r == self@.len(),
    {
        self.len
    }

    #[verifier::external_body]
    pub fn byte(&self, i: usize) -> (r: u8)
        requires
            i < self@.len(),
        ensures
            r == self@[i as int],
    {
        unsafe { *self.ptr.add(i) }
    }
}

/// The program's dispatch table (read only).
#[verifier::external_body]
pub struct DispatchView {
    ptr: *const i32,
    len: usize,
}

impl DispatchView {
    pub uninterp spec fn view(&self) -> Seq<i32>;

    #[verifier::external_body]
    pub fn len(&self) -> (r: usize)
        ensures
            r == self@.len(),
    {
        self.len
    }

    #[verifier::external_body]
    pub fn at(&self, i: usize) -> (r: i32)
        requires
            i < self@.len(),
        ensures
            r == self@[i as int],
    {
        unsafe { *self.ptr.add(i) }
    }
}

/// The interpreter's stack-overflow/preemption watermark. Read with the
/// same comparison as CHECK_STACK_OVERFLOW. No contract: its answer is
/// treated as environment nondeterminism by the spec.
#[verifier::external_body]
pub struct RoomOracle {
    limit: *mut usize,
    watermark: *const core::sync::atomic::AtomicUsize,
}

impl RoomOracle {
    /// True if `sp - max_height >= watermark_` where `sp` is the address of
    /// stack index `new_sp`.
    #[verifier::external_body]
    pub fn has_room(&self, new_sp: usize, max_height: usize) -> (r: bool) {
        let watermark = unsafe { (*self.watermark).load(core::sync::atomic::Ordering::Relaxed) };
        let word = core::mem::size_of::<usize>();
        let sp = (self.limit as usize).wrapping_add(new_sp.wrapping_mul(word));
        let lowest = sp.wrapping_sub(max_height.wrapping_mul(word));
        // Pointer comparison as in C++; guard against wrap-around below 0.
        lowest <= sp && lowest >= watermark
    }
}

} // verus!

// Constructors are invisible to the verifier (they create the ghost views).
impl StackView {
    /// # Safety
    /// `ptr..ptr+len` must be valid, writable, word-aligned, and not
    /// accessed by anyone else for the lifetime of the view.
    pub unsafe fn from_raw(ptr: *mut usize, len: usize) -> Self {
        StackView { ptr, len }
    }
}

impl CodeView {
    /// # Safety
    /// `ptr..ptr+len` must be valid and immutable for the lifetime of the view.
    pub unsafe fn from_raw(ptr: *const u8, len: usize) -> Self {
        CodeView { ptr, len }
    }
}

impl DispatchView {
    /// # Safety
    /// `ptr..ptr+len` must be valid, aligned and immutable for the lifetime
    /// of the view.
    pub unsafe fn from_raw(ptr: *const i32, len: usize) -> Self {
        DispatchView { ptr, len }
    }
}

impl RoomOracle {
    /// # Safety
    /// `watermark` must point to the interpreter's `std::atomic<Object**>`.
    pub unsafe fn from_raw(limit: *mut usize, watermark: *const core::sync::atomic::AtomicUsize) -> Self {
        RoomOracle { limit, watermark }
    }
}
