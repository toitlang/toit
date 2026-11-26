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

//! The revised bytecode format (format 2). See `format/README.md`.

pub mod bytecodes;
pub mod types;
pub mod spec;
pub mod prim;
pub mod prim_core;
#[cfg(any(feature = "std", verus_keep_ghost))]
pub mod exec;
pub mod verifier;
pub mod sound;
pub mod sound_frames;
pub mod sound_local;
pub mod sound_call;
pub mod sound_upto;
pub mod sound_unwind;
pub mod sound_return;
pub mod sound_instr;
pub mod sound_raise;
pub mod sound_heap;
pub mod sound_ctx;
pub mod sound_unwind_ops;
pub mod sound_tail;
pub mod sound_prim;
pub mod sound_call_ops;
pub mod sound_virtual;
pub mod sound_local_ops;
pub mod sound_hash;
pub mod sound_field;
pub mod sound_block;
pub mod sound_resource;
pub mod sound_prim_spec;
pub mod gc;
pub mod sound_step;
pub mod theorem;
pub mod vprog;
pub mod split;
#[allow(unused_variables)]
pub mod check;
#[allow(unused_variables)]
pub mod cert;
#[allow(unused_variables)]
pub mod walk;
#[cfg(all(not(verus_keep_ghost), feature = "infer"))]
pub mod infer;
#[cfg(all(not(verus_keep_ghost), feature = "infer"))]
pub mod gbuf;
#[cfg(all(not(verus_keep_ghost), feature = "infer"))]
pub mod encode;
pub mod heap_check;
pub mod prim_arity;
