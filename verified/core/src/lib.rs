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
//! - `view`:    TRUSTED raw-memory views and the heap model (TRUSTED.md).
//! - `ffi`:     TRUSTED C ABI glue and the C++ functions the core calls.
//! - `abs`:     the abstraction: value encoding, frame records, program.
//! - `exec`:    the machine, `refines`/`inv`, the top-frame handlers.
//! - `step`:    the verified run loop and dispatch; the assumed bridges.
//! - `calls`, `fields`, `types`, `blocks`, `ops`: verified handler
//!              families (refinement of `spec::step`).
//! - `machine`: the checked handlers (unverified; programs not accepted
//!              and the paths not proven yet, OBLIGATIONS.md).
//! - `theorem`: the end-to-end statement.
//!
//! See DESIGN.md.

// no_std + alloc on every target (it uses no std API): the VM links it
// through verified/vmverify, which brings std on hosts and the VM's
// allocator and panic handler on devices (vmverify/src/device.rs).
#![no_std]
#![cfg_attr(target_arch = "xtensa", feature(optimize_attribute))]
#![allow(unused_parens, unused_variables, dead_code, unused_imports, unused_braces)]

pub mod layout;
pub mod view;
pub mod abs;
pub mod ffi;
pub mod exec;
pub mod regs;
pub mod room;
pub mod rcalls;
pub mod rfields;
pub mod rops;
pub mod rblocks;
pub mod rarrays;
pub mod rloops;
pub mod rhash;
pub mod rnonlocal;
pub mod rfins;
pub mod machine;
pub mod step;
pub mod calls;
pub mod fields;
pub mod types;
pub mod blocks;
pub mod ops;
pub mod halt;
pub mod globals;
pub mod alloc;
pub mod arrays;
pub mod theorem;
pub mod prims;
pub mod unwind;
pub mod numbers;
pub mod tail;
pub mod raise;
pub mod primitive;
pub mod gcbridge;
pub mod process;
