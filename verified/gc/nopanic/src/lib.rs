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

//! A C entry point around the collector (the shape of the M5 FFI; not
//! verified, not linked into the VM): the page source is three extern
//! functions, the ghost arguments are erased (`assume_new`, which is how
//! the trusted entry derivation of M5 will look). check.sh links this for
//! riscv32 and thumbv7m with --gc-sections and fails if any panic or
//! formatting machinery survives.

#![no_std]

use toit_gc::model::Ctx;
use toit_gc::space::PageSource;
use toit_gc::statement::collect;
use vstd::prelude::*;

extern "C" {
    fn toit_gc_page_reserve(n: usize) -> bool;
    fn toit_gc_page_take() -> usize;
    fn toit_gc_page_release();
    fn toit_gc_panic() -> !;
}

struct ExternPages;

impl PageSource for ExternPages {
    fn reserve(&mut self, n: usize) -> bool {
        unsafe { toit_gc_page_reserve(n) }
    }
    fn take(&mut self, _key: Ghost<int>) -> (usize, Tracked<Map<(int, int), vstd::raw_ptr::PointsTo<usize>>>) {
        (unsafe { toit_gc_page_take() }, Tracked::assume_new())
    }
    fn release(&mut self) {
        unsafe { toit_gc_page_release() }
    }
}

/// Collects; returns the number of pages (0 if the collection did not
/// start) and stores the used words of the last page in `*top`.
#[no_mangle]
pub extern "C" fn toit_gc_collect(base: *mut usize, ftab: *mut usize, nf: usize, pw: usize,
                                  ctab: *mut u16, ncls: usize, sw: usize, null: usize,
                                  nodes: *mut usize, ncb: usize, nn: usize,
                                  roots: *mut usize, nroots: usize,
                                  ttab: *mut usize, tused: *mut usize, tcap: usize, top: *mut usize) -> usize {
    let c = Ctx { base, ftab, nf, pw, ctab, ncls, sw, null, nullid: Ghost::assume_new(), fss: Ghost::assume_new(), cbs: Ghost::assume_new() };
    let mut src = ExternPages;
    match collect(&c, &mut src, roots, nroots, ttab, tused, tcap, nodes, ncb, nn,
                  Ghost::assume_new(), Ghost::assume_new(), Ghost::assume_new(), Tracked::assume_new(), Tracked::assume_new(),
                  Tracked::assume_new()) {
        Ok(w) => {
            unsafe { *top = w.top; }
            w.pages
        }
        Err(_) => 0,
    }
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    unsafe { toit_gc_panic() }
}
