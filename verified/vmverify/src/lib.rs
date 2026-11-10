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
//! - `alloc`:     the counting allocator (memory high-water mark).
//! - `canonical`: test support: canonical text of an abstract program.
//! - `tables`:    test support: the FFI input saved and loaded (fuzzing).

pub mod alloc;
pub mod canonical;
pub mod ffi;
pub mod from_vm;
pub mod tables;
pub mod verify;

// The core's C entry points are part of this library.
pub use toit_verified_core;
