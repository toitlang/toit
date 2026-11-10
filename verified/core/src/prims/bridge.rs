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

//! TEMPORARY, plain Rust: the opt-in hook at the C++ bridge call site of
//! the checked PRIMITIVE handler (`machine.rs`, `op_primitive_cold`, one
//! line). With `TOIT_V2_RUST_PRIMITIVES=1` a primitive the policy resolves
//! to the VM's own entry (`PrimitiveRef::rust`) runs as its Rust port
//! (`prims::call`); `NotPorted` falls back to the C++ primitive.
//!
//! The retry protocol is the C++ one (`toit_v2_call_primitive`): on
//! `NeedsGc` collect garbage (attempts 1 and 2 collect, attempt 3 only
//! reports, as `v2_gc`) and call the primitive again; a fourth failure
//! throws ALLOCATION_FAILED. The caller has saved the machine state into
//! the Stack object (`Machine::save`), so the GC sees the task; the stack
//! view is replaced after each GC and the arguments are re-read from it.
//!
//! Not verified: the preconditions of `prims::call` (`heap_inv`,
//! `args_ok`) hold because the machine refines a well-formed state (the
//! arguments are the top frame's parameters, `spec::prim_args`); the
//! verified PRIMITIVE handler (branch core/refinement-2) replaces this file
//! and proves them.

use crate::exec::Env;
use crate::ffi::PrimitiveRef;
use crate::layout::*;
use crate::prims::{call, PrimOutcome};
use crate::view::{Heap, StackMem};
use vstd::prelude::Ghost;

/// Runs the primitive: its Rust port if enabled and ported, else the C++
/// entry. Same result convention as `Runtime::call_primitive`: (status,
/// value) with `V2_PRIMITIVE_SUCCESS`, `_FAILURE` or `_THROW`.
#[inline(never)]
pub fn bridge(mem: &mut StackMem, heap: &mut Heap, env: &Env, primitive: &PrimitiveRef,
              module: usize, index: usize, arity: usize, first: usize) -> (usize, usize) {
    if primitive.rust() && module < 256 && index < 0x1_0000 {
        let al = env.rt.allocator();
        let mut attempt = 0;
        loop {
            let len = mem.len();
            if first >= len { break; }
            let at = len - 1 - first;
            if arity > at + 1 { break; }
            let (r, _) = call(module as u8, index as u16, mem, at, arity, heap, env.p, &al, Ghost::assume_new());
            match r {
                PrimOutcome::Success(w) => {
                    if attempt > 0 { env.rt.leave_primitive(); }
                    return (V2_PRIMITIVE_SUCCESS, w);
                }
                PrimOutcome::Failure(w) => {
                    if attempt > 0 { env.rt.leave_primitive(); }
                    return (V2_PRIMITIVE_FAILURE, w);
                }
                PrimOutcome::NotPorted => {
                    if attempt > 0 { env.rt.leave_primitive(); }
                    break;
                }
                PrimOutcome::NeedsGc => {
                    attempt += 1;
                    if attempt > 3 {
                        env.rt.leave_primitive();
                        return (V2_PRIMITIVE_THROW, env.p.roots.at(ROOT_ALLOCATION_FAILED));
                    }
                    env.rt.primitive_gc(mem, attempt);
                }
            }
        }
    }
    env.rt.call_primitive(mem, primitive, arity, first)
}
