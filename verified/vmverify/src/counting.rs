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

//! A counting global allocator: the high-water mark of the Rust heap during
//! a verification (`VerifyResult::peak_bytes`). Host builds only (`std`). One relaxed atomic add per
//! allocation and free; the verified core does not allocate on its paths.

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};

struct Counting;

static CURRENT: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let p = System.alloc(layout);
        if !p.is_null() { grow(layout.size()); }
        p
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let p = System.alloc_zeroed(layout);
        if !p.is_null() { grow(layout.size()); }
        p
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout);
        CURRENT.fetch_sub(layout.size(), Ordering::Relaxed);
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let p = System.realloc(ptr, layout, new_size);
        if !p.is_null() {
            CURRENT.fetch_sub(layout.size(), Ordering::Relaxed);
            grow(new_size);
        }
        p
    }
}

fn grow(n: usize) {
    let now = CURRENT.fetch_add(n, Ordering::Relaxed).wrapping_add(n);
    PEAK.fetch_max(now, Ordering::Relaxed);
}

#[global_allocator]
static GLOBAL: Counting = Counting;

/// Starts a measurement: returns the current level and resets the peak to it.
pub fn start_peak() -> usize {
    let now = CURRENT.load(Ordering::Relaxed);
    PEAK.store(now, Ordering::Relaxed);
    BASE.store(now, Ordering::Relaxed);
    now
}

/// The current level of the Rust heap.
pub fn current() -> usize {
    CURRENT.load(Ordering::Relaxed)
}

/// The peak since `start_peak` returned `base`, above `base`.
pub fn peak_since(base: usize) -> usize {
    PEAK.load(Ordering::Relaxed).saturating_sub(base)
}

static BASE: AtomicUsize = AtomicUsize::new(0);

/// With TOIT_VERIFY_MEM=1: prints the heap level and the high-water mark
/// at a `phase` of the verification to stderr, relative to the level at
/// `start_peak` (README.md, "Memory").
pub fn trace(phase: &str) {
    if std::env::var_os("TOIT_VERIFY_MEM").map_or(false, |v| v == "1") {
        let base = BASE.load(Ordering::Relaxed);
        eprintln!("vmverify mem {}: level {} B, peak {} B", phase,
                  current().saturating_sub(base), PEAK.load(Ordering::Relaxed).saturating_sub(base));
    }
}
