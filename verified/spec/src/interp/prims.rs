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

//! Primitive oracle: Rust implementations of the primitives the core
//! library needs, following `src/primitive_core.cc` and friends. Dispatch is
//! by name (`module::name` from the snapshot's primitive table), so the
//! table indices of the VM build do not matter.
//!
//! The arity used to drop the arguments on success is the arity of the
//! method that contains the PRIMITIVE bytecode (the C++ VM uses the
//! primitive's declared arity; the compiler makes them equal).

use super::*;
use super::system::{Message, MsgValue};
use crate::types::Stuck;

/// Result of a primitive.
pub enum PR {
    Ok(Value),
    /// Failure with an error value (usually one of the error-string roots).
    Fail(Value),
    /// The primitive does not exist in the VM (primitive_lookup_failure).
    Missing,
    /// The primitive exists in the C++ VM but has no Rust implementation.
    Unimplemented,
    /// The primitive needs something from the outside world the emulation
    /// does not provide (e.g. a system service).
    UnimplementedNamed(String),
    /// The primitive already completed the step (task primitives).
    Done,
}

const ERROR_NAMES: [&str; 28] = [
    "ALLOCATION_FAILED", "ALLOCATION_SIZE_EXCEEDED", "ALREADY_CLOSED", "ALREADY_EXISTS",
    "DIVISION_BY_ZERO", "ERROR", "FILE_NOT_FOUND", "HARDWARE_ERROR", "ILLEGAL_UTF_8",
    "INVALID_ARGUMENT", "MALLOC_FAILED", "CROSS_PROCESS_GC", "NEGATIVE_ARGUMENT", "OUT_OF_BOUNDS",
    "OUT_OF_RANGE", "ALREADY_IN_USE", "OVERFLOW", "PRIVILEGED_PRIMITIVE", "PERMISSION_DENIED",
    "QUOTA_EXCEEDED", "READ_FAILED", "STACK_OVERFLOW", "UNIMPLEMENTED", "WRONG_OBJECT_TYPE",
    "WRONG_BYTES_TYPE", "INVALID_SIGNATURE", "INVALID_STATE", "UNSUPPORTED",
];

pub fn call(m: &mut Machine, module: u8, index: u16) -> Result<(), End> {
    if m.format == 2 {
        return call2(m, module, index);
    }
    let name = m.names.primitive(module, index);
    let arity = match m.names.method_at(m.s.bci) {
        Some((id, _, _)) => m.method_arity(id),
        None => return Err(End::Stuck(Stuck::NotMethod, m.backtrace())),
    };
    if m.s.stack.len() < 2 + arity {
        return Err(End::Stuck(Stuck::StackRange, m.backtrace()));
    }
    let args: Vec<Value> = (0..arity).map(|j| m.at(2 + arity - 1 - j).unwrap()).collect();
    let r = super::prims_impl::dispatch(m, &name, &args);
    let r = match r {
        Ok(r) => r,
        Err(stuck) => return Err(End::Stuck(stuck, format!("in primitive {}\n  {}", name, m.backtrace()))),
    };
    let step = match r {
        PR::Ok(v) => m.return_to_caller(arity, v),
        PR::Fail(e) => {
            m.push(e);
            m.s.bci += 4;
            Ok(Step::Next)
        }
        PR::Missing => {
            m.push(Value::Smi(module as i64));
            m.push(Value::Smi(index as i64));
            let t = m.entry_method(PRIMITIVE_LOOKUP_FAILURE);
            let ret = m.s.bci + 4;
            m.call_with(t, ret)
        }
        PR::Unimplemented => return Err(End::Unimplemented(name)),
        PR::UnimplementedNamed(what) => return Err(End::Unimplemented(what)),
        PR::Done => Ok(Step::Next),
    };
    match step {
        Ok(_) => Ok(()),
        Err(stuck) => Err(End::Stuck(stuck, m.backtrace())),
    }
}

/// Format 2 (`v2::prim`): the arguments are the parameters of the top
/// frame; success returns from the frame, failure continues after the
/// PRIMITIVE with the error pushed, a missing primitive raises
/// PRIMITIVE_LOOKUP_FAILED.
fn call2(m: &mut Machine, module: u8, index: u16) -> Result<(), End> {
    let name = m.names.primitive(module, index);
    let frame = match m.top_frame() {
        Ok(f) => f,
        Err(stuck) => return Err(End::Stuck(stuck, m.backtrace())),
    };
    let arity = m.p.methods[frame.method].arity as usize;
    if m.s.stack.len() != frame.base + arity {
        return Err(End::Stuck(Stuck::StackRange, m.backtrace()));
    }
    let args: Vec<Value> = m.s.stack[frame.base..].to_vec();
    let r = match super::prims_impl::dispatch(m, &name, &args) {
        Ok(r) => r,
        Err(stuck) => return Err(End::Stuck(stuck, format!("in primitive {}\n  {}", name, m.backtrace()))),
    };
    let step = match r {
        PR::Ok(v) => m.return2(v),
        PR::Fail(e) => {
            m.push(e);
            m.s.bci += 4;
            Ok(Step::Next)
        }
        PR::Missing => m.raise(super::exec2::PRIMITIVE_LOOKUP_FAILED),
        PR::Unimplemented => return Err(End::Unimplemented(name)),
        PR::UnimplementedNamed(what) => return Err(End::Unimplemented(what)),
        PR::Done => Ok(Step::Next),
    };
    match step {
        Ok(Step::Halt(Halt::Uncaught(v))) => Err(End::Uncaught(m.describe(v))),
        Ok(Step::Halt(Halt::TaskReturned)) => Err(End::TaskReturned),
        Ok(_) => Ok(()),
        Err(stuck) => Err(End::Stuck(stuck, m.backtrace())),
    }
}

/// Helpers shared by the primitive implementations.
impl Machine {
    pub fn error(&self, name: &str) -> Value {
        let i = ERROR_NAMES.iter().position(|n| *n == name).expect("unknown error name");
        self.p.roots[7 + i]
    }

    pub fn fail(&self, name: &str) -> PR {
        PR::Fail(self.error(name))
    }

    pub fn new_string(&mut self, bytes: Vec<u8>) -> Value {
        let cid = self.builtin(STRING_CLASS);
        self.alloc(ExecObj { class_id: cid, ro: false, body: ExecBody::Str(bytes) })
    }

    pub fn new_bytes(&mut self, bytes: Vec<u8>) -> Value {
        let cid = self.builtin(BYTE_ARRAY_CLASS);
        self.alloc(ExecObj { class_id: cid, ro: false, body: ExecBody::Bytes(bytes) })
    }

    pub fn new_array(&mut self, elems: Vec<Value>) -> Value {
        let cid = self.builtin(ARRAY_CLASS);
        self.alloc(ExecObj { class_id: cid, ro: false, body: ExecBody::Array(elems) })
    }

    pub fn new_double(&mut self, d: f64) -> Value {
        let cid = self.builtin(DOUBLE_CLASS);
        self.alloc(ExecObj { class_id: cid, ro: false, body: ExecBody::Double(d.to_bits()) })
    }

    /// `Primitive::integer`: a smi if it fits, else a LargeInteger.
    pub fn integer(&mut self, v: i64) -> Value {
        if self.smi_ok(v as i128) {
            Value::Smi(v)
        } else {
            let cid = self.builtin(LARGE_INTEGER_CLASS);
            self.alloc(ExecObj { class_id: cid, ro: false, body: ExecBody::LargeInt(v) })
        }
    }

    pub fn int_of(&self, v: Value) -> Option<i64> {
        match v {
            Value::Smi(i) => Some(i),
            _ => self.large_int(v),
        }
    }

    pub fn is_string(&self, v: Value) -> bool {
        self.str_bytes(v).is_some()
    }

    pub fn byte_array(&self, v: Value) -> Option<&Vec<u8>> {
        match self.obj(v) {
            Some(ExecObj { body: ExecBody::Bytes(b), .. }) => Some(b),
            _ => None,
        }
    }

    pub fn array(&self, v: Value) -> Option<&Vec<Value>> {
        match self.obj(v) {
            Some(ExecObj { body: ExecBody::Array(e), .. }) => Some(e),
            _ => None,
        }
    }

    /// `Blob` unpacking (`Object::byte_content`): strings, byte arrays,
    /// copy-on-write byte arrays, byte-array slices and string slices.
    pub fn blob(&self, v: Value, strings_only: bool) -> Option<Vec<u8>> {
        if let Some(s) = self.str_bytes(v) {
            return Some(s.clone());
        }
        if !strings_only {
            if let Some(b) = self.byte_array(v) {
                return Some(b.clone());
            }
        }
        let f = self.fields(v)?;
        let cid = self.class_of(v)?;
        if !strings_only && cid == self.builtin(BYTE_ARRAY_COW_CLASS) {
            return self.byte_array(f[0]).cloned();
        }
        let slice_kind = if cid == self.builtin(STRING_SLICE_CLASS) {
            true
        } else if !strings_only && cid == self.builtin(BYTE_ARRAY_SLICE_CLASS) {
            false
        } else {
            return None;
        };
        let (from, to) = match (f.get(1)?, f.get(2)?) {
            (Value::Smi(a), Value::Smi(b)) => (*a, *b),
            _ => return None,
        };
        let inner = self.blob(f[0], slice_kind)?;
        if from < 0 || to < from || to as usize > inner.len() {
            return None;
        }
        Some(inner[from as usize..to as usize].to_vec())
    }

    pub fn string_of(&self, v: Value) -> Option<String> {
        self.blob(v, true).map(|b| String::from_utf8_lossy(&b).into_owned())
    }

    /// Converts a heap value into a message value (the message encoder).
    pub fn encode_message(&self, v: Value, depth: u32) -> Option<MsgValue> {
        if depth > 16 {
            return None;
        }
        if v == self.null() { return Some(MsgValue::Null); }
        if v == self.true_v() { return Some(MsgValue::Bool(true)); }
        if v == self.false_v() { return Some(MsgValue::Bool(false)); }
        if let Some(i) = self.int_of(v) { return Some(MsgValue::Int(i)); }
        if let Some(s) = self.blob(v, true) { return Some(MsgValue::Str(String::from_utf8_lossy(&s).into_owned())); }
        if let Some(e) = self.array(v) {
            return e.iter().map(|x| self.encode_message(*x, depth + 1)).collect::<Option<Vec<_>>>().map(MsgValue::List);
        }
        if let Some(b) = self.blob(v, false) { return Some(MsgValue::Bytes(b)); }
        if self.is_class(v, LIST_CLASS) {
            let f = self.fields(v)?;
            let size = match f[1] { Value::Smi(s) => s as usize, _ => return None };
            let backing = self.array(f[0])?;
            return backing.iter().take(size).map(|x| self.encode_message(*x, depth + 1))
                .collect::<Option<Vec<_>>>().map(MsgValue::List);
        }
        None
    }

    /// Builds heap objects for a received message (the message decoder).
    /// Lists decode to `Array_`, as in the C++ VM.
    pub fn decode_message(&mut self, v: &MsgValue) -> Value {
        match v {
            MsgValue::Null => self.null(),
            MsgValue::Bool(b) => self.boolean(*b),
            MsgValue::Int(i) => self.integer(*i),
            MsgValue::Str(s) => self.new_string(s.as_bytes().to_vec()),
            MsgValue::Bytes(b) => self.new_bytes(b.clone()),
            MsgValue::List(l) => {
                let elems: Vec<Value> = l.iter().map(|x| self.decode_message(x)).collect();
                self.new_array(elems)
            }
        }
    }

    pub fn receive_message(&mut self) -> Value {
        match self.world.mailbox.pop_front() {
            None => self.null(),
            Some(Message::Monitor(mon)) => mon,
            Some(Message::System(ty, gid, pid, payload)) => {
                let p = self.decode_message(&payload);
                let elems = vec![Value::Smi(ty), Value::Smi(gid), Value::Smi(pid), p];
                self.new_array(elems)
            }
        }
    }
}
