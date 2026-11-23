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

//! Basic spec vocabulary: smis, instruction decoding, stack access,
//! program tables, method headers, dispatch.

use vstd::prelude::*;
use crate::types::*;

verus! {

// ---------------------------------------------------------------------------
// Constants from the C++ sources.

/// `Interpreter::FRAME_SIZE`.
pub spec const FRAME_SIZE: int = 2;
/// `Method::HEADER_SIZE` (= `ENTRY_OFFSET`).
pub spec const METHOD_HEADER_SIZE: int = 4;
/// `HeapObject::CLASS_ID_OFFSET` (tag 4 bits + finalizer bit).
pub const CLASS_ID_OFFSET: u16 = 5;
pub const INSTANCE_TAG: u16 = 2;
/// `Array::ARRAYLET_SIZE`.
pub spec const ARRAYLET_SIZE: int = 500;

// Indexes into `Program.builtin` (BUILTIN_CLASS_IDS order).
pub spec const STRING_CLASS: int = 0;
pub spec const ARRAY_CLASS: int = 1;
pub spec const BYTE_ARRAY_CLASS: int = 2;
pub spec const BYTE_ARRAY_COW_CLASS: int = 3;
pub spec const BYTE_ARRAY_SLICE_CLASS: int = 4;
pub spec const LIST_CLASS: int = 7;
pub spec const MAP_CLASS: int = 9;
pub spec const TOMBSTONE_CLASS: int = 10;
pub spec const STACK_CLASS: int = 11;
pub spec const DOUBLE_CLASS: int = 16;
pub spec const LARGE_INTEGER_CLASS: int = 17;
pub spec const SMI_CLASS: int = 18;
pub spec const TASK_CLASS: int = 19;
pub spec const LARGE_ARRAY_CLASS: int = 20;
pub spec const LAZY_INITIALIZER_CLASS: int = 21;
pub spec const EXCEPTION_CLASS: int = 22;

// Indexes into `Program.entry_points` (entry_points.h order).
pub spec const ENTRY_MAIN: int = 0;
pub spec const ENTRY_SPAWN: int = 1;
pub spec const ENTRY_TASK: int = 2;
pub spec const LOOKUP_FAILURE: int = 3;
pub spec const AS_CHECK_FAILURE: int = 4;
pub spec const PRIMITIVE_LOOKUP_FAILURE: int = 5;
pub spec const CODE_FAILURE: int = 6;
pub spec const PROGRAM_FAILURE: int = 7;
pub spec const RUN_GLOBAL_INITIALIZER: int = 8;

// Indexes into `Program.roots`.
pub spec const NULL_ROOT: int = 0;
pub spec const TRUE_ROOT: int = 1;
pub spec const FALSE_ROOT: int = 2;
pub spec const EMPTY_ARRAY_ROOT: int = 3;
pub spec const ERROR_ROOT: int = 12;

// ---------------------------------------------------------------------------
// Smis. The C++ VM tags smis with a 0 low bit, so a smi has
// `word_bits - 1` bits.

pub open spec fn smi_bits(p: Program) -> int {
    if p.word_bits == 32 { 31 } else { 63 }
}

pub open spec fn smi_max(p: Program) -> int {
    if p.word_bits == 32 { 0x3fff_ffff } else { 0x3fff_ffff_ffff_ffff }
}

pub open spec fn smi_min(p: Program) -> int {
    if p.word_bits == 32 { -0x4000_0000 } else { -0x4000_0000_0000_0000 }
}

pub open spec fn smi_ok(p: Program, v: int) -> bool {
    smi_min(p) <= v <= smi_max(p)
}

/// Bits of a machine word (`WORD_BIT_SIZE`).
pub open spec fn word_bit_size(p: Program) -> int {
    if p.word_bits == 32 { 32 } else { 64 }
}

/// `Smi::from(v)` for a `v` that may not fit: the C++ VM shifts the value
/// left by one and loses the top bit. This wraps `v` into the smi range.
pub open spec fn smi_wrap(p: Program, v: int) -> int {
    let m = smi_max(p) + 1;  // 2^(bits-1)
    let r = (v + m) % (2 * m);  // Euclidean, in 0..2m
    r - m
}

pub open spec fn smi(v: int) -> Value {
    Value::Smi(v as i64)
}

/// Two's complement truncation to 32 bits (`int x = (word) y`).
pub open spec fn trunc32(v: int) -> int {
    let r = (v + 0x8000_0000) % 0x1_0000_0000int;
    r - 0x8000_0000
}

/// C/C++ truncating division (`/` on `word`).
pub open spec fn tdiv(a: int, b: int) -> int
    recommends b != 0,
{
    let q = (if a >= 0 { a } else { -a }) / (if b >= 0 { b } else { -b });
    if (a >= 0) == (b >= 0) { q } else { -q }
}

/// C/C++ remainder (`%` on `word`): sign follows the dividend.
pub open spec fn trem(a: int, b: int) -> int
    recommends b != 0,
{
    a - b * tdiv(a, b)
}

/// Arithmetic shift right (`>>` on `word`), i.e. floor division by 2^n.
pub open spec fn shr(a: int, n: nat) -> int {
    a / (vstd::arithmetic::power2::pow2(n) as int)
}

// ---------------------------------------------------------------------------
// Instruction decoding.

pub open spec fn byte(p: Program, i: int) -> int {
    p.bytecodes[i] as int
}

pub open spec fn u16_at(p: Program, i: int) -> int {
    byte(p, i) + 256 * byte(p, i + 1)
}

pub open spec fn u32_at(p: Program, i: int) -> int {
    u16_at(p, i) + 65536 * u16_at(p, i + 2)
}

/// The instruction at `bci` exists: a valid opcode whose operands lie inside
/// the bytecodes.
pub open spec fn instruction_ok(p: Program, bci: int) -> bool {
    0 <= bci < p.bytecodes.len()
        && p.bytecodes[bci] < crate::bytecodes::OPCODE_COUNT
        && bci + crate::bytecodes::opcode_length(p.bytecodes[bci]) <= p.bytecodes.len()
}

// ---------------------------------------------------------------------------
// Stack access. `at(s, n)` is the C++ `STACK_AT(n)`.

pub open spec fn height(s: State) -> int {
    s.stack.len() as int
}

pub open spec fn has_slot(s: State, n: int) -> bool {
    0 <= n < s.stack.len()
}

pub open spec fn at(s: State, n: int) -> Value
    recommends has_slot(s, n),
{
    s.stack[s.stack.len() - 1 - n]
}

/// Value words: everything that may be loaded, stored and passed around.
/// Frame words (return addresses and frame markers) may only be touched by
/// calls, returns and unwinding.
pub open spec fn is_value(v: Value) -> bool {
    match v {
        Value::RetAddr(_) => false,
        Value::FrameMarker => false,
        _ => true,
    }
}

pub open spec fn push(s: State, v: Value) -> State {
    State { stack: s.stack.push(v), ..s }
}

pub open spec fn drop(s: State, n: int) -> State
    recommends 0 <= n <= s.stack.len(),
{
    State { stack: s.stack.subrange(0, s.stack.len() - n), ..s }
}

/// `STACK_AT_PUT(n, v)`.
pub open spec fn put(s: State, n: int, v: Value) -> State
    recommends has_slot(s, n),
{
    State { stack: s.stack.update(s.stack.len() - 1 - n, v), ..s }
}

pub open spec fn goto(s: State, bci: int) -> State {
    State { bci: bci as usize, ..s }
}

/// Continue with the next instruction.
pub open spec fn next(s: State, len: int) -> Outcome {
    Outcome::Next(goto(s, s.bci + len))
}

pub open spec fn stuck(r: Stuck) -> Outcome {
    Outcome::Stuck(r)
}

// ---------------------------------------------------------------------------
// Program tables.

pub open spec fn null_v(p: Program) -> Value { p.roots[NULL_ROOT] }
pub open spec fn true_v(p: Program) -> Value { p.roots[TRUE_ROOT] }
pub open spec fn false_v(p: Program) -> Value { p.roots[FALSE_ROOT] }

pub open spec fn boolean(p: Program, b: bool) -> Value {
    if b { true_v(p) } else { false_v(p) }
}

/// `Interpreter::is_true_value`: only false and null are false.
pub open spec fn truthy(p: Program, v: Value) -> bool {
    v != false_v(p) && v != null_v(p)
}

pub open spec fn builtin(p: Program, k: int) -> int {
    p.builtin[k] as int
}

pub open spec fn class_tag(p: Program, cid: int) -> u16 {
    p.class_bits[cid] & 0xf
}

/// Number of fields of an instance of class `cid` (instance size in words
/// minus the header word).
pub open spec fn instance_field_count(p: Program, cid: int) -> int {
    (((p.class_bits[cid] >> CLASS_ID_OFFSET) & 0x7ff) as int) - 1
}

// ---------------------------------------------------------------------------
// Methods. A method id is the absolute offset of its 4-byte header.

pub open spec fn valid_method(p: Program, id: int) -> bool {
    0 <= id && id + METHOD_HEADER_SIZE <= p.bytecodes.len() && p.method_start[id]
}

pub open spec fn method_arity(p: Program, id: int) -> int {
    (p.bytecodes[id] & 0x7f) as int
}

pub open spec fn method_kind(p: Program, id: int) -> int {
    (p.bytecodes[id + 1] & 0x3) as int
}

pub open spec fn method_value(p: Program, id: int) -> int {
    u16_at(p, id + 2)
}

/// `Method::selector_offset`.
pub open spec fn method_selector_offset(p: Program, id: int) -> int {
    if (p.bytecodes[id] & 0x80) != 0 {
        -method_value(p, id)
    } else if method_value(p, id) == 0xffff {
        -1
    } else {
        method_value(p, id)
    }
}

pub open spec fn method_entry(id: int) -> int {
    id + METHOD_HEADER_SIZE
}

pub spec const KIND_FIELD_ACCESSOR: int = 1;

/// Method id of entry point `k`, or -1.
pub open spec fn entry_method(p: Program, k: int) -> int {
    let d = p.entry_points[k] as int;
    if 0 <= d < p.dispatch.len() { p.dispatch[d] as int } else { -1 }
}

/// `CALL_METHOD_WITH_RETURN_ADDRESS`: push the frame and jump to the entry.
/// Stack-overflow handling and preemption are not modeled.
pub open spec fn call_with(p: Program, s: State, target: int, ret: int) -> Outcome {
    if !valid_method(p, target) {
        stuck(Stuck::NotMethod)
    } else {
        Outcome::Next(goto(
            push(push(s, Value::RetAddr(ret as usize)), Value::FrameMarker),
            method_entry(target),
        ))
    }
}

/// `CALL_METHOD(target, offset)`: return to `bci + offset`.
pub open spec fn call(p: Program, s: State, target: int, offset: int) -> Outcome {
    call_with(p, s, target, s.bci + offset)
}

/// Call entry point `k`.
pub open spec fn call_entry(p: Program, s: State, k: int, offset: int) -> Outcome {
    call(p, s, entry_method(p, k), offset)
}

// ---------------------------------------------------------------------------
// Heap.

pub open spec fn obj_ok(s: State, v: Value) -> bool {
    match v {
        Value::Obj(id) => id < s.heap.len(),
        _ => false,
    }
}

pub open spec fn obj(s: State, v: Value) -> HeapObj
    recommends obj_ok(s, v),
{
    match v {
        Value::Obj(id) => s.heap[id as int],
        _ => arbitrary(),
    }
}

pub open spec fn obj_id(v: Value) -> int {
    match v {
        Value::Obj(id) => id as int,
        _ => -1,
    }
}

pub open spec fn is_instance(s: State, v: Value) -> bool {
    obj_ok(s, v) && obj(s, v).body is Instance
}

pub open spec fn fields(s: State, v: Value) -> Seq<Value>
    recommends is_instance(s, v),
{
    match obj(s, v).body {
        Body::Instance(f) => f,
        _ => Seq::empty(),
    }
}

pub open spec fn is_array(s: State, v: Value) -> bool {
    obj_ok(s, v) && obj(s, v).body is Array
}

pub open spec fn elements(s: State, v: Value) -> Seq<Value> {
    match obj(s, v).body {
        Body::Array(e) => e,
        _ => Seq::empty(),
    }
}

pub open spec fn is_bytes(s: State, v: Value) -> bool {
    obj_ok(s, v) && obj(s, v).body is Bytes
}

pub open spec fn bytes(s: State, v: Value) -> Seq<u8> {
    match obj(s, v).body {
        Body::Bytes(b) => b,
        _ => Seq::empty(),
    }
}

pub open spec fn is_double(s: State, v: Value) -> bool {
    obj_ok(s, v) && obj(s, v).body is Double
}

pub open spec fn double_bits(s: State, v: Value) -> u64 {
    match obj(s, v).body {
        Body::Double(b) => b,
        _ => 0,
    }
}

pub open spec fn is_large_int(s: State, v: Value) -> bool {
    obj_ok(s, v) && obj(s, v).body is LargeInt
}

pub open spec fn large_int(s: State, v: Value) -> int {
    match obj(s, v).body {
        Body::LargeInt(i) => i as int,
        _ => 0,
    }
}

pub open spec fn is_string(s: State, v: Value) -> bool {
    obj_ok(s, v) && obj(s, v).body is Str
}

pub open spec fn str_bytes(s: State, v: Value) -> Seq<u8> {
    match obj(s, v).body {
        Body::Str(b) => b,
        _ => Seq::empty(),
    }
}

pub open spec fn class_of_obj(s: State, v: Value) -> int {
    obj(s, v).class_id as int
}

/// Class id of a value: smis have `smi_class_id`; block references and
/// links are smis in the C++ VM but have no class in the spec.
pub open spec fn class_id_ok(s: State, v: Value) -> bool {
    match v {
        Value::Smi(_) => true,
        Value::Obj(id) => id < s.heap.len(),
        _ => false,
    }
}

pub open spec fn class_id_of(p: Program, s: State, v: Value) -> int {
    match v {
        Value::Smi(_) => builtin(p, SMI_CLASS),
        _ => class_of_obj(s, v),
    }
}

/// Replaces the object at `id`.
pub open spec fn set_obj(s: State, id: int, o: HeapObj) -> State {
    State { heap: s.heap.update(id, o), ..s }
}

/// Appends a new object; its id is the old heap length.
pub open spec fn alloc(s: State, o: HeapObj) -> State {
    State { heap: s.heap.push(o), ..s }
}

pub open spec fn new_ref(s: State) -> Value {
    Value::Obj(s.heap.len() as usize)
}

/// Writes field `f` of instance `inst`.
pub open spec fn set_field(s: State, inst: Value, f: int, v: Value) -> State {
    let o = obj(s, inst);
    set_obj(s, obj_id(inst), HeapObj { body: Body::Instance(fields(s, inst).update(f, v)), ..o })
}

pub open spec fn new_double(s: State, p: Program, bits: u64) -> HeapObj {
    HeapObj { class_id: p.builtin[DOUBLE_CLASS], ro: false, body: Body::Double(bits) }
}

// ---------------------------------------------------------------------------
// Dispatch.

pub enum Lookup {
    Found(int),
    Missing,
    Stuck(Stuck),
}

/// `Program::find_method`.
pub open spec fn find_method(p: Program, s: State, receiver: Value, offset: int) -> Lookup {
    if !class_id_ok(s, receiver) {
        Lookup::Stuck(Stuck::NotObject)
    } else {
        let index = class_id_of(p, s, receiver) + offset;
        if !(0 <= index < p.dispatch.len()) {
            Lookup::Stuck(Stuck::TableRange)
        } else {
            let entry = p.dispatch[index] as int;
            if entry == -1 {
                Lookup::Missing
            } else if !valid_method(p, entry) {
                Lookup::Stuck(Stuck::NotMethod)
            } else if method_selector_offset(p, entry) != offset {
                Lookup::Missing
            } else {
                Lookup::Found(entry)
            }
        }
    }
}

/// A virtual call of selector `offset` on `receiver`, whose arguments are on
/// the stack. On a miss, pushes receiver and selector and calls
/// `lookup_failure`.
pub open spec fn invoke_virtual(p: Program, s: State, receiver: Value, offset: int, len: int) -> Outcome {
    match find_method(p, s, receiver, offset) {
        Lookup::Stuck(r) => stuck(r),
        Lookup::Missing => call_entry(p, push(push(s, receiver), smi(offset)), LOOKUP_FAILURE, len),
        Lookup::Found(t) => call(p, s, t, len),
    }
}

/// `INVOKE_VIRTUAL_FALLBACK` for the operator bytecodes: the receiver was
/// pushed again on top of the arguments and is popped here.
pub open spec fn virtual_fallback(p: Program, s: State, op: u8) -> Outcome {
    let k = op - crate::bytecodes::INVOKE_EQ;
    let sel = p.invoke_offsets[k] as int;
    let receiver = at(s, 0);
    invoke_virtual(p, drop(s, 1), receiver, sel, 1)
}

/// Reads the method id stored in the slot a block reference points to.
pub open spec fn block_method(p: Program, s: State, b: Value) -> int
    recommends b is Block,
{
    match b {
        Value::Block(h) => {
            if 1 <= h <= s.stack.len() {
                match s.stack[h - 1] {
                    Value::Smi(m) => m as int,
                    _ => -1,
                }
            } else {
                -1
            }
        },
        _ => -1,
    }
}

pub open spec fn block_ok(p: Program, s: State, b: Value) -> bool {
    b is Block && valid_method(p, block_method(p, s, b))
}

} // verus!
