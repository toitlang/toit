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

//! The step function: one bytecode of the running task.
//!
//! Every opcode handler in `src/interpreter_run.cc` has a spec function
//! `op_*` here. `step` decodes the instruction at `s.bci` and dispatches.

use vstd::prelude::*;
use crate::types::*;
use crate::bytecodes::*;
use crate::spec_common::*;
use crate::spec_helpers::*;

verus! {

// ---------------------------------------------------------------------------
// Locals.

/// LOAD_LOCAL n, LOAD_LOCAL_WIDE n, LOAD_LOCAL_0..5.
pub open spec fn op_load_local(s: State, n: int, len: int) -> Outcome {
    if !has_slot(s, n) {
        stuck(Stuck::StackRange)
    } else if !is_value(at(s, n)) {
        stuck(Stuck::FrameWord)
    } else {
        next(push(s, at(s, n)), len)
    }
}

/// POP_LOAD_LOCAL n: replace the top with STACK_AT(n + 1).
pub open spec fn op_pop_load_local(s: State, n: int) -> Outcome {
    if !has_slot(s, n + 1) {
        stuck(Stuck::StackRange)
    } else if !is_value(at(s, n + 1)) || !is_value(at(s, 0)) {
        stuck(Stuck::FrameWord)
    } else {
        next(put(s, 0, at(s, n + 1)), 2)
    }
}

/// STORE_LOCAL n: STACK_AT(n) = top (top stays).
pub open spec fn op_store_local(s: State, n: int) -> Outcome {
    if !has_slot(s, n) {
        stuck(Stuck::StackRange)
    } else if !is_value(at(s, n)) || !is_value(at(s, 0)) {
        stuck(Stuck::FrameWord)
    } else {
        next(put(s, n, at(s, 0)), 2)
    }
}

/// STORE_LOCAL_POP n: pop v; STACK_AT(n - 1) = v. n == 0 would write the
/// slot that was just popped (outside the stack).
pub open spec fn op_store_local_pop(s: State, n: int) -> Outcome {
    if n < 1 || !has_slot(s, n) {
        stuck(Stuck::StackRange)
    } else if !is_value(at(s, n)) || !is_value(at(s, 0)) {
        stuck(Stuck::FrameWord)
    } else {
        next(put(drop(s, 1), n - 1, at(s, 0)), 2)
    }
}

/// Stack index of `block_ptr[k]` for block reference height `h`.
pub open spec fn outer_index(h: int, k: int) -> int {
    h - 1 - k
}

/// LOAD_OUTER k: pop a block reference, push `block_ptr[k]`.
pub open spec fn op_load_outer(s: State, k: int) -> Outcome {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else {
        match at(s, 0) {
            Value::Block(h) => {
                let s1 = drop(s, 1);
                let i = outer_index(h as int, k);
                if !(0 <= i < s1.stack.len()) {
                    stuck(Stuck::StackRange)
                } else if !is_value(s1.stack[i]) {
                    stuck(Stuck::FrameWord)
                } else {
                    next(push(s1, s1.stack[i]), 2)
                }
            },
            _ => stuck(Stuck::NotBlock),
        }
    }
}

/// STORE_OUTER k: pop value, pop block reference, `block_ptr[k] = value`,
/// push value.
pub open spec fn op_store_outer(s: State, k: int) -> Outcome {
    if !has_slot(s, 1) {
        stuck(Stuck::StackRange)
    } else {
        let v = at(s, 0);
        match at(s, 1) {
            Value::Block(h) => {
                let s1 = drop(s, 2);
                let i = outer_index(h as int, k);
                if !(0 <= i < s1.stack.len()) {
                    stuck(Stuck::StackRange)
                } else if !is_value(s1.stack[i]) || !is_value(v) {
                    stuck(Stuck::FrameWord)
                } else {
                    next(push(State { stack: s1.stack.update(i, v), ..s1 }, v), 2)
                }
            },
            _ => stuck(Stuck::NotBlock),
        }
    }
}

// ---------------------------------------------------------------------------
// Fields.

pub open spec fn field_ok(s: State, inst: Value, f: int) -> Option<Stuck> {
    if !is_instance(s, inst) {
        Some(Stuck::NotInstance)
    } else if !(0 <= f < fields(s, inst).len()) {
        Some(Stuck::FieldRange)
    } else {
        None
    }
}

/// LOAD_FIELD f: replace the instance on top with its field `f`.
pub open spec fn op_load_field(s: State, f: int, len: int) -> Outcome {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else {
        match field_ok(s, at(s, 0), f) {
            Some(r) => stuck(r),
            None => next(push(drop(s, 1), fields(s, at(s, 0))[f]), len),
        }
    }
}

/// LOAD_FIELD_LOCAL enc / POP_LOAD_FIELD_LOCAL enc: local = enc & 15,
/// field = enc >> 4.
pub open spec fn op_load_field_local(s: State, enc: int, pop: bool) -> Outcome {
    let local = enc % 16;
    let f = enc / 16;
    let slot = if pop { local + 1 } else { local };
    if !has_slot(s, slot) || (pop && !has_slot(s, 0)) {
        stuck(Stuck::StackRange)
    } else {
        match field_ok(s, at(s, slot), f) {
            Some(r) => stuck(r),
            None => {
                let v = fields(s, at(s, slot))[f];
                if pop { next(put(s, 0, v), 2) } else { next(push(s, v), 2) }
            },
        }
    }
}

/// STORE_FIELD f (keep value) / STORE_FIELD_POP f.
pub open spec fn op_store_field(s: State, f: int, len: int, keep: bool) -> Outcome {
    if !has_slot(s, 1) {
        stuck(Stuck::StackRange)
    } else {
        let v = at(s, 0);
        let inst = at(s, 1);
        match field_ok(s, inst, f) {
            Some(r) => stuck(r),
            None => {
                if obj(s, inst).ro {
                    stuck(Stuck::ReadOnly)
                } else if !is_value(v) {
                    stuck(Stuck::FrameWord)
                } else {
                    let s1 = set_field(drop(s, 2), inst, f, v);
                    if keep { next(push(s1, v), len) } else { next(s1, len) }
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Constants.

pub open spec fn op_load_literal(p: Program, s: State, i: int, len: int) -> Outcome {
    if !(0 <= i < p.literals.len()) {
        stuck(Stuck::TableRange)
    } else {
        next(push(s, p.literals[i]), len)
    }
}

/// LOAD_SMI_*, LOAD_METHOD: `Smi::from(v)` (wraps like the C++ VM).
pub open spec fn op_load_smi(p: Program, s: State, v: int, len: int) -> Outcome {
    next(push(s, smi(smi_wrap(p, v))), len)
}

pub open spec fn op_load_smis_0(s: State, n: int) -> Outcome {
    next(State { stack: s.stack + Seq::new(n as nat, |i: int| Value::Smi(0)), ..s }, 2)
}

// ---------------------------------------------------------------------------
// Globals.

pub open spec fn op_load_global(s: State, g: int, len: int) -> Outcome {
    if !(0 <= g < s.globals.len()) {
        stuck(Stuck::TableRange)
    } else {
        next(push(s, s.globals[g]), len)
    }
}

/// LOAD_GLOBAL_VAR_LAZY: a LazyInitializer_ instance in the global means
/// "call run_global_initializer(g, initializer)".
pub open spec fn op_load_global_lazy(p: Program, s: State, g: int, len: int) -> Outcome {
    if !(0 <= g < s.globals.len()) {
        stuck(Stuck::TableRange)
    } else {
        let v = s.globals[g];
        if is_instance(s, v) && class_of_obj(s, v) == builtin(p, LAZY_INITIALIZER_CLASS) {
            call_entry(p, push(push(s, smi(g)), v), RUN_GLOBAL_INITIALIZER, len)
        } else {
            next(push(s, v), len)
        }
    }
}

pub open spec fn op_load_global_dynamic(p: Program, s: State) -> Outcome {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else {
        match at(s, 0) {
            Value::Smi(gi) => {
                let s1 = drop(s, 1);
                let g = trunc32(gi as int);
                if !(0 <= g < s.globals.len()) {
                    call_entry(p, push(s1, smi(s.bci as int)), PROGRAM_FAILURE, 1)
                } else {
                    next(push(s1, s.globals[g]), 1)
                }
            },
            _ => stuck(Stuck::NotSmi),
        }
    }
}

pub open spec fn op_store_global(s: State, g: int, len: int) -> Outcome {
    if !(0 <= g < s.globals.len()) {
        stuck(Stuck::TableRange)
    } else if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else if !is_value(at(s, 0)) {
        stuck(Stuck::FrameWord)
    } else {
        next(State { globals: s.globals.update(g, at(s, 0)), ..s }, len)
    }
}

pub open spec fn op_store_global_dynamic(p: Program, s: State) -> Outcome {
    if !has_slot(s, 1) {
        stuck(Stuck::StackRange)
    } else {
        let v = at(s, 0);
        match at(s, 1) {
            Value::Smi(gi) => {
                let s1 = drop(s, 2);
                let g = trunc32(gi as int);
                if !(0 <= g < s.globals.len()) {
                    call_entry(p, push(s1, smi(s.bci as int)), PROGRAM_FAILURE, 1)
                } else if !is_value(v) {
                    stuck(Stuck::FrameWord)
                } else {
                    next(State { globals: s1.globals.update(g, v), ..s1 }, 1)
                }
            },
            _ => stuck(Stuck::NotSmi),
        }
    }
}

// ---------------------------------------------------------------------------
// Blocks.

/// LOAD_BLOCK k: push a reference to stack slot `sp + k`.
pub open spec fn op_load_block(s: State, k: int) -> Outcome {
    if !has_slot(s, k) {
        stuck(Stuck::StackRange)
    } else {
        next(push(s, Value::Block((height(s) - k) as usize)), 2)
    }
}

/// LOAD_OUTER_BLOCK k: pop block reference b, push reference to
/// `block_ptr + k`.
pub open spec fn op_load_outer_block(s: State, k: int) -> Outcome {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else {
        match at(s, 0) {
            Value::Block(h) => {
                if (h as int) - k < 1 || h as int > height(s) - 1 {
                    stuck(Stuck::StackRange)
                } else {
                    next(push(drop(s, 1), Value::Block((h as int - k) as usize)), 2)
                }
            },
            _ => stuck(Stuck::NotBlock),
        }
    }
}

// ---------------------------------------------------------------------------
// Pop, allocate.

pub open spec fn op_pop(s: State, n: int, len: int) -> Outcome {
    if !(0 <= n <= height(s)) {
        stuck(Stuck::StackRange)
    } else {
        next(drop(s, n), len)
    }
}

pub open spec fn op_allocate(p: Program, s: State, c: int, len: int) -> Outcome {
    if !(0 <= c < p.class_bits.len()) {
        stuck(Stuck::TableRange)
    } else if class_tag(p, c) != INSTANCE_TAG || instance_field_count(p, c) < 0 {
        stuck(Stuck::NotInstantiable)
    } else {
        let o = HeapObj {
            class_id: c as u16,
            ro: false,
            body: Body::Instance(Seq::new(instance_field_count(p, c) as nat, |i: int| null_v(p))),
        };
        next(push(alloc(s, o), new_ref(s)), len)
    }
}

// ---------------------------------------------------------------------------
// Type checks.

pub open spec fn op_is(p: Program, s: State, enc: int, interface: bool, len: int) -> Outcome {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else {
        let v = at(s, 0);
        let c = if interface {
            typecheck_interface(p, s, v, enc / 2, enc % 2 == 1)
        } else {
            typecheck_class(p, s, v, enc / 2, enc % 2 == 1)
        };
        match c {
            Check::Stuck(r) => stuck(r),
            Check::Yes => next(put(s, 0, true_v(p)), len),
            Check::No => next(put(s, 0, false_v(p)), len),
        }
    }
}

pub open spec fn op_as(p: Program, s: State, enc: int, interface: bool, len: int) -> Outcome {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else {
        let v = at(s, 0);
        let c = if interface {
            typecheck_interface(p, s, v, enc / 2, enc % 2 == 1)
        } else {
            typecheck_class(p, s, v, enc / 2, enc % 2 == 1)
        };
        match c {
            Check::Stuck(r) => stuck(r),
            Check::Yes => next(s, len),
            Check::No => call_entry(p, push(s, smi(s.bci + len)), AS_CHECK_FAILURE, len),
        }
    }
}

/// AS_LOCAL enc: local = enc >> 5, class check index = enc & 31.
pub open spec fn op_as_local(p: Program, s: State, enc: int) -> Outcome {
    let local = enc / 32;
    if !has_slot(s, local) {
        stuck(Stuck::StackRange)
    } else {
        let v = at(s, local);
        match typecheck_class(p, s, v, enc % 32, false) {
            Check::Stuck(r) => stuck(r),
            Check::Yes => next(s, 2),
            Check::No => {
                if !is_value(v) {
                    stuck(Stuck::FrameWord)
                } else {
                    call_entry(p, push(push(s, v), smi(s.bci + 2)), AS_CHECK_FAILURE, 2)
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Calls.

pub open spec fn dispatch_target(p: Program, d: int) -> int {
    if 0 <= d < p.dispatch.len() { p.dispatch[d] as int } else { -1 }
}

pub open spec fn op_invoke_static(p: Program, s: State, d: int) -> Outcome {
    call(p, s, dispatch_target(p, d), 3)
}

/// Shared by INVOKE_STATIC_TAIL and INVOKE_INITIALIZER_TAIL: the frame of
/// the current method (height `h` expression slots, then frame marker and
/// return address, then `a` parameters) is replaced by the top
/// `call_arity` words, and `target` is called with the current method's
/// return address.
pub open spec fn tail_call(p: Program, s: State, target: int, h: int, a: int) -> Outcome {
    if !valid_method(p, target) {
        stuck(Stuck::NotMethod)
    } else {
        let call_arity = method_arity(p, target);
        if !has_slot(s, h + 1) || height(s) < h + FRAME_SIZE + a {
            stuck(Stuck::StackRange)
        } else if at(s, h) != Value::FrameMarker || !(at(s, h + 1) is RetAddr) {
            stuck(Stuck::BadFrame)
        } else if call_arity > h {
            stuck(Stuck::FrameWord)
        } else {
            let ret = match at(s, h + 1) { Value::RetAddr(r) => r as int, _ => 0 };
            let base = s.stack.subrange(0, height(s) - (h + FRAME_SIZE + a));
            let args = s.stack.subrange(height(s) - call_arity, height(s));
            call_with(p, State { stack: base + args, ..s }, target, ret)
        }
    }
}

pub open spec fn op_invoke_static_tail(p: Program, s: State, d: int, h: int, a: int) -> Outcome {
    tail_call(p, s, dispatch_target(p, d), h, a)
}

/// INVOKE_BLOCK n: the block reference is the receiver, at STACK_AT(n - 1).
pub open spec fn op_invoke_block(p: Program, s: State, n: int) -> Outcome {
    if n < 1 || !has_slot(s, n - 1) {
        stuck(Stuck::StackRange)
    } else {
        let b = at(s, n - 1);
        if !(b is Block) {
            stuck(Stuck::NotBlock)
        } else if !block_ok(p, s, b) {
            stuck(Stuck::NotMethod)
        } else {
            let target = block_method(p, s, b);
            let extra = n - method_arity(p, target);
            if extra < 0 {
                let s1 = push(push(push(push(s, true_v(p)), smi(method_arity(p, target))), smi(n)),
                    smi(method_entry(target)));
                call_entry(p, s1, CODE_FAILURE, 2)
            } else {
                call(p, drop(s, extra), target, 2)
            }
        }
    }
}

/// INVOKE_LAMBDA_TAIL k: in the body of `Lambda.call`, with an empty
/// expression stack, the receiver lambda below `k` arguments.
pub open spec fn op_invoke_lambda_tail(p: Program, s: State, k: int) -> Outcome {
    if !has_slot(s, k + 2) {
        stuck(Stuck::StackRange)
    } else {
        let recv = at(s, k + 2);
        if !is_instance(s, recv) {
            stuck(Stuck::NotInstance)
        } else if fields(s, recv).len() < 2 {
            stuck(Stuck::FieldRange)
        } else {
            let mid = fields(s, recv)[0];
            let argument = fields(s, recv)[1];
            if !(mid is Smi) || !valid_method(p, smi_val(mid)) {
                stuck(Stuck::NotMethod)
            } else {
                let target = smi_val(mid);
                let captured = if is_array(s, argument) { elements(s, argument) } else { seq![argument] };
                let user_arity = method_arity(p, target) - captured.len();
                if user_arity < 0 {
                    // The C++ VM would drop words of the caller's frame.
                    stuck(Stuck::StackRange)
                } else if k < user_arity {
                    let s1 = push(push(push(push(s, false_v(p)), smi(user_arity)), smi(k)),
                        smi(method_entry(target)));
                    call_entry(p, s1, CODE_FAILURE, 2)
                } else if at(s, 0) != Value::FrameMarker || !(at(s, 1) is RetAddr) {
                    stuck(Stuck::BadFrame)
                } else {
                    let ret = match at(s, 1) { Value::RetAddr(r) => r as int, _ => 0 };
                    let n = height(s) - 2;  // After popping the frame.
                    let base = s.stack.subrange(0, n - (k + 1));
                    let args = s.stack.subrange(n - k, n - k + user_arity);
                    call_with(p, State { stack: base + args + captured, ..s }, target, ret)
                }
            }
        }
    }
}

pub open spec fn op_invoke_initializer_tail(p: Program, s: State, h: int, a: int) -> Outcome {
    if !has_slot(s, 0) || h < 1 {
        stuck(Stuck::StackRange)
    } else {
        match at(s, 0) {
            Value::Smi(m) => {
                let s1 = drop(s, 1);
                let target = m as int;
                if !valid_method(p, target) {
                    stuck(Stuck::NotMethod)
                } else if method_arity(p, target) != 0 {
                    call_entry(p, push(s1, smi(s.bci as int)), PROGRAM_FAILURE, 3)
                } else {
                    tail_call(p, s1, target, h - 1, a)
                }
            },
            _ => stuck(Stuck::NotSmi),
        }
    }
}

pub open spec fn op_invoke_virtual(p: Program, s: State, k: int, sel: int, len: int) -> Outcome {
    if !has_slot(s, k) {
        stuck(Stuck::StackRange)
    } else {
        invoke_virtual(p, s, at(s, k), sel, len)
    }
}

/// INVOKE_VIRTUAL_GET sel (also INVOKE_SIZE's fallback). Field accessors are
/// executed inline by decoding the accessor's bytecodes.
pub open spec fn op_invoke_virtual_get(p: Program, s: State, sel: int) -> Outcome {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else {
        let recv = at(s, 0);
        match find_method(p, s, recv, sel) {
            Lookup::Stuck(r) => stuck(r),
            Lookup::Missing => call_entry(p, push(push(s, recv), smi(sel)), LOOKUP_FAILURE, 3),
            Lookup::Found(t) => {
                if method_kind(p, t) == KIND_FIELD_ACCESSOR {
                    let e = method_entry(t);
                    if e + 4 > p.bytecodes.len() {
                        stuck(Stuck::BadInstruction)
                    } else {
                        let f = if p.bytecodes[e] == LOAD_FIELD_LOCAL { byte(p, e + 1) / 16 } else { byte(p, e + 2) };
                        match field_ok(s, recv, f) {
                            Some(r) => stuck(r),
                            None => next(put(s, 0, fields(s, recv)[f]), 3),
                        }
                    }
                } else {
                    call(p, s, t, 3)
                }
            },
        }
    }
}

pub open spec fn op_invoke_virtual_set(p: Program, s: State, sel: int) -> Outcome {
    if !has_slot(s, 1) {
        stuck(Stuck::StackRange)
    } else {
        let recv = at(s, 1);
        match find_method(p, s, recv, sel) {
            Lookup::Stuck(r) => stuck(r),
            Lookup::Missing => call_entry(p, push(push(s, recv), smi(sel)), LOOKUP_FAILURE, 3),
            Lookup::Found(t) => {
                if method_kind(p, t) == KIND_FIELD_ACCESSOR {
                    let e = method_entry(t);
                    if e + 5 > p.bytecodes.len() {
                        stuck(Stuck::BadInstruction)
                    } else {
                        let f = byte(p, e + 3);
                        let v = at(s, 0);
                        match field_ok(s, recv, f) {
                            Some(r) => stuck(r),
                            None => {
                                if obj(s, recv).ro {
                                    stuck(Stuck::ReadOnly)
                                } else if !is_value(v) {
                                    stuck(Stuck::FrameWord)
                                } else {
                                    next(drop(put(set_field(s, recv, f, v), 1, v), 1), 3)
                                }
                            },
                        }
                    }
                } else {
                    call(p, s, t, 3)
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Operators. Each has a fast path; otherwise the receiver is pushed again
// and the operator's selector is invoked virtually.

/// Replace the two operands by `r` and continue.
pub open spec fn binary_result(s: State, r: Value) -> Outcome {
    next(drop(put(s, 1, r), 1), 1)
}

pub open spec fn fallback(p: Program, s: State, op: u8) -> Outcome {
    virtual_fallback(p, push(s, at(s, 1)), op)
}

pub open spec fn op_invoke_eq(p: Program, s: State) -> Outcome {
    let a0 = at(s, 1);
    let a1 = at(s, 0);
    if a0 == a1 {
        binary_result(s, boolean(p, !(is_double(s, a0) && is_nan_bits(double_bits(s, a0)))))
    } else if a0 == null_v(p) || a1 == null_v(p) {
        binary_result(s, false_v(p))
    } else if are_smis(a0, a1) {
        binary_result(s, boolean(p, smi_val(a0) == smi_val(a1)))
    } else if compare_numbers(s, a0, a1) != 0 {
        binary_result(s, boolean(p, (compare_numbers(s, a0, a1) & COMPARE_FLAG_EQUAL) != 0))
    } else {
        fallback(p, s, INVOKE_EQ)
    }
}

pub open spec fn relational_flag(op: u8) -> u8 {
    if op == INVOKE_LT { COMPARE_FLAG_STRICTLY_LESS }
    else if op == INVOKE_LTE { COMPARE_FLAG_LESS_EQUAL }
    else if op == INVOKE_GT { COMPARE_FLAG_STRICTLY_GREATER }
    else { COMPARE_FLAG_GREATER_EQUAL }
}

pub open spec fn relational_smi(op: u8, a: int, b: int) -> bool {
    if op == INVOKE_LT { a < b }
    else if op == INVOKE_LTE { a <= b }
    else if op == INVOKE_GT { a > b }
    else { a >= b }
}

pub open spec fn op_invoke_relational(p: Program, s: State, op: u8) -> Outcome {
    let a0 = at(s, 1);
    let a1 = at(s, 0);
    if are_smis(a0, a1) {
        binary_result(s, boolean(p, relational_smi(op, smi_val(a0), smi_val(a1))))
    } else if compare_numbers(s, a0, a1) != 0 {
        binary_result(s, boolean(p, (compare_numbers(s, a0, a1) & relational_flag(op)) != 0))
    } else {
        fallback(p, s, op)
    }
}

/// Smi fast path of the arithmetic operators: `Some(result)` if it applies.
pub open spec fn smi_arith(p: Program, op: u8, a: int, b: int) -> Option<int> {
    if op == INVOKE_BIT_OR { Some(((a as i64) | (b as i64)) as int) }
    else if op == INVOKE_BIT_XOR { Some(((a as i64) ^ (b as i64)) as int) }
    else if op == INVOKE_BIT_AND { Some(((a as i64) & (b as i64)) as int) }
    else if op == INVOKE_ADD { if smi_ok(p, a + b) { Some(a + b) } else { None } }
    else if op == INVOKE_SUB { if smi_ok(p, a - b) { Some(a - b) } else { None } }
    else if op == INVOKE_MUL { if smi_ok(p, a * b) { Some(a * b) } else { None } }
    // MIN_SMI / -1 is not a smi; the VM leaves it to the slow path.
    else if op == INVOKE_DIV { if b != 0 && smi_ok(p, tdiv(a, b)) { Some(tdiv(a, b)) } else { None } }
    else if op == INVOKE_MOD { if b != 0 { Some(trem(a, b)) } else { None } }
    else if op == INVOKE_BIT_SHL {
        if 0 <= b < word_bit_size(p) && smi_ok(p, a * vstd::arithmetic::power2::pow2(b as nat)) {
            Some(a * vstd::arithmetic::power2::pow2(b as nat))
        } else { None }
    }
    // Smi::from(value >> bits): arithmetic shift of the (sign-extended)
    // value, as on the C++ `word`.
    else if op == INVOKE_BIT_SHR {
        if 0 <= b < word_bit_size(p) { Some(((a as i64) >> (b as u64)) as int) } else { None }
    }
    else {  // INVOKE_BIT_USHR
        if 0 <= b < word_bit_size(p) && a >= 0 { Some(((a as i64) >> (b as u64)) as int) } else { None }
    }
}

pub open spec fn float_arith(op: u8, a: u64, b: u64) -> u64 {
    if op == INVOKE_ADD { double_add(a, b) }
    else if op == INVOKE_SUB { double_sub(a, b) }
    else { double_mul(a, b) }
}

pub open spec fn op_invoke_arith(p: Program, s: State, op: u8) -> Outcome {
    let a0 = at(s, 1);
    let a1 = at(s, 0);
    if are_smis(a0, a1) && smi_arith(p, op, smi_val(a0), smi_val(a1)) is Some {
        binary_result(s, smi(smi_arith(p, op, smi_val(a0), smi_val(a1))->0))
    } else if (op == INVOKE_ADD || op == INVOKE_SUB || op == INVOKE_MUL) && are_floats(s, a0, a1) {
        let bits = float_arith(op, double_bits(s, a0), double_bits(s, a1));
        binary_result(alloc(s, new_double(s, p, bits)), new_ref(s))
    } else {
        fallback(p, s, op)
    }
}

pub open spec fn op_invoke_at(p: Program, s: State) -> Outcome {
    match fast_at(p, s, at(s, 1), at(s, 0), false, null_v(p), FAST_AT_FUEL) {
        FastAt::Get(v) => binary_result(s, v),
        FastAt::Stuck(r) => stuck(r),
        _ => fallback(p, s, INVOKE_AT),
    }
}

pub open spec fn op_invoke_at_put(p: Program, s: State) -> Outcome {
    if !has_slot(s, 2) {
        stuck(Stuck::StackRange)
    } else if !is_value(at(s, 0)) {
        stuck(Stuck::FrameWord)
    } else {
        match fast_at(p, s, at(s, 2), at(s, 1), true, at(s, 0), FAST_AT_FUEL) {
            FastAt::Put(s1, v) => next(drop(put(s1, 2, v), 2), 1),
            FastAt::Stuck(r) => stuck(r),
            _ => virtual_fallback(p, push(s, at(s, 2)), INVOKE_AT_PUT),
        }
    }
}

pub open spec fn op_invoke_size(p: Program, s: State, sel: int) -> Outcome {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else if !fast_size_fields_ok(p, s, at(s, 0)) {
        stuck(Stuck::FieldRange)
    } else {
        match fast_size(p, s, at(s, 0)) {
            Some(n) => next(put(s, 0, smi(n)), 3),
            None => op_invoke_virtual_get(p, s, sel),
        }
    }
}

// ---------------------------------------------------------------------------
// Branches. BRANCH_BACK's second operand (distance to the method entry) is
// only used for preemption bookkeeping, which is not modeled.

pub open spec fn branch_to(p: Program, s: State, target: int) -> Outcome {
    if !(0 <= target < p.bytecodes.len()) {
        stuck(Stuck::BadBranch)
    } else {
        Outcome::Next(goto(s, target))
    }
}

/// kind: 0 = always, 1 = if true, 2 = if false, 3 = if not null.
pub open spec fn branch_taken(p: Program, kind: int, v: Value) -> bool {
    if kind == 1 { truthy(p, v) }
    else if kind == 2 { !truthy(p, v) }
    else { v != null_v(p) }
}

pub open spec fn op_branch(p: Program, s: State, kind: int, target: int, len: int) -> Outcome {
    if kind == 0 {
        branch_to(p, s, target)
    } else if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else if branch_taken(p, kind, at(s, 0)) {
        branch_to(p, drop(s, 1), target)
    } else {
        next(drop(s, 1), len)
    }
}

// ---------------------------------------------------------------------------
// Returns and unwinding.

/// Pops the frame marker and return address from `s` and continues at the
/// return address after dropping `arity` arguments and pushing `result`.
pub open spec fn return_to_caller(s: State, arity: int, result: Value) -> Outcome {
    if !has_slot(s, 1) {
        stuck(Stuck::StackRange)
    } else if at(s, 0) != Value::FrameMarker || !(at(s, 1) is RetAddr) {
        stuck(Stuck::BadFrame)
    } else if height(s) < 2 + arity {
        stuck(Stuck::StackRange)
    } else {
        let ret = match at(s, 1) { Value::RetAddr(r) => r as int, _ => 0 };
        Outcome::Next(goto(push(drop(s, 2 + arity), result), ret))
    }
}

pub open spec fn op_return(p: Program, s: State, h: int, a: int, null_result: bool) -> Outcome {
    if !has_slot(s, 0) && !null_result {
        stuck(Stuck::StackRange)
    } else if !null_result && !is_value(at(s, 0)) {
        stuck(Stuck::FrameWord)
    } else if height(s) < h {
        stuck(Stuck::StackRange)
    } else {
        let result = if null_result { null_v(p) } else { at(s, 0) };
        return_to_caller(drop(s, h), a, result)
    }
}

/// UNWIND_IMPLEMENTATION. The top three words describe the unwinding:
/// reason (TOS), target, result.
pub open spec fn unwind(p: Program, s: State) -> Outcome {
    if !has_slot(s, 2) {
        stuck(Stuck::StackRange)
    } else {
        match at(s, 0) {
            Value::Smi(tos) => {
                let tv = trunc32(tos as int);
                if tv == -1 {
                    // Leaving the try/finally normally.
                    next(drop(s, 3), 1)
                } else {
                    match at(s, 1) {
                        Value::Block(target) => {
                            let t = target as int;
                            let result = at(s, 2);
                            let s1 = drop(s, 3);
                            let th = s.try_h as int;
                            if t < th {
                                // Hit an unwind-protect: record the reason in the
                                // link and return from the try-block call into the
                                // finally code.
                                if th < 4 || height(s1) < th + 3 {
                                    stuck(Stuck::StackRange)
                                } else {
                                    let st = s1.stack.subrange(0, th + 3)
                                        .update(th - 2, at(s, 0))
                                        .update(th - 3, Value::Block(target))
                                        .update(th - 4, result);
                                    let s2 = State { stack: st, ..s1 };
                                    if at(s2, 0) != Value::FrameMarker || !(at(s2, 1) is RetAddr) {
                                        stuck(Stuck::BadFrame)
                                    } else {
                                        let ret = match at(s2, 1) { Value::RetAddr(r) => r as int, _ => 0 };
                                        Outcome::Next(goto(drop(s2, 2), ret))
                                    }
                                }
                            } else if t > height(s1) {
                                stuck(Stuck::StackRange)
                            } else if tv == -2 || tv % 2 == 0 {
                                // Exception or non-local return.
                                let arity = if tv == -2 { 0 } else { tv / 2 };
                                let s2 = State { stack: s1.stack.subrange(0, t), ..s1 };
                                if has_slot(s2, 0) && at(s2, 0) != Value::FrameMarker {
                                    // "Threw exception before entering last-chance
                                    // catch clause".
                                    stuck(Stuck::Fatal)
                                } else {
                                    return_to_caller(s2, arity, result)
                                }
                            } else {
                                // Non-local branch.
                                match result {
                                    Value::Smi(hd) => {
                                        let s2 = State { stack: s1.stack.subrange(0, t), ..s1 };
                                        let target_bci = tv / 2;
                                        if !(0 <= hd as int <= t) {
                                            stuck(Stuck::StackRange)
                                        } else if !(0 <= target_bci < p.bytecodes.len()) {
                                            stuck(Stuck::BadBranch)
                                        } else {
                                            Outcome::Next(goto(drop(s2, hd as int), target_bci))
                                        }
                                    },
                                    _ => stuck(Stuck::NotSmi),
                                }
                            }
                        },
                        _ => stuck(Stuck::NotBlock),
                    }
                }
            },
            _ => stuck(Stuck::NotSmi),
        }
    }
}

/// THROW: unwind to the base of the stack with reason -2.
pub open spec fn op_throw(p: Program, s: State) -> Outcome {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else {
        unwind(p, push(push(s, Value::Block(0)), smi(-2)))
    }
}

/// NON_LOCAL_RETURN: return `result` from the frame `height + 1` slots
/// below the block's home slot, dropping `arity` arguments.
pub open spec fn op_non_local_return(p: Program, s: State, arity: int, h: int) -> Outcome {
    if !has_slot(s, 1) {
        stuck(Stuck::StackRange)
    } else {
        match at(s, 0) {
            Value::Block(b) => {
                let result = at(s, 1);
                let t = b as int - h - 1;
                if t < 0 {
                    stuck(Stuck::StackRange)
                } else if !smi_ok(p, arity * 2) {
                    stuck(Stuck::SmiRange)
                } else {
                    unwind(p, push(push(push(drop(s, 2), result), Value::Block(t as usize)), smi(arity * 2)))
                }
            },
            _ => stuck(Stuck::NotBlock),
        }
    }
}

pub open spec fn op_non_local_branch(p: Program, s: State, hd: int, abs_bci: int) -> Outcome {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else {
        match at(s, 0) {
            Value::Block(b) => {
                if !smi_ok(p, abs_bci * 2 + 1) {
                    stuck(Stuck::SmiRange)
                } else {
                    unwind(p, push(push(push(drop(s, 1), smi(hd)), Value::Block(b)), smi(abs_bci * 2 + 1)))
                }
            },
            _ => stuck(Stuck::NotBlock),
        }
    }
}

/// LINK: push result, target, reason, chain; `try_sp_ = sp`.
pub open spec fn op_link(s: State) -> Outcome {
    let s1 = push(push(push(push(s, smi(0xbeef)), smi(-0xdead)), smi(-1)), Value::Link(s.try_h));
    next(State { try_h: (height(s) + 4) as usize, ..s1 }, 2)
}

pub open spec fn op_unlink(s: State) -> Outcome {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else {
        match at(s, 0) {
            Value::Link(h) => next(State { try_h: h, ..drop(s, 1) }, 2),
            _ => stuck(Stuck::NotLink),
        }
    }
}

pub open spec fn op_halt(s: State, code: int) -> Outcome {
    if code == 0 {
        Outcome::Halt(goto(push(s, smi(91)), s.bci + 2), HaltKind::Yield)
    } else if code == 1 {
        if !has_slot(s, 0) {
            stuck(Stuck::StackRange)
        } else {
            match at(s, 0) {
                Value::Smi(v) => Outcome::Halt(goto(drop(s, 1), s.bci + 2), HaltKind::Exit(v)),
                _ => stuck(Stuck::NotSmi),
            }
        }
    } else if code == 2 {
        if !has_slot(s, 0) {
            stuck(Stuck::StackRange)
        } else {
            // Non-numeric durations are FATAL in the C++ VM.
            Outcome::Halt(goto(drop(s, 1), s.bci + 2), HaltKind::DeepSleep)
        }
    } else {
        Outcome::Halt(goto(s, s.bci + 2), HaltKind::Reset)
    }
}

// ---------------------------------------------------------------------------
// Intrinsics. They run as the body of a method with a fixed frame shape
// and re-execute themselves after each block call (return address = the
// intrinsic's own bci).

pub open spec fn op_smi_repeat(p: Program, s0: State) -> Outcome {
    if !has_slot(s0, 5) {
        stuck(Stuck::StackRange)
    } else {
        let s = drop(s0, 1);  // Last block result.
        let block = at(s, 3);
        match (at(s, 0), at(s, 4)) {
            (Value::Smi(current), Value::Smi(end)) => {
                if !block_ok(p, s, block) {
                    stuck(Stuck::NotBlock)
                } else {
                    let target = block_method(p, s, block);
                    if method_arity(p, target) > 2 {
                        next(s, 1)
                    } else if current >= end {
                        // Return null from the surrounding method (drops `this`).
                        // Return null from `repeat` (this, block).
                        return_to_caller(drop(s, 1), 2, null_v(p))
                    } else {
                        let s1 = push(put(s, 0, smi(current + 1)), block);
                        let s2 = if method_arity(p, target) == 2 { push(s1, smi(current as int)) } else { s1 };
                        call_with(p, s2, target, s0.bci as int)
                    }
                }
            },
            _ => stuck(Stuck::NotSmi),
        }
    }
}

pub open spec fn op_array_do(p: Program, s0: State) -> Outcome {
    if !has_slot(s0, 6) {
        stuck(Stuck::StackRange)
    } else {
        let s = drop(s0, 1);
        let block = at(s, 3);
        let backing = at(s, 5);
        match (at(s, 0), at(s, 4)) {
            (Value::Smi(current), Value::Smi(end)) => {
                if !is_array(s, backing) {
                    stuck(Stuck::NotArray)
                } else if !block_ok(p, s, block) {
                    stuck(Stuck::NotBlock)
                } else {
                    let target = block_method(p, s, block);
                    if method_arity(p, target) > 2 {
                        next(s, 1)
                    } else if current >= end {
                        // Return null from `do` (backing, end, block).
                        return_to_caller(drop(s, 1), 3, null_v(p))
                    } else {
                        let s1 = push(put(s, 0, smi(current + 1)), block);
                        if method_arity(p, target) == 2 {
                            if !(0 <= current < elements(s, backing).len()) {
                                stuck(Stuck::FieldRange)
                            } else {
                                call_with(p, push(s1, elements(s, backing)[current as int]), target, s0.bci as int)
                            }
                        } else {
                            call_with(p, s1, target, s0.bci as int)
                        }
                    }
                }
            },
            _ => stuck(Stuck::NotSmi),
        }
    }
}

/// INTRINSIC_HASH_DO. Locals: [state]; parameters: block, reversed, step,
/// collection.
pub open spec fn op_hash_do(p: Program, s0: State) -> Outcome {
    if !has_slot(s0, 7) {
        stuck(Stuck::StackRange)
    } else {
        let s = drop(s0, 1);
        let collection = at(s, 6);
        let block = at(s, 3);
        if !is_instance(s, collection) {
            stuck(Stuck::NotInstance)
        } else if fields(s, collection).len() < 4 {
            stuck(Stuck::FieldRange)
        } else {
            match at(s, 5) {
                Value::Smi(st) => {
                    let backing = fields(s, collection)[3];
                    let step0 = trunc32(st as int);
                    let step = if at(s, 4) == true_v(p) { -step0 } else { step0 };
                    match hash_do(p, s, at(s, 0), backing, step, block) {
                        HashDo::Stuck(r) => stuck(r),
                        HashDo::Call(s1, c, entry) => {
                            let s1p = put(s1, 0, smi(c));
                            if !block_ok(p, s1p, block) {
                                stuck(Stuck::NotBlock)
                            } else {
                                let target = block_method(p, s1p, block);
                                let s2 = push(push(s1p, block), entry);
                                if method_arity(p, target) > 2 {
                                    let v = match fast_at(p, s2, backing, smi(c + 1), false, null_v(p), FAST_AT_FUEL) {
                                        FastAt::Get(v) => v,
                                        _ => null_v(p),
                                    };
                                    call_with(p, push(s2, v), target, s0.bci as int)
                                } else {
                                    call_with(p, s2, target, s0.bci as int)
                                }
                            }
                        },
                        HashDo::Return(s1, v) => return_to_caller(drop(s1, 1), 4, v),
                    }
                },
                _ => stuck(Stuck::NotSmi),
            }
        }
    }
}

// INTRINSIC_HASH_FIND. Stack after popping the block result:
//   0 state, 1 old_size, 2 deleted_slot, 3 slot, 4 position, 5 slot_step,
//   6 starting_slot, 7 frame marker, 8 return address,
//   9 compare, 10 rebuild, 11 not_found, 12 append_position, 13 hash,
//   14 key, 15 collection.

pub open spec fn hf_bail(s: State, bci: int) -> Outcome {
    Outcome::Next(goto(drop(s, 6), bci + 1))
}

/// Return `result` from `find-body_` (7 arguments).
pub open spec fn hf_return(s: State, result: Value) -> Outcome {
    return_to_caller(drop(s, 7), 7, result)
}

pub open spec fn index_get(p: Program, s: State, index: Value, slot: int) -> Option<int> {
    if is_array(s, index) {
        if 0 <= slot < elements(s, index).len() && elements(s, index)[slot] is Smi {
            Some(smi_val(elements(s, index)[slot]))
        } else {
            None
        }
    } else {
        match fast_at(p, s, index, smi(slot), false, null_v(p), FAST_AT_FUEL) {
            FastAt::Get(Value::Smi(v)) => Some(v as int),
            _ => None,
        }
    }
}

pub open spec fn hash_find_loop(
    p: Program, s: State, bci: int, index: Value, mask: int, hash: int,
    slot: int, step: int, starting: int, inc: bool, fuel: nat,
) -> Outcome
    decreases fuel,
{
    if fuel == 0 {
        stuck(Stuck::OutOfFuel)
    } else {
        let coll = at(s, 15);
        let cf = fields(s, coll);
        let slot2 = if inc { band(slot + step, mask) } else { slot };
        let step2 = if inc { step + 1 } else { step };
        let exhausted = inc && slot2 == starting;
        match index_get(p, s, index, slot2) {
            None => stuck(Stuck::NotSmi),
            Some(hap) => {
                if hap == 0 || exhausted {
                    if !(cf[1] is Smi) {
                        stuck(Stuck::NotSmi)
                    } else {
                        let s1 = if smi_val(cf[1]) == 0 || exhausted {
                            put(put(s, 1, cf[0]), 0, smi(2))
                        } else {
                            put(put(s, 3, smi(slot2)), 0, smi(1))
                        };
                        let ap = at(s1, 12);
                        if !(ap is Smi) {
                            let nf = at(s1, 11);
                            if !block_ok(p, s1, nf) {
                                stuck(Stuck::NotBlock)
                            } else {
                                call_with(p, push(s1, nf), block_method(p, s1, nf), bci)
                            }
                        } else {
                            // Restart the bytecode as if not_found had returned ap.
                            Outcome::Next(goto(push(s1, ap), bci))
                        }
                    }
                } else {
                    let position = hap / 4096 - 1;
                    let backing = cf[3];
                    if !(backing is Obj) {
                        stuck(Stuck::NotObject)
                    } else {
                        match fast_at(p, s, backing, smi(position), false, null_v(p), FAST_AT_FUEL) {
                            FastAt::Get(k) => {
                                if !class_id_ok(s, k) || !(at(s, 2) is Smi) {
                                    stuck(Stuck::NotObject)
                                } else {
                                    let is_tombstone = k is Obj && class_of_obj(s, k) == builtin(p, TOMBSTONE_CLASS);
                                    let s1 = if smi_val(at(s, 2)) == -1 && is_tombstone { put(s, 2, smi(slot2)) } else { s };
                                    if band(hap, 0xfff) == band(hash, 0xfff) && !is_tombstone {
                                        let s2 = put(put(put(put(put(s1, 0, smi(3)), 3, smi(slot2)), 6, smi(starting)), 5, smi(step2)), 4, smi(position));
                                        let cb = at(s2, 9);
                                        if !block_ok(p, s2, cb) {
                                            stuck(Stuck::NotBlock)
                                        } else {
                                            let s3 = push(push(push(s2, cb), at(s2, 14)), k);
                                            call_with(p, s3, block_method(p, s2, cb), bci)
                                        }
                                    } else {
                                        hash_find_loop(p, s1, bci, index, mask, hash, slot2, step2, starting, true, (fuel - 1) as nat)
                                    }
                                }
                            },
                            FastAt::Stuck(r) => stuck(r),
                            _ => stuck(Stuck::FieldRange),
                        }
                    }
                }
            },
        }
    }
}

/// Stores `index_[idx] = new_hap` (the array case, or through fast_at for
/// a large-array index, whose failure the C++ VM only asserts against).
pub open spec fn hf_store(p: Program, s2: State, coll: Value, index: Value, idx: int, new_hap: int) -> Option<State> {
    if obj(s2, coll).ro {
        None
    } else if is_array(s2, index) {
        if !(0 <= idx < elements(s2, index).len()) || obj(s2, index).ro {
            None
        } else {
            let o = obj(s2, index);
            Some(set_obj(s2, obj_id(index),
                HeapObj { body: Body::Array(elements(s2, index).update(idx, smi(new_hap))), ..o }))
        }
    } else {
        match fast_at(p, s2, index, smi(idx), true, smi(new_hap), FAST_AT_FUEL) {
            FastAt::Put(s3, _) => Some(s3),
            FastAt::Stuck(_) => None,
            _ => Some(s2),
        }
    }
}

/// The NOT_FOUND state: enter the appended entry into the index. The slot
/// and the spaces-left field are only read when no deleted slot was found.
pub open spec fn hf_not_found(p: Program, s: State, block_result: Value, index: Value, mask: int, hash: int) -> Option<State> {
    let coll = at(s, 15);
    let s1 = put(s, 12, block_result);
    match (block_result, at(s1, 2)) {
        (Value::Smi(ap), Value::Smi(deleted)) => {
            let new_hap = (ap as int + 1) * 4096 + band(hash, 0xfff);
            if !smi_ok(p, new_hap) {
                None
            } else if deleted < 0 {
                match (at(s1, 3), fields(s1, coll)[1]) {
                    (Value::Smi(slot), Value::Smi(left)) => {
                        let s2 = set_field(s1, coll, 1, smi(smi_wrap(p, left - 1)));
                        hf_store(p, s2, coll, index, band(slot as int, mask), new_hap)
                    },
                    _ => None,
                }
            } else {
                hf_store(p, s1, coll, index, band(deleted as int, mask), new_hap)
            }
        },
        _ => None,
    }
}

pub open spec fn op_hash_find(p: Program, s0: State) -> Outcome {
    if !has_slot(s0, 16) {
        stuck(Stuck::StackRange)
    } else {
        let block_result = at(s0, 0);
        let s = drop(s0, 1);
        let bci = s0.bci as int;
        match at(s, 0) {
            Value::Smi(state) => {
                if state == 2 {
                    // REBUILD: call the rebuild block with old_size (read
                    // before the block is pushed).
                    let s1 = put(put(s, 12, block_result), 0, smi(0));
                    let rb = at(s1, 10);
                    if !block_ok(p, s1, rb) {
                        stuck(Stuck::NotBlock)
                    } else {
                        let s2 = push(s1, rb);
                        call_with(p, push(s2, at(s1, 1)), block_method(p, s1, rb), bci)
                    }
                } else {
                    let coll = at(s, 15);
                    let hash_obj = at(s, 13);
                    if !is_instance(s, coll) {
                        stuck(Stuck::NotInstance)
                    } else if fields(s, coll).len() < 4 {
                        stuck(Stuck::FieldRange)
                    } else {
                        let cf = fields(s, coll);
                        let nf = at(s, 11);
                        let rb = at(s, 10);
                        let cb = at(s, 9);
                        let checked = state == 0 || state == 3;
                        if checked && (!block_ok(p, s, nf) || !block_ok(p, s, rb) || !block_ok(p, s, cb)) {
                            stuck(Stuck::NotBlock)
                        } else if checked && (!(cf[1] is Smi) || !(hash_obj is Smi) || !(cf[0] is Smi)
                            || method_arity(p, block_method(p, s, nf)) != 1
                            || method_arity(p, block_method(p, s, rb)) != 2
                            || method_arity(p, block_method(p, s, cb)) != 3) {
                            hf_bail(s, bci)
                        } else {
                            let index = cf[2];
                            let mask_opt: Option<int> = if is_array(s, index) {
                                Some(elements(s, index).len() - 1)
                            } else if is_instance(s, index) && class_of_obj(s, index) == builtin(p, LARGE_ARRAY_CLASS)
                                && fields(s, index).len() >= 1 && fields(s, index)[0] is Smi
                                && smi_val(fields(s, index)[0]) - 1 < smi_max(p) / 4096 {
                                Some(smi_val(fields(s, index)[0]) - 1)
                            } else {
                                None
                            };
                            match mask_opt {
                                None => hf_bail(s, bci),
                                Some(mask) => {
                                    if !(hash_obj is Smi) {
                                        stuck(Stuck::NotSmi)
                                    } else {
                                        let hash = smi_val(hash_obj);
                                        let s1_opt = if state == 1 { hf_not_found(p, s, block_result, index, mask, hash) } else { Some(s) };
                                        match s1_opt {
                                            None => stuck(Stuck::NotSmi),
                                            Some(s1) => {
                                                if state == 1 {
                                                    hf_return(s1, smi(-1))
                                                } else if state == 3 && truthy(p, block_result) {
                                                    hf_return(s1, if at(s1, 12) is Smi { smi(-1) } else { at(s1, 4) })
                                                } else if state == 0 {
                                                    let slot = band(hash, mask);
                                                    hash_find_loop(p, put(s1, 2, smi(-1)), bci, index, mask, hash, slot, 1, slot, false, HASH_FUEL)
                                                } else {
                                                    match (at(s1, 3), at(s1, 6), at(s1, 5)) {
                                                        (Value::Smi(sl), Value::Smi(start), Value::Smi(stp)) =>
                                                            hash_find_loop(p, s1, bci, index, mask, hash, band(sl as int, mask), stp as int, start as int, true, HASH_FUEL),
                                                        _ => stuck(Stuck::NotSmi),
                                                    }
                                                }
                                            },
                                        }
                                    }
                                },
                            }
                        }
                    }
                }
            },
            _ => stuck(Stuck::NotSmi),
        }
    }
}

// ---------------------------------------------------------------------------
// The step function.

/// Operators need both operands on the stack.
pub open spec fn binary_ok(s: State) -> bool {
    has_slot(s, 1) && is_value(at(s, 0)) && is_value(at(s, 1))
}

#[verifier::opaque]
pub open spec fn step(p: Program, s: State) -> Outcome {
    let bci = s.bci as int;
    if !instruction_ok(p, bci) {
        stuck(Stuck::BadInstruction)
    } else {
        let op = p.bytecodes[bci];
        let len = opcode_length(op);
        let b1 = byte(p, bci + 1);
        let w1 = if len >= 3 { u16_at(p, bci + 1) } else { 0 };
        if op == LOAD_LOCAL { op_load_local(s, b1, len) }
        else if op == LOAD_LOCAL_WIDE { op_load_local(s, w1, len) }
        else if op == POP_LOAD_LOCAL { op_pop_load_local(s, b1) }
        else if op == STORE_LOCAL { op_store_local(s, b1) }
        else if op == STORE_LOCAL_POP { op_store_local_pop(s, b1) }
        else if op == LOAD_OUTER { op_load_outer(s, b1) }
        else if op == STORE_OUTER { op_store_outer(s, b1) }
        else if op == LOAD_FIELD { op_load_field(s, b1, len) }
        else if op == LOAD_FIELD_WIDE { op_load_field(s, w1, len) }
        else if op == LOAD_FIELD_LOCAL { op_load_field_local(s, b1, false) }
        else if op == POP_LOAD_FIELD_LOCAL { op_load_field_local(s, b1, true) }
        else if op == STORE_FIELD { op_store_field(s, b1, len, true) }
        else if op == STORE_FIELD_WIDE { op_store_field(s, w1, len, true) }
        else if op == STORE_FIELD_POP { op_store_field(s, b1, len, false) }
        else if LOAD_LOCAL_0 <= op && op <= LOAD_LOCAL_5 { op_load_local(s, op - LOAD_LOCAL_0, len) }
        else if op == LOAD_LITERAL { op_load_literal(p, s, b1, len) }
        else if op == LOAD_LITERAL_WIDE { op_load_literal(p, s, w1, len) }
        else if op == LOAD_NULL { next(push(s, null_v(p)), len) }
        else if op == LOAD_SMI_0 { op_load_smi(p, s, 0, len) }
        else if op == LOAD_SMIS_0 { op_load_smis_0(s, b1) }
        else if op == LOAD_SMI_1 { op_load_smi(p, s, 1, len) }
        else if op == LOAD_SMI_U8 { op_load_smi(p, s, b1, len) }
        else if op == LOAD_SMI_U16 { op_load_smi(p, s, w1, len) }
        else if op == LOAD_SMI_U32 || op == LOAD_METHOD { op_load_smi(p, s, u32_at(p, bci + 1), len) }
        else if op == LOAD_GLOBAL_VAR { op_load_global(s, b1, len) }
        else if op == LOAD_GLOBAL_VAR_WIDE { op_load_global(s, w1, len) }
        else if op == LOAD_GLOBAL_VAR_LAZY { op_load_global_lazy(p, s, b1, len) }
        else if op == LOAD_GLOBAL_VAR_LAZY_WIDE { op_load_global_lazy(p, s, w1, len) }
        else if op == LOAD_GLOBAL_VAR_DYNAMIC { op_load_global_dynamic(p, s) }
        else if op == STORE_GLOBAL_VAR { op_store_global(s, b1, len) }
        else if op == STORE_GLOBAL_VAR_WIDE { op_store_global(s, w1, len) }
        else if op == STORE_GLOBAL_VAR_DYNAMIC { op_store_global_dynamic(p, s) }
        else if op == LOAD_BLOCK { op_load_block(s, b1) }
        else if op == LOAD_OUTER_BLOCK { op_load_outer_block(s, b1) }
        else if op == POP { op_pop(s, b1, len) }
        else if op == POP_1 { op_pop(s, 1, len) }
        else if op == ALLOCATE { op_allocate(p, s, b1, len) }
        else if op == ALLOCATE_WIDE { op_allocate(p, s, w1, len) }
        else if op == IS_CLASS { op_is(p, s, b1, false, len) }
        else if op == IS_CLASS_WIDE { op_is(p, s, w1, false, len) }
        else if op == IS_INTERFACE { op_is(p, s, b1, true, len) }
        else if op == IS_INTERFACE_WIDE { op_is(p, s, w1, true, len) }
        else if op == AS_CLASS { op_as(p, s, b1, false, len) }
        else if op == AS_CLASS_WIDE { op_as(p, s, w1, false, len) }
        else if op == AS_INTERFACE { op_as(p, s, b1, true, len) }
        else if op == AS_INTERFACE_WIDE { op_as(p, s, w1, true, len) }
        else if op == AS_LOCAL { op_as_local(p, s, b1) }
        else if op == INVOKE_STATIC { op_invoke_static(p, s, w1) }
        else if op == INVOKE_STATIC_TAIL { op_invoke_static_tail(p, s, w1, byte(p, bci + 3), byte(p, bci + 4)) }
        else if op == INVOKE_BLOCK { op_invoke_block(p, s, b1) }
        else if op == INVOKE_LAMBDA_TAIL { op_invoke_lambda_tail(p, s, b1) }
        else if op == INVOKE_INITIALIZER_TAIL { op_invoke_initializer_tail(p, s, b1, byte(p, bci + 2)) }
        else if op == INVOKE_VIRTUAL { op_invoke_virtual(p, s, b1, u16_at(p, bci + 2), len) }
        else if op == INVOKE_VIRTUAL_WIDE { op_invoke_virtual(p, s, w1, u16_at(p, bci + 3), len) }
        else if op == INVOKE_VIRTUAL_GET { op_invoke_virtual_get(p, s, w1) }
        else if op == INVOKE_VIRTUAL_SET { op_invoke_virtual_set(p, s, w1) }
        else if INVOKE_EQ <= op && op <= INVOKE_AT_PUT && !binary_ok(s) { stuck(Stuck::StackRange) }
        else if op == INVOKE_EQ { op_invoke_eq(p, s) }
        else if INVOKE_LT <= op && op <= INVOKE_GTE { op_invoke_relational(p, s, op) }
        else if INVOKE_BIT_OR <= op && op <= INVOKE_MOD { op_invoke_arith(p, s, op) }
        else if op == INVOKE_AT { op_invoke_at(p, s) }
        else if op == INVOKE_AT_PUT { op_invoke_at_put(p, s) }
        else if op == INVOKE_SIZE { op_invoke_size(p, s, w1) }
        else if op == BRANCH { op_branch(p, s, 0, bci + w1, len) }
        else if op == BRANCH_IF_TRUE { op_branch(p, s, 1, bci + w1, len) }
        else if op == BRANCH_IF_FALSE { op_branch(p, s, 2, bci + w1, len) }
        else if op == BRANCH_IF_NOT_NULL { op_branch(p, s, 3, bci + w1, len) }
        else if op == BRANCH_BACK { op_branch(p, s, 0, bci - w1, len) }
        else if op == BRANCH_BACK_IF_TRUE { op_branch(p, s, 1, bci - w1, len) }
        else if op == BRANCH_BACK_IF_FALSE { op_branch(p, s, 2, bci - w1, len) }
        else if op == BRANCH_BACK_IF_NOT_NULL { op_branch(p, s, 3, bci - w1, len) }
        else if op == PRIMITIVE { Outcome::Primitive(s, p.bytecodes[bci + 1], u16_at(p, bci + 2) as u16) }
        else if op == THROW { op_throw(p, s) }
        else if op == RETURN { op_return(p, s, b1, byte(p, bci + 2), false) }
        else if op == RETURN_NULL { op_return(p, s, b1, byte(p, bci + 2), true) }
        else if op == NON_LOCAL_RETURN { op_non_local_return(p, s, b1 % 16, b1 / 16) }
        else if op == NON_LOCAL_RETURN_WIDE { op_non_local_return(p, s, w1, u16_at(p, bci + 3)) }
        else if op == NON_LOCAL_BRANCH { op_non_local_branch(p, s, b1, u32_at(p, bci + 2)) }
        else if op == IDENTICAL {
            if !binary_ok(s) { stuck(Stuck::StackRange) }
            else { binary_result(s, boolean(p, identical(s, at(s, 1), at(s, 0)))) }
        }
        else if op == LINK { op_link(s) }
        else if op == UNLINK { op_unlink(s) }
        else if op == UNWIND { unwind(p, s) }
        else if op == HALT { op_halt(s, b1) }
        else if op == INTRINSIC_SMI_REPEAT { op_smi_repeat(p, s) }
        else if op == INTRINSIC_ARRAY_DO { op_array_do(p, s) }
        else if op == INTRINSIC_HASH_FIND { op_hash_find(p, s) }
        else { op_hash_do(p, s) }  // INTRINSIC_HASH_DO
    }
}

} // verus!

