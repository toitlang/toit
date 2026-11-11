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

//! TRUSTED (devices, `no_std`): the Rust runtime the VM supplies.
//!
//! - Allocation goes to the VM's `malloc`/`free`/`realloc` (on ESP-IDF the
//!   VM's heap, with its accounting and out-of-memory handling). Rust
//!   types of this library need at most 8-byte alignment, which `malloc`
//!   gives; a larger alignment fails the allocation (null).
//! - A panic calls `toit_vmverify_panic` (the VM: `FATAL`, which reboots a
//!   device). The library is built with `panic = "abort"` for devices
//!   (Cargo profile `device`): there is no unwinding without std. Hosts
//!   keep std and the verifier's `catch_unwind` (a panic of the inference
//!   rejects the program, ffi.rs). On devices the verifier relies on the
//!   inference being total (fuzzed: README.md, "Fuzzing the entry point").

use core::alloc::{GlobalAlloc, Layout};
use core::ffi::c_void;

extern "C" {
    fn malloc(size: usize) -> *mut c_void;
    fn free(p: *mut c_void);
    fn realloc(p: *mut c_void, size: usize) -> *mut c_void;
    /// The VM's handler of a Rust panic; does not return.
    fn toit_vmverify_panic(message: *const u8, length: usize) -> !;
}

/// The alignment `malloc` guarantees on every supported device.
const MALLOC_ALIGN: usize = 8;

struct VmAllocator;

unsafe impl GlobalAlloc for VmAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if layout.align() > MALLOC_ALIGN { return core::ptr::null_mut(); }
        malloc(layout.size()) as *mut u8
    }

    unsafe fn dealloc(&self, ptr: *mut u8, _layout: Layout) {
        free(ptr as *mut c_void)
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        if layout.align() > MALLOC_ALIGN { return core::ptr::null_mut(); }
        realloc(ptr as *mut c_void, new_size) as *mut u8
    }
}

#[global_allocator]
static ALLOCATOR: VmAllocator = VmAllocator;

#[panic_handler]
fn panic(info: &core::panic::PanicInfo) -> ! {
    // The location only: formatting the message would pull in the
    // formatting machinery for a path that ends the VM anyway.
    let file = match info.location() {
        Some(l) => l.file(),
        None => "unknown",
    };
    unsafe { toit_vmverify_panic(file.as_ptr(), file.len()) }
}
