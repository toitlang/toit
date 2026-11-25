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

//! Executable specification of the Toit bytecode machine.
//!
//! * `types`, `bytecodes`: the abstract state and opcode table.
//! * `spec_common`, `spec_helpers`, `spec_step`, `spec_prim`: the Verus
//!   spec-mode step function for all 105 opcodes.
//! * `exec_step`: verified executable implementations of the stack and
//!   arithmetic opcodes, proven equal to `spec_step`.
//! * `interp`: the reference interpreter (plain Rust, not verified) that
//!   runs real snapshots, using `exec_step` for the opcodes it covers.
//!
//! See DESIGN.md.

#![allow(unused_imports)]
// Without the `std` feature: the verifier only (no reference interpreter),
// for devices (`no_std` + `alloc`).
#![cfg_attr(not(any(feature = "std", verus_keep_ghost)), no_std)]

extern crate alloc;

pub mod xvec;
pub mod cvec;
pub mod types;
pub mod bytecodes;
pub mod spec_common;
pub mod spec_helpers;
pub mod spec_step;
pub mod spec_prim;
// Format 1 exec steps and the format-2 exec step use the reference
// interpreter's float helpers: std only.
// The executable step (format 1) and the float helpers the core uses: no_std.
pub mod exec_step;
pub mod v2;
// Install-time verification with progress reports (v2::cert::verify_shipped
// plus a callback per method).
pub mod progress;
#[cfg(any(feature = "std", verus_keep_ghost))]
pub mod interp;
