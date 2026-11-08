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

//! Verified interpreter core for the Toit VM (Phase 0 spike).
//!
//! - `layout`: constants assumed about the C++ VM (checked at build time).
//! - `spec`:   abstract machine step for the covered opcodes.
//! - `view`:   TRUSTED raw-memory views (see TRUSTED.md).
//! - `exec`:   verified handlers refining `spec`.
//! - `ffi`:    TRUSTED C ABI glue (see TRUSTED.md).

#![no_std]

pub mod layout;
pub mod spec;
pub mod view;
pub mod exec;
pub mod ffi;

#[cfg(not(any(test, toit_vcore_hosted)))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    // Verified code contains no panicking operations; this is unreachable
    // unless the trusted layer is wrong.
    extern "C" {
        fn abort() -> !;
    }
    unsafe { abort() }
}

/// The precompiled `core` of a no_std staticlib references the unwinding
/// personality even with panic = "abort". Nothing unwinds through the core,
/// so it is never called.
#[cfg(not(any(test, toit_vcore_hosted)))]
#[no_mangle]
pub extern "C" fn rust_eh_personality() {}
