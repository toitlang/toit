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

//! The verified interpreter core for format-2 programs (Phase 4).
//!
//! - `layout`:  constants assumed about the C++ VM (checked at build time).
//! - `view`:    TRUSTED raw-memory views (see TRUSTED.md).
//! - `ffi`:     TRUSTED C ABI glue and the C++ functions the core calls.
//! - `exec`:    the machine state and the verified opcode handlers.
//! - `machine`: the run loop and the handlers not yet verified
//!              (OBLIGATIONS.md).
//!
//! See DESIGN.md.

#![allow(unused_parens, unused_variables, dead_code)]

pub mod layout;
pub mod view;
pub mod ffi;
pub mod exec;
pub mod machine;
