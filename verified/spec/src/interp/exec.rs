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

//! Unverified executable step for all opcodes. Each `op_*` mirrors the spec
//! function of the same name in `spec_step.rs`; the opcodes covered by
//! `exec_step` (verified) are dispatched there instead (see `Machine::step`).

use super::*;
use crate::bytecodes::*;
use crate::types::Stuck::*;

type R = Result<Step, Stuck>;

impl Machine {
    // -----------------------------------------------------------------------
    // Stack.

    pub fn at(&self, n: usize) -> Result<Value, Stuck> {
        let len = self.s.stack.len();
        if n < len { Ok(self.s.stack[len - 1 - n]) } else { Err(StackRange) }
    }

    pub fn at_value(&self, n: usize) -> Result<Value, Stuck> {
        let v = self.at(n)?;
        if is_value(v) { Ok(v) } else { Err(FrameWord) }
    }

    pub fn put(&mut self, n: usize, v: Value) {
        let len = self.s.stack.len();
        self.s.stack[len - 1 - n] = v;
    }

    pub fn push(&mut self, v: Value) {
        self.s.stack.push(v);
    }

    pub fn drop_n(&mut self, n: usize) -> Result<(), Stuck> {
        let len = self.s.stack.len();
        if n > len {
            return Err(StackRange);
        }
        self.s.stack.truncate(len - n);
        Ok(())
    }

    fn next(&mut self, len: usize) -> R {
        self.s.bci += len;
        Ok(Step::Next)
    }

    // -----------------------------------------------------------------------
    // Program and heap.

    pub fn null(&self) -> Value { self.p.roots[0] }
    pub fn true_v(&self) -> Value { self.p.roots[1] }
    pub fn false_v(&self) -> Value { self.p.roots[2] }
    pub fn boolean(&self, b: bool) -> Value { if b { self.true_v() } else { self.false_v() } }
    pub fn truthy(&self, v: Value) -> bool { v != self.false_v() && v != self.null() }
    pub fn builtin(&self, k: usize) -> u16 { self.p.builtin[k] }

    pub fn byte(&self, i: usize) -> usize { self.p.bytecodes[i] as usize }
    pub fn u16_at(&self, i: usize) -> usize { self.byte(i) | (self.byte(i + 1) << 8) }
    pub fn u32_at(&self, i: usize) -> usize { self.u16_at(i) | (self.u16_at(i + 2) << 16) }

    pub fn obj(&self, v: Value) -> Option<&ExecObj> {
        match v {
            Value::Obj(id) => self.s.heap.get(id),
            _ => None,
        }
    }

    pub fn obj_mut(&mut self, v: Value) -> Option<&mut ExecObj> {
        match v {
            Value::Obj(id) => self.s.heap.get_mut(id),
            _ => None,
        }
    }

    pub fn fields(&self, v: Value) -> Option<&Vec<Value>> {
        match self.obj(v) {
            Some(ExecObj { body: ExecBody::Instance(f), .. }) => Some(f),
            _ => None,
        }
    }

    pub fn class_of(&self, v: Value) -> Option<u16> {
        self.obj(v).map(|o| o.class_id)
    }

    pub fn is_class(&self, v: Value, builtin: usize) -> bool {
        self.class_of(v) == Some(self.builtin(builtin))
    }

    pub fn class_id_of(&self, v: Value) -> Result<i64, Stuck> {
        match v {
            Value::Smi(_) => Ok(self.builtin(SMI_CLASS) as i64),
            Value::Obj(_) => self.class_of(v).map(|c| c as i64).ok_or(NotObject),
            _ => Err(NotObject),
        }
    }

    pub fn alloc(&mut self, o: ExecObj) -> Value {
        self.s.heap.push(o);
        Value::Obj(self.s.heap.len() - 1)
    }

    fn set_field(&mut self, inst: Value, f: usize, v: Value) {
        if let Some(ExecObj { body: ExecBody::Instance(fs), .. }) = self.obj_mut(inst) {
            fs[f] = v;
        }
    }

    pub fn smi_ok(&self, v: i128) -> bool {
        let (min, max) = loader::smi_range(self.p.word_bits);
        min as i128 <= v && v <= max as i128
    }

    pub fn smi_wrap(&self, v: i128) -> i64 {
        let bits = if self.p.word_bits == 32 { 31 } else { 63 };
        let m: i128 = 1 << (bits - 1);
        ((v + m).rem_euclid(2 * m) - m) as i64
    }

    pub fn word_bit_size(&self) -> i64 {
        if self.p.word_bits == 32 { 32 } else { 64 }
    }

    // -----------------------------------------------------------------------
    // Methods and dispatch.

    pub fn valid_method(&self, id: i64) -> bool {
        id >= 0 && (id as usize) + 4 <= self.p.bytecodes.len() && self.p.method_start[id as usize]
    }

    pub fn method_arity(&self, id: usize) -> usize { (self.p.bytecodes[id] & 0x7f) as usize }
    pub fn method_kind(&self, id: usize) -> usize { (self.p.bytecodes[id + 1] & 3) as usize }

    pub fn method_selector_offset(&self, id: usize) -> i64 {
        let value = self.u16_at(id + 2) as i64;
        if self.p.bytecodes[id] & 0x80 != 0 {
            -value
        } else if value == 0xffff {
            -1
        } else {
            value
        }
    }

    pub fn entry_method(&self, k: usize) -> i64 {
        let d = self.p.entry_points[k] as i64;
        if 0 <= d && (d as usize) < self.p.dispatch.len() { self.p.dispatch[d as usize] as i64 } else { -1 }
    }

    pub fn call_with(&mut self, target: i64, ret: usize) -> R {
        if !self.valid_method(target) {
            return Err(NotMethod);
        }
        self.push(Value::RetAddr(ret));
        self.push(Value::FrameMarker);
        self.s.bci = target as usize + 4;
        Ok(Step::Next)
    }

    fn call(&mut self, target: i64, offset: usize) -> R {
        let ret = self.s.bci + offset;
        self.call_with(target, ret)
    }

    fn call_entry(&mut self, k: usize, offset: usize) -> R {
        let t = self.entry_method(k);
        self.call(t, offset)
    }

    pub fn find_method(&self, recv: Value, offset: i64) -> Result<Option<usize>, Stuck> {
        let index = self.class_id_of(recv)? + offset;
        if !(0 <= index && (index as usize) < self.p.dispatch.len()) {
            return Err(TableRange);
        }
        let entry = self.p.dispatch[index as usize] as i64;
        if entry == -1 {
            return Ok(None);
        }
        if !self.valid_method(entry) {
            return Err(NotMethod);
        }
        if self.method_selector_offset(entry as usize) != offset {
            return Ok(None);
        }
        Ok(Some(entry as usize))
    }

    fn invoke_virtual(&mut self, recv: Value, offset: i64, len: usize) -> R {
        match self.find_method(recv, offset)? {
            Some(t) => self.call(t as i64, len),
            None => {
                self.push(recv);
                self.push(Value::Smi(offset));
                self.call_entry(LOOKUP_FAILURE, len)
            }
        }
    }

    fn virtual_fallback(&mut self, op: u8) -> R {
        let sel = self.p.invoke_offsets[(op - INVOKE_EQ) as usize] as i64;
        let recv = self.at(0)?;
        self.drop_n(1)?;
        self.invoke_virtual(recv, sel, 1)
    }

    fn fallback(&mut self, op: u8) -> R {
        let a0 = self.at(1)?;
        self.push(a0);
        self.virtual_fallback(op)
    }

    pub fn block_method(&self, b: Value) -> Result<usize, Stuck> {
        match b {
            Value::Block(h) => {
                if 1 <= h && h <= self.s.stack.len() {
                    if let Value::Smi(m) = self.s.stack[h - 1] {
                        if self.valid_method(m) {
                            return Ok(m as usize);
                        }
                    }
                }
                Err(NotMethod)
            }
            _ => Err(NotBlock),
        }
    }

    // -----------------------------------------------------------------------
    // The step.

    pub fn step_unverified(&mut self) -> R {
        let bci = self.s.bci;
        let len_bc = self.p.bytecodes.len();
        if bci >= len_bc || self.p.bytecodes[bci] >= OPCODE_COUNT {
            return Err(BadInstruction);
        }
        let op = self.p.bytecodes[bci];
        let len = OPCODE_LENGTHS[op as usize] as usize;
        if bci + len > len_bc {
            return Err(BadInstruction);
        }
        let b1 = if len >= 2 { self.byte(bci + 1) } else { 0 };
        let w1 = if len >= 3 { self.u16_at(bci + 1) } else { 0 };
        match op {
            LOAD_LOCAL => self.op_load_local(b1, len),
            LOAD_LOCAL_WIDE => self.op_load_local(w1, len),
            POP_LOAD_LOCAL => {
                let v = self.at(b1 + 1)?;
                if !is_value(v) || !is_value(self.at(0)?) { return Err(FrameWord); }
                self.put(0, v);
                self.next(2)
            }
            STORE_LOCAL => {
                let t = self.at(b1)?;
                let v = self.at(0)?;
                if !is_value(t) || !is_value(v) { return Err(FrameWord); }
                self.put(b1, v);
                self.next(2)
            }
            STORE_LOCAL_POP => {
                if b1 < 1 { return Err(StackRange); }
                let t = self.at(b1)?;
                let v = self.at(0)?;
                if !is_value(t) || !is_value(v) { return Err(FrameWord); }
                self.drop_n(1)?;
                self.put(b1 - 1, v);
                self.next(2)
            }
            LOAD_OUTER => {
                let h = match self.at(0)? { Value::Block(h) => h, _ => return Err(NotBlock) };
                self.drop_n(1)?;
                let i = h as i64 - 1 - b1 as i64;
                if !(0 <= i && (i as usize) < self.s.stack.len()) { return Err(StackRange); }
                let v = self.s.stack[i as usize];
                if !is_value(v) { return Err(FrameWord); }
                self.push(v);
                self.next(2)
            }
            STORE_OUTER => {
                let v = self.at(0)?;
                let h = match self.at(1)? { Value::Block(h) => h, _ => return Err(NotBlock) };
                self.drop_n(2)?;
                let i = h as i64 - 1 - b1 as i64;
                if !(0 <= i && (i as usize) < self.s.stack.len()) { return Err(StackRange); }
                if !is_value(self.s.stack[i as usize]) || !is_value(v) { return Err(FrameWord); }
                self.s.stack[i as usize] = v;
                self.push(v);
                self.next(2)
            }
            LOAD_FIELD => self.op_load_field(b1, len),
            LOAD_FIELD_WIDE => self.op_load_field(w1, len),
            LOAD_FIELD_LOCAL => self.op_load_field_local(b1, false),
            POP_LOAD_FIELD_LOCAL => self.op_load_field_local(b1, true),
            STORE_FIELD => self.op_store_field(b1, len, true),
            STORE_FIELD_WIDE => self.op_store_field(w1, len, true),
            STORE_FIELD_POP => self.op_store_field(b1, len, false),
            LOAD_LOCAL_0..=LOAD_LOCAL_5 => self.op_load_local((op - LOAD_LOCAL_0) as usize, len),
            LOAD_LITERAL => self.op_load_literal(b1, len),
            LOAD_LITERAL_WIDE => self.op_load_literal(w1, len),
            LOAD_NULL => {
                let n = self.null();
                self.push(n);
                self.next(len)
            }
            LOAD_SMI_0 => self.op_load_smi(0, len),
            LOAD_SMIS_0 => {
                for _ in 0..b1 { self.push(Value::Smi(0)); }
                self.next(2)
            }
            LOAD_SMI_1 => self.op_load_smi(1, len),
            LOAD_SMI_U8 => self.op_load_smi(b1 as i128, len),
            LOAD_SMI_U16 => self.op_load_smi(w1 as i128, len),
            LOAD_SMI_U32 | LOAD_METHOD => self.op_load_smi(self.u32_at(bci + 1) as i128, len),
            LOAD_GLOBAL_VAR => self.op_load_global(b1, len),
            LOAD_GLOBAL_VAR_WIDE => self.op_load_global(w1, len),
            LOAD_GLOBAL_VAR_LAZY => self.op_load_global_lazy(b1, len),
            LOAD_GLOBAL_VAR_LAZY_WIDE => self.op_load_global_lazy(w1, len),
            LOAD_GLOBAL_VAR_DYNAMIC => {
                let g = match self.at(0)? { Value::Smi(g) => g as i32 as i64, _ => return Err(NotSmi) };
                self.drop_n(1)?;
                if !(0 <= g && (g as usize) < self.s.globals.len()) {
                    self.push(Value::Smi(bci as i64));
                    return self.call_entry(PROGRAM_FAILURE, 1);
                }
                let v = self.s.globals[g as usize];
                self.push(v);
                self.next(1)
            }
            STORE_GLOBAL_VAR => self.op_store_global(b1, len),
            STORE_GLOBAL_VAR_WIDE => self.op_store_global(w1, len),
            STORE_GLOBAL_VAR_DYNAMIC => {
                let v = self.at(0)?;
                let g = match self.at(1)? { Value::Smi(g) => g as i32 as i64, _ => return Err(NotSmi) };
                self.drop_n(2)?;
                if !(0 <= g && (g as usize) < self.s.globals.len()) {
                    self.push(Value::Smi(bci as i64));
                    return self.call_entry(PROGRAM_FAILURE, 1);
                }
                if !is_value(v) { return Err(FrameWord); }
                self.s.globals[g as usize] = v;
                self.next(1)
            }
            LOAD_BLOCK => {
                self.at(b1)?;
                let h = self.s.stack.len() - b1;
                self.push(Value::Block(h));
                self.next(2)
            }
            LOAD_OUTER_BLOCK => {
                let h = match self.at(0)? { Value::Block(h) => h, _ => return Err(NotBlock) };
                if (h as i64) - (b1 as i64) < 1 || h > self.s.stack.len() - 1 { return Err(StackRange); }
                self.drop_n(1)?;
                self.push(Value::Block(h - b1));
                self.next(2)
            }
            POP => {
                self.drop_n(b1)?;
                self.next(len)
            }
            POP_1 => {
                self.drop_n(1)?;
                self.next(len)
            }
            ALLOCATE => self.op_allocate(b1, len),
            ALLOCATE_WIDE => self.op_allocate(w1, len),
            IS_CLASS => self.op_is(b1, false, len),
            IS_CLASS_WIDE => self.op_is(w1, false, len),
            IS_INTERFACE => self.op_is(b1, true, len),
            IS_INTERFACE_WIDE => self.op_is(w1, true, len),
            AS_CLASS => self.op_as(b1, false, len),
            AS_CLASS_WIDE => self.op_as(w1, false, len),
            AS_INTERFACE => self.op_as(b1, true, len),
            AS_INTERFACE_WIDE => self.op_as(w1, true, len),
            AS_LOCAL => {
                let local = b1 / 32;
                let v = self.at(local)?;
                match self.typecheck_class(v, b1 % 32, false)? {
                    true => self.next(2),
                    false => {
                        if !is_value(v) { return Err(FrameWord); }
                        self.push(v);
                        self.push(Value::Smi((bci + 2) as i64));
                        self.call_entry(AS_CHECK_FAILURE, 2)
                    }
                }
            }
            INVOKE_STATIC => {
                let t = self.dispatch_target(w1);
                self.call(t, 3)
            }
            INVOKE_STATIC_TAIL => {
                let t = self.dispatch_target(w1);
                let (h, a) = (self.byte(bci + 3), self.byte(bci + 4));
                self.tail_call(t, h, a)
            }
            INVOKE_BLOCK => self.op_invoke_block(b1),
            INVOKE_LAMBDA_TAIL => self.op_invoke_lambda_tail(b1),
            INVOKE_INITIALIZER_TAIL => {
                let a = self.byte(bci + 2);
                if b1 < 1 { return Err(StackRange); }
                let m = match self.at(0)? { Value::Smi(m) => m, _ => return Err(NotSmi) };
                self.drop_n(1)?;
                if !self.valid_method(m) { return Err(NotMethod); }
                if self.method_arity(m as usize) != 0 {
                    self.push(Value::Smi(bci as i64));
                    return self.call_entry(PROGRAM_FAILURE, 3);
                }
                self.tail_call(m, b1 - 1, a)
            }
            INVOKE_VIRTUAL => {
                let recv = self.at(b1)?;
                self.invoke_virtual(recv, self.u16_at(bci + 2) as i64, len)
            }
            INVOKE_VIRTUAL_WIDE => {
                let recv = self.at(w1)?;
                self.invoke_virtual(recv, self.u16_at(bci + 3) as i64, len)
            }
            INVOKE_VIRTUAL_GET => self.op_invoke_virtual_get(w1 as i64),
            INVOKE_VIRTUAL_SET => self.op_invoke_virtual_set(w1 as i64),
            INVOKE_EQ..=INVOKE_AT_PUT => {
                let (a1, a0) = (self.at(0)?, self.at(1)?);
                if !is_value(a0) || !is_value(a1) { return Err(StackRange); }
                match op {
                    INVOKE_EQ => self.op_invoke_eq(a0, a1),
                    INVOKE_LT..=INVOKE_GTE => self.op_invoke_relational(op, a0, a1),
                    INVOKE_AT => match self.fast_at(a0, a1, false, self.null(), 8)? {
                        FastAt::Get(v) => self.binary_result(v),
                        _ => self.fallback(op),
                    },
                    INVOKE_AT_PUT => self.op_invoke_at_put(),
                    _ => self.op_invoke_arith(op, a0, a1),
                }
            }
            INVOKE_SIZE => {
                let recv = self.at(0)?;
                match self.fast_size(recv)? {
                    Some(n) => {
                        self.put(0, Value::Smi(n));
                        self.next(3)
                    }
                    None => self.op_invoke_virtual_get(w1 as i64),
                }
            }
            BRANCH => self.op_branch(0, bci as i64 + w1 as i64, len),
            BRANCH_IF_TRUE => self.op_branch(1, bci as i64 + w1 as i64, len),
            BRANCH_IF_FALSE => self.op_branch(2, bci as i64 + w1 as i64, len),
            BRANCH_IF_NOT_NULL => self.op_branch(3, bci as i64 + w1 as i64, len),
            BRANCH_BACK => self.op_branch(0, bci as i64 - w1 as i64, len),
            BRANCH_BACK_IF_TRUE => self.op_branch(1, bci as i64 - w1 as i64, len),
            BRANCH_BACK_IF_FALSE => self.op_branch(2, bci as i64 - w1 as i64, len),
            BRANCH_BACK_IF_NOT_NULL => self.op_branch(3, bci as i64 - w1 as i64, len),
            PRIMITIVE => Ok(Step::Primitive(self.p.bytecodes[bci + 1], self.u16_at(bci + 2) as u16)),
            THROW => {
                self.at(0)?;
                self.push(Value::Block(0));
                self.push(Value::Smi(-2));
                self.unwind()
            }
            RETURN => self.op_return(b1, self.byte(bci + 2), false),
            RETURN_NULL => self.op_return(b1, self.byte(bci + 2), true),
            NON_LOCAL_RETURN => self.op_non_local_return(b1 % 16, b1 / 16),
            NON_LOCAL_RETURN_WIDE => self.op_non_local_return(w1, self.u16_at(bci + 3)),
            NON_LOCAL_BRANCH => {
                let abs = self.u32_at(bci + 2) as i128;
                let b = self.at(0)?;
                if !matches!(b, Value::Block(_)) { return Err(NotBlock); }
                if !self.smi_ok(abs * 2 + 1) { return Err(SmiRange); }
                self.drop_n(1)?;
                self.push(Value::Smi(b1 as i64));
                self.push(b);
                self.push(Value::Smi((abs * 2 + 1) as i64));
                self.unwind()
            }
            IDENTICAL => {
                let (a1, a0) = (self.at(0)?, self.at(1)?);
                if !is_value(a0) || !is_value(a1) { return Err(StackRange); }
                let r = self.identical(a0, a1);
                self.binary_result(self.boolean(r))
            }
            LINK => {
                let try_h = self.s.try_h;
                self.push(Value::Smi(0xbeef));
                self.push(Value::Smi(-0xdead));
                self.push(Value::Smi(-1));
                self.push(Value::Link(try_h));
                self.s.try_h = self.s.stack.len();
                self.next(2)
            }
            UNLINK => match self.at(0)? {
                Value::Link(h) => {
                    self.drop_n(1)?;
                    self.s.try_h = h;
                    self.next(2)
                }
                _ => Err(NotLink),
            },
            UNWIND => self.unwind(),
            HALT => match b1 {
                0 => {
                    self.push(Value::Smi(91));
                    self.s.bci += 2;
                    Ok(Step::Halt(Halt::Yield))
                }
                1 => match self.at(0)? {
                    Value::Smi(v) => {
                        self.drop_n(1)?;
                        self.s.bci += 2;
                        Ok(Step::Halt(Halt::Exit(v)))
                    }
                    _ => Err(NotSmi),
                },
                2 => {
                    self.at(0)?;
                    self.drop_n(1)?;
                    self.s.bci += 2;
                    Ok(Step::Halt(Halt::DeepSleep))
                }
                _ => {
                    self.s.bci += 2;
                    Ok(Step::Halt(Halt::Reset))
                }
            },
            INTRINSIC_SMI_REPEAT => self.op_smi_repeat(),
            INTRINSIC_ARRAY_DO => self.op_array_do(),
            INTRINSIC_HASH_FIND => self.op_hash_find(),
            _ => self.op_hash_do(),
        }
    }

    fn op_load_local(&mut self, n: usize, len: usize) -> R {
        let v = self.at_value(n)?;
        self.push(v);
        self.next(len)
    }

    fn field_ok(&self, inst: Value, f: usize) -> Result<(), Stuck> {
        match self.fields(inst) {
            None => Err(NotInstance),
            Some(fs) if f >= fs.len() => Err(FieldRange),
            _ => Ok(()),
        }
    }

    fn op_load_field(&mut self, f: usize, len: usize) -> R {
        let inst = self.at(0)?;
        self.field_ok(inst, f)?;
        let v = self.fields(inst).unwrap()[f];
        self.put(0, v);
        self.next(len)
    }

    fn op_load_field_local(&mut self, enc: usize, pop: bool) -> R {
        let (local, f) = (enc % 16, enc / 16);
        let slot = if pop { local + 1 } else { local };
        let inst = self.at(slot)?;
        if pop { self.at(0)?; }
        self.field_ok(inst, f)?;
        let v = self.fields(inst).unwrap()[f];
        if pop { self.put(0, v) } else { self.push(v) }
        self.next(2)
    }

    fn op_store_field(&mut self, f: usize, len: usize, keep: bool) -> R {
        let v = self.at(0)?;
        let inst = self.at(1)?;
        self.field_ok(inst, f)?;
        if self.obj(inst).unwrap().ro { return Err(ReadOnly); }
        if !is_value(v) { return Err(FrameWord); }
        self.drop_n(2)?;
        self.set_field(inst, f, v);
        if keep { self.push(v); }
        self.next(len)
    }

    fn op_load_literal(&mut self, i: usize, len: usize) -> R {
        let v = *self.p.literals.get(i).ok_or(TableRange)?;
        self.push(v);
        self.next(len)
    }

    fn op_load_smi(&mut self, v: i128, len: usize) -> R {
        let w = self.smi_wrap(v);
        self.push(Value::Smi(w));
        self.next(len)
    }

    fn op_load_global(&mut self, g: usize, len: usize) -> R {
        let v = *self.s.globals.get(g).ok_or(TableRange)?;
        self.push(v);
        self.next(len)
    }

    fn op_load_global_lazy(&mut self, g: usize, len: usize) -> R {
        let v = *self.s.globals.get(g).ok_or(TableRange)?;
        if self.fields(v).is_some() && self.is_class(v, LAZY_INITIALIZER_CLASS) {
            self.push(Value::Smi(g as i64));
            self.push(v);
            self.call_entry(RUN_GLOBAL_INITIALIZER, len)
        } else {
            self.push(v);
            self.next(len)
        }
    }

    fn op_store_global(&mut self, g: usize, len: usize) -> R {
        if g >= self.s.globals.len() { return Err(TableRange); }
        let v = self.at_value(0)?;
        self.s.globals[g] = v;
        self.next(len)
    }

    fn op_allocate(&mut self, c: usize, len: usize) -> R {
        let bits = *self.p.class_bits.get(c).ok_or(TableRange)?;
        let words = ((bits >> 5) & 0x7ff) as i64;
        if bits & 0xf != 2 || words < 1 { return Err(NotInstantiable); }
        let null = self.null();
        let o = ExecObj { class_id: c as u16, ro: false, body: ExecBody::Instance(vec![null; (words - 1) as usize]) };
        let r = self.alloc(o);
        self.push(r);
        self.next(len)
    }

    pub fn typecheck_class(&self, v: Value, ci: usize, nullable: bool) -> Result<bool, Stuck> {
        if nullable && v == self.null() { return Ok(true); }
        let cid = self.class_id_of(v)?;
        if 2 * ci + 1 >= self.p.class_check_ids.len() { return Err(TableRange); }
        Ok(self.p.class_check_ids[2 * ci] as i64 <= cid && cid < self.p.class_check_ids[2 * ci + 1] as i64)
    }

    pub fn typecheck_interface(&self, v: Value, ii: usize, nullable: bool) -> Result<bool, Stuck> {
        if nullable && v == self.null() { return Ok(true); }
        let sel = *self.p.interface_check_offsets.get(ii).ok_or(TableRange)? as i64;
        Ok(self.find_method(v, sel)?.is_some())
    }

    fn op_is(&mut self, enc: usize, interface: bool, len: usize) -> R {
        let v = self.at(0)?;
        let ok = if interface {
            self.typecheck_interface(v, enc / 2, enc % 2 == 1)?
        } else {
            self.typecheck_class(v, enc / 2, enc % 2 == 1)?
        };
        self.put(0, self.boolean(ok));
        self.next(len)
    }

    fn op_as(&mut self, enc: usize, interface: bool, len: usize) -> R {
        let v = self.at(0)?;
        let ok = if interface {
            self.typecheck_interface(v, enc / 2, enc % 2 == 1)?
        } else {
            self.typecheck_class(v, enc / 2, enc % 2 == 1)?
        };
        if ok {
            self.next(len)
        } else {
            self.push(Value::Smi((self.s.bci + len) as i64));
            self.call_entry(AS_CHECK_FAILURE, len)
        }
    }

    fn dispatch_target(&self, d: usize) -> i64 {
        self.p.dispatch.get(d).map(|t| *t as i64).unwrap_or(-1)
    }

    fn tail_call(&mut self, target: i64, h: usize, a: usize) -> R {
        if !self.valid_method(target) { return Err(NotMethod); }
        let call_arity = self.method_arity(target as usize);
        let len = self.s.stack.len();
        if h + 1 >= len || len < h + 2 + a { return Err(StackRange); }
        let ret = match (self.at(h)?, self.at(h + 1)?) {
            (Value::FrameMarker, Value::RetAddr(r)) => r,
            _ => return Err(BadFrame),
        };
        if call_arity > h { return Err(FrameWord); }
        let args: Vec<Value> = self.s.stack[len - call_arity..].to_vec();
        self.s.stack.truncate(len - (h + 2 + a));
        self.s.stack.extend(args);
        self.call_with(target, ret)
    }

    fn op_invoke_block(&mut self, n: usize) -> R {
        if n < 1 { return Err(StackRange); }
        let b = self.at(n - 1)?;
        if !matches!(b, Value::Block(_)) { return Err(NotBlock); }
        let target = self.block_method(b)?;
        let arity = self.method_arity(target);
        if n < arity {
            self.push(self.true_v());
            self.push(Value::Smi(arity as i64));
            self.push(Value::Smi(n as i64));
            self.push(Value::Smi(target as i64 + 4));
            self.call_entry(CODE_FAILURE, 2)
        } else {
            self.drop_n(n - arity)?;
            self.call(target as i64, 2)
        }
    }

    fn op_invoke_lambda_tail(&mut self, k: usize) -> R {
        let recv = self.at(k + 2)?;
        let fs = self.fields(recv).ok_or(NotInstance)?;
        if fs.len() < 2 { return Err(FieldRange); }
        let (mid, argument) = (fs[0], fs[1]);
        let target = match mid { Value::Smi(m) if self.valid_method(m) => m as usize, _ => return Err(NotMethod) };
        let captured: Vec<Value> = match self.obj(argument) {
            Some(ExecObj { body: ExecBody::Array(e), .. }) => e.clone(),
            _ => vec![argument],
        };
        let user_arity = self.method_arity(target) as i64 - captured.len() as i64;
        if user_arity < 0 { return Err(StackRange); }
        let user_arity = user_arity as usize;
        if k < user_arity {
            self.push(self.false_v());
            self.push(Value::Smi(user_arity as i64));
            self.push(Value::Smi(k as i64));
            self.push(Value::Smi(target as i64 + 4));
            return self.call_entry(CODE_FAILURE, 2);
        }
        let ret = match (self.at(0)?, self.at(1)?) {
            (Value::FrameMarker, Value::RetAddr(r)) => r,
            _ => return Err(BadFrame),
        };
        let n = self.s.stack.len() - 2;
        let args: Vec<Value> = self.s.stack[n - k..n - k + user_arity].to_vec();
        self.s.stack.truncate(n - (k + 1));
        self.s.stack.extend(args);
        self.s.stack.extend(captured);
        self.call_with(target as i64, ret)
    }

    fn op_invoke_virtual_get(&mut self, sel: i64) -> R {
        let recv = self.at(0)?;
        match self.find_method(recv, sel)? {
            None => {
                self.push(recv);
                self.push(Value::Smi(sel));
                self.call_entry(LOOKUP_FAILURE, 3)
            }
            Some(t) if self.method_kind(t) == 1 => {
                let e = t + 4;
                if e + 4 > self.p.bytecodes.len() { return Err(BadInstruction); }
                let f = if self.p.bytecodes[e] == LOAD_FIELD_LOCAL { self.byte(e + 1) / 16 } else { self.byte(e + 2) };
                self.field_ok(recv, f)?;
                let v = self.fields(recv).unwrap()[f];
                self.put(0, v);
                self.next(3)
            }
            Some(t) => self.call(t as i64, 3),
        }
    }

    fn op_invoke_virtual_set(&mut self, sel: i64) -> R {
        let recv = self.at(1)?;
        match self.find_method(recv, sel)? {
            None => {
                self.push(recv);
                self.push(Value::Smi(sel));
                self.call_entry(LOOKUP_FAILURE, 3)
            }
            Some(t) if self.method_kind(t) == 1 => {
                let e = t + 4;
                if e + 5 > self.p.bytecodes.len() { return Err(BadInstruction); }
                let f = self.byte(e + 3);
                let v = self.at(0)?;
                self.field_ok(recv, f)?;
                if self.obj(recv).unwrap().ro { return Err(ReadOnly); }
                if !is_value(v) { return Err(FrameWord); }
                self.set_field(recv, f, v);
                self.put(1, v);
                self.drop_n(1)?;
                self.next(3)
            }
            Some(t) => self.call(t as i64, 3),
        }
    }

    pub fn binary_result(&mut self, r: Value) -> R {
        self.put(1, r);
        self.drop_n(1)?;
        self.next(1)
    }

    pub fn double_bits(&self, v: Value) -> Option<u64> {
        match self.obj(v) {
            Some(ExecObj { body: ExecBody::Double(b), .. }) => Some(*b),
            _ => None,
        }
    }

    pub fn large_int(&self, v: Value) -> Option<i64> {
        match self.obj(v) {
            Some(ExecObj { body: ExecBody::LargeInt(i), .. }) => Some(*i),
            _ => None,
        }
    }

    pub fn str_bytes(&self, v: Value) -> Option<&Vec<u8>> {
        match self.obj(v) {
            Some(ExecObj { body: ExecBody::Str(b), .. }) => Some(b),
            _ => None,
        }
    }

    pub fn identical(&self, a: Value, b: Value) -> bool {
        if a == b { return true; }
        if let (Some(x), Some(y)) = (self.double_bits(a), self.double_bits(b)) { return x == y; }
        if let (Some(x), Some(y)) = (self.large_int(a), self.large_int(b)) { return x == y; }
        if let (Some(x), Some(y)) = (self.str_bytes(a), self.str_bytes(b)) { return x == y; }
        false
    }

    fn num_of(&self, v: Value) -> Option<Num> {
        match v {
            Value::Smi(i) => Some(Num::Int(i)),
            Value::Obj(_) => {
                if let Some(i) = self.large_int(v) { Some(Num::Int(i)) }
                else { self.double_bits(v).map(Num::Dbl) }
            }
            _ => None,
        }
    }

    pub fn compare_numbers(&self, a: Value, b: Value) -> u8 {
        match (self.num_of(a), self.num_of(b)) {
            (Some(Num::Int(x)), Some(Num::Int(y))) => compare_ints(x, y),
            (Some(x), Some(y)) => compare_mixed(x, y),
            _ => 0,
        }
    }

    fn op_invoke_eq(&mut self, a0: Value, a1: Value) -> R {
        if a0 == a1 {
            let nan = self.double_bits(a0).map(|b| f64::from_bits(b).is_nan()).unwrap_or(false);
            return self.binary_result(self.boolean(!nan));
        }
        if a0 == self.null() || a1 == self.null() {
            return self.binary_result(self.false_v());
        }
        if let (Value::Smi(x), Value::Smi(y)) = (a0, a1) {
            return self.binary_result(self.boolean(x == y));
        }
        let c = self.compare_numbers(a0, a1);
        if c != 0 {
            return self.binary_result(self.boolean(c & 32 != 0));
        }
        self.fallback(INVOKE_EQ)
    }

    fn op_invoke_relational(&mut self, op: u8, a0: Value, a1: Value) -> R {
        if let (Value::Smi(x), Value::Smi(y)) = (a0, a1) {
            let r = match op { INVOKE_LT => x < y, INVOKE_LTE => x <= y, INVOKE_GT => x > y, _ => x >= y };
            return self.binary_result(self.boolean(r));
        }
        let c = self.compare_numbers(a0, a1);
        if c != 0 {
            let flag = match op { INVOKE_LT => 8, INVOKE_LTE => 16, INVOKE_GT => 128, _ => 64 };
            return self.binary_result(self.boolean(c & flag != 0));
        }
        self.fallback(op)
    }

    pub fn smi_arith(&self, op: u8, a: i64, b: i64) -> Option<i64> {
        let (a2, b2) = (a as i128, b as i128);
        let wbs = self.word_bit_size();
        let r: i128 = match op {
            INVOKE_BIT_OR => (a | b) as i128,
            INVOKE_BIT_XOR => (a ^ b) as i128,
            INVOKE_BIT_AND => (a & b) as i128,
            INVOKE_ADD => a2 + b2,
            INVOKE_SUB => a2 - b2,
            INVOKE_MUL => a2 * b2,
            INVOKE_DIV => {
                // MIN_SMI / -1 does not fit in a smi: slow path (smi_ok below).
                if b == 0 { return None; }
                a2 / b2
            }
            INVOKE_MOD => {
                if b == 0 { return None; }
                a2 % b2
            }
            INVOKE_BIT_SHL => {
                if !(0 <= b && b < wbs) { return None; }
                let r = (a2).checked_mul(1i128.checked_shl(b as u32)?)?;
                r
            }
            INVOKE_BIT_SHR => {
                if !(0 <= b && b < wbs) { return None; }
                (a >> b) as i128
            }
            _ => {
                if !(0 <= b && b < wbs) || a < 0 { return None; }
                (a >> b) as i128
            }
        };
        if self.smi_ok(r) { Some(r as i64) } else { None }
    }

    fn op_invoke_arith(&mut self, op: u8, a0: Value, a1: Value) -> R {
        if let (Value::Smi(x), Value::Smi(y)) = (a0, a1) {
            if let Some(r) = self.smi_arith(op, x, y) {
                return self.binary_result(Value::Smi(r));
            }
        }
        if matches!(op, INVOKE_ADD | INVOKE_SUB | INVOKE_MUL) {
            if let (Some(x), Some(y)) = (self.double_bits(a0), self.double_bits(a1)) {
                let bits = float_arith(op, x, y);
                let d = ExecObj { class_id: self.builtin(DOUBLE_CLASS), ro: false, body: ExecBody::Double(bits) };
                let r = self.alloc(d);
                return self.binary_result(r);
            }
        }
        self.fallback(op)
    }

    fn op_invoke_at_put(&mut self) -> R {
        let v = self.at(0)?;
        let arg = self.at(1)?;
        let recv = self.at(2)?;
        if !is_value(v) { return Err(FrameWord); }
        match self.fast_at(recv, arg, true, v, 8)? {
            FastAt::Put(r) => {
                self.put(2, r);
                self.drop_n(2)?;
                self.next(1)
            }
            _ => {
                self.push(recv);
                self.virtual_fallback(INVOKE_AT_PUT)
            }
        }
    }

    fn op_branch(&mut self, kind: u8, target: i64, len: usize) -> R {
        let taken = if kind == 0 {
            true
        } else {
            let v = self.at(0)?;
            self.drop_n(1)?;
            match kind { 1 => self.truthy(v), 2 => !self.truthy(v), _ => v != self.null() }
        };
        if taken {
            if !(0 <= target && (target as usize) < self.p.bytecodes.len()) { return Err(BadBranch); }
            self.s.bci = target as usize;
            Ok(Step::Next)
        } else {
            self.next(len)
        }
    }

    pub fn return_to_caller(&mut self, arity: usize, result: Value) -> R {
        let ret = match (self.at(0)?, self.at(1)?) {
            (Value::FrameMarker, Value::RetAddr(r)) => r,
            _ => return Err(BadFrame),
        };
        self.drop_n(2 + arity)?;
        self.push(result);
        self.s.bci = ret;
        Ok(Step::Next)
    }

    fn op_return(&mut self, h: usize, a: usize, null_result: bool) -> R {
        let result = if null_result { self.null() } else { self.at_value(0)? };
        self.drop_n(h)?;
        self.return_to_caller(a, result)
    }

    pub fn unwind(&mut self) -> R {
        self.at(2)?;
        let tos = match self.at(0)? { Value::Smi(t) => t, _ => return Err(NotSmi) };
        let tv = tos as i32 as i64;
        if tv == -1 {
            self.drop_n(3)?;
            return self.next(1);
        }
        let t = match self.at(1)? { Value::Block(t) => t, _ => return Err(NotBlock) };
        let result = self.at(2)?;
        self.drop_n(3)?;
        let th = self.s.try_h;
        if t < th {
            if th < 4 || self.s.stack.len() < th + 3 { return Err(StackRange); }
            self.s.stack.truncate(th + 3);
            self.s.stack[th - 2] = Value::Smi(tos);
            self.s.stack[th - 3] = Value::Block(t);
            self.s.stack[th - 4] = result;
            let ret = match (self.at(0)?, self.at(1)?) {
                (Value::FrameMarker, Value::RetAddr(r)) => r,
                _ => return Err(BadFrame),
            };
            self.drop_n(2)?;
            self.s.bci = ret;
            return Ok(Step::Next);
        }
        if t > self.s.stack.len() { return Err(StackRange); }
        if tv == -2 || tv % 2 == 0 {
            let arity = if tv == -2 { 0 } else { (tv / 2) as usize };
            self.s.stack.truncate(t);
            if let Ok(v) = self.at(0) {
                if v != Value::FrameMarker { return Err(Fatal); }
            }
            self.return_to_caller(arity, result)
        } else {
            let hd = match result { Value::Smi(h) => h, _ => return Err(NotSmi) };
            let target_bci = tv.div_euclid(2);
            self.s.stack.truncate(t);
            if !(0 <= hd && (hd as usize) <= t) { return Err(StackRange); }
            if !(0 <= target_bci && (target_bci as usize) < self.p.bytecodes.len()) { return Err(BadBranch); }
            self.drop_n(hd as usize)?;
            self.s.bci = target_bci as usize;
            Ok(Step::Next)
        }
    }

    fn op_non_local_return(&mut self, arity: usize, h: usize) -> R {
        let b = match self.at(0)? { Value::Block(b) => b, _ => return Err(NotBlock) };
        let result = self.at(1)?;
        let t = b as i64 - h as i64 - 1;
        if t < 0 { return Err(StackRange); }
        if !self.smi_ok(arity as i128 * 2) { return Err(SmiRange); }
        self.drop_n(2)?;
        self.push(result);
        self.push(Value::Block(t as usize));
        self.push(Value::Smi(arity as i64 * 2));
        self.unwind()
    }

    fn op_smi_repeat(&mut self) -> R {
        let bci = self.s.bci;
        self.at(5)?;
        self.drop_n(1)?;
        let block = self.at(3)?;
        let (current, end) = match (self.at(0)?, self.at(4)?) {
            (Value::Smi(c), Value::Smi(e)) => (c, e),
            _ => return Err(NotSmi),
        };
        let target = self.block_method(block).map_err(|_| NotBlock)?;
        let arity = self.method_arity(target);
        if arity > 2 { return self.next(1); }
        if current >= end {
            self.drop_n(1)?;
            return self.return_to_caller(2, self.null());
        }
        self.put(0, Value::Smi(current + 1));
        self.push(block);
        if arity == 2 { self.push(Value::Smi(current)); }
        self.call_with(target as i64, bci)
    }

    fn op_array_do(&mut self) -> R {
        let bci = self.s.bci;
        self.at(6)?;
        self.drop_n(1)?;
        let block = self.at(3)?;
        let backing = self.at(5)?;
        let (current, end) = match (self.at(0)?, self.at(4)?) {
            (Value::Smi(c), Value::Smi(e)) => (c, e),
            _ => return Err(NotSmi),
        };
        let elems = match self.obj(backing) {
            Some(ExecObj { body: ExecBody::Array(e), .. }) => e.len(),
            _ => return Err(NotArray),
        };
        let target = self.block_method(block).map_err(|_| NotBlock)?;
        let arity = self.method_arity(target);
        if arity > 2 { return self.next(1); }
        if current >= end {
            self.drop_n(1)?;
            return self.return_to_caller(3, self.null());
        }
        self.put(0, Value::Smi(current + 1));
        self.push(block);
        if arity == 2 {
            if !(0 <= current && (current as usize) < elems) { return Err(FieldRange); }
            let v = match &self.obj(backing).unwrap().body { ExecBody::Array(e) => e[current as usize], _ => unreachable!() };
            self.push(v);
        }
        self.call_with(target as i64, bci)
    }
}

pub fn is_value(v: Value) -> bool {
    !matches!(v, Value::RetAddr(_) | Value::FrameMarker)
}

#[derive(Clone, Copy)]
pub enum Num {
    Int(i64),
    Dbl(u64),
}

pub fn compare_ints(a: i64, b: i64) -> u8 {
    if a < b { 29 } else if a == b { 114 } else { 195 }
}

/// `Interpreter::compare_numbers` for at least one double, shared with the verified loop.
pub fn compare_mixed(a: Num, b: Num) -> u8 {
    let conv = |n: Num| match n { Num::Int(i) => crate::exec_step::XNum::Int(i), Num::Dbl(d) => crate::exec_step::XNum::Dbl(d) };
    crate::exec_step::x_compare_mixed(conv(a), conv(b))
}

/// Trusted implementation of the uninterpreted `double_add/sub/mul`.
pub fn float_arith(op: u8, a: u64, b: u64) -> u64 {
    let (x, y) = (f64::from_bits(a), f64::from_bits(b));
    let r = match op { INVOKE_ADD => x + y, INVOKE_SUB => x - y, _ => x * y };
    r.to_bits()
}
