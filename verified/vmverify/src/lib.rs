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

//! The format-2 structural verifier as the VM runs it at untrusted launch
//! (README.md), and the one Rust static library the VM links: it contains
//! the verified core (`toit_verified_core`), so the binary has a single
//! Rust runtime.
//!
//! - `from_vm`:   TRUSTED. The abstract program and heap from VM memory.
//! - `verify`:    TRUSTED. The verdict: heap check + proven `check::verify`.
//! - `ffi`:       TRUSTED. The C ABI (src/verifier_v2.h).
//! - `counting`:  the counting allocator (memory high-water mark; std).
//! - `clock`:     phase times (std; zero without).
//! - `canonical`: test support: canonical text of an abstract program.
//! - `tables`:    test support: the FFI input saved and loaded (fuzzing).
//! - `device`:    TRUSTED. Devices (`device-runtime`): allocator and panic
//!                handler supplied by the VM.

// Without the `std` feature (devices): `no_std` + `alloc`, no panic
// catching, no timing, no counting allocator, no test support.
#![cfg_attr(not(feature = "std"), no_std)]

extern crate alloc;

pub mod clock;
#[cfg(feature = "std")]
pub mod counting;
#[cfg(feature = "std")]
pub mod canonical;
pub mod ffi;
pub mod from_vm;
#[cfg(feature = "std")]
pub mod tables;
pub mod verify;
#[cfg(all(not(feature = "std"), not(test), feature = "device-runtime"))]
mod device;

// The core's C entry points are part of this library.
pub use toit_verified_core;
