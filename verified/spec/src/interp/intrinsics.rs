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

//! Unverified mirrors of `fast_at`, `fast_size`, `hash_do`, and the
//! INTRINSIC_HASH_DO / INTRINSIC_HASH_FIND bytecodes (spec_helpers.rs and
//! spec_step.rs).

use super::*;
use crate::types::Stuck::*;

type R = Result<Step, Stuck>;

pub enum FastAt {
    Fail,
    Get(Value),
    /// Stored; the value to push.
    Put(Value),
}

enum HashDo {
    Return(Value),
    Call(i64, Value),
}

const HASH_FUEL: u64 = 0x1_0000_0000;

impl Machine {
    fn elements(&self, v: Value) -> Option<&Vec<Value>> {
        match self.obj(v) {
            Some(ExecObj { body: ExecBody::Array(e), .. }) => Some(e),
            _ => None,
        }
    }

    fn bytes_len(&self, v: Value) -> Option<usize> {
        match self.obj(v) {
            Some(ExecObj { body: ExecBody::Bytes(b), .. }) => Some(b.len()),
            _ => None,
        }
    }

    fn array_at(&mut self, arr: Value, length: i64, n: i64, is_put: bool, value: Value) -> Result<FastAt, Stuck> {
        let len = self.elements(arr).unwrap().len() as i64;
        if n >= length || n >= len { return Ok(FastAt::Fail); }
        if is_put {
            let o = self.obj_mut(arr).unwrap();
            if o.ro { return Err(ReadOnly); }
            if let ExecBody::Array(e) = &mut o.body { e[n as usize] = value; }
            Ok(FastAt::Put(value))
        } else {
            Ok(FastAt::Get(self.elements(arr).unwrap()[n as usize]))
        }
    }

    fn bytes_at(&mut self, ba: Value, n: i64, is_put: bool, value: Value) -> Result<FastAt, Stuck> {
        let len = self.bytes_len(ba).unwrap() as i64;
        if n >= len { return Ok(FastAt::Fail); }
        if is_put {
            let v = match value { Value::Smi(v) => v, _ => return Ok(FastAt::Fail) };
            let o = self.obj_mut(ba).unwrap();
            if o.ro { return Err(ReadOnly); }
            let b = v.rem_euclid(256);
            if let ExecBody::Bytes(bs) = &mut o.body { bs[n as usize] = b as u8; }
            Ok(FastAt::Put(Value::Smi(b)))
        } else {
            match &self.obj(ba).unwrap().body {
                ExecBody::Bytes(bs) => Ok(FastAt::Get(Value::Smi(bs[n as usize] as i64))),
                _ => unreachable!(),
            }
        }
    }

    fn cow_at(&mut self, cow: Value, n: i64, is_put: bool, value: Value) -> Result<FastAt, Stuck> {
        let f = self.fields(cow).unwrap();
        if f.len() < 2 { return Err(FieldRange); }
        let (backing, mutable) = (f[0], f[1]);
        if is_put && mutable == self.false_v() { return Ok(FastAt::Fail); }
        if self.bytes_len(backing).is_none() { return Ok(FastAt::Fail); }
        self.bytes_at(backing, n, is_put, value)
    }

    pub fn fast_at(&mut self, recv: Value, arg: Value, is_put: bool, value: Value, fuel: u32) -> Result<FastAt, Stuck> {
        let n = match arg { Value::Smi(a) => a, _ => return Ok(FastAt::Fail) };
        if n < 0 { return Ok(FastAt::Fail); }
        if let Some(f) = self.fields(recv) {
            let f = f.clone();
            let cid = self.class_of(recv).unwrap();
            let list = self.builtin(LIST_CLASS);
            if cid == list && f.len() < 2 { return Err(FieldRange); }
            if cid == list && self.elements(f[0]).is_some() {
                return match f[1] {
                    Value::Smi(size) => {
                        if size > self.elements(f[0]).unwrap().len() as i64 { Ok(FastAt::Fail) }
                        else { self.array_at(f[0], size, n, is_put, value) }
                    }
                    _ => Ok(FastAt::Fail),
                };
            }
            if cid == self.builtin(BYTE_ARRAY_SLICE_CLASS) {
                if f.len() < 3 { return Err(FieldRange); }
                return match (f[1], f[2]) {
                    (Value::Smi(from), Value::Smi(to)) => {
                        let m = from + n;
                        if from < 0 || m >= to { Ok(FastAt::Fail) }
                        else if self.bytes_len(f[0]).is_some() { self.bytes_at(f[0], m, is_put, value) }
                        else if self.fields(f[0]).is_some() {
                            if self.class_of(f[0]) != Some(self.builtin(BYTE_ARRAY_COW_CLASS)) { Ok(FastAt::Fail) }
                            else { self.cow_at(f[0], m, is_put, value) }
                        } else { Ok(FastAt::Fail) }
                    }
                    _ => Ok(FastAt::Fail),
                };
            }
            let large = self.builtin(LARGE_ARRAY_CLASS);
            if cid == large || cid == list {
                if f.len() < 2 { return Err(FieldRange); }
                let la = if cid == large { recv } else { f[0] };
                let size_obj = if cid == large { f[0] } else { f[1] };
                if self.fields(la).is_none() || self.class_of(la) != Some(large) { return Ok(FastAt::Fail); }
                let lf = self.fields(la).unwrap();
                if lf.len() < 2 { return Err(FieldRange); }
                let vector = lf[1];
                let size = match size_obj { Value::Smi(s) => s, _ => return Ok(FastAt::Fail) };
                let vector_ok = self.elements(vector).is_some()
                    || (self.class_of(vector) == Some(large)
                        && self.fields(vector).map(|vf| vf.len() >= 1 && matches!(vf[0], Value::Smi(vs) if vs < size)).unwrap_or(false));
                if n >= size || !vector_ok { return Ok(FastAt::Fail); }
                if fuel == 0 { return Err(OutOfFuel); }
                let null = self.null();
                return match self.fast_at(vector, Value::Smi(n / 500), false, null, fuel - 1)? {
                    FastAt::Get(arraylet) => {
                        if self.elements(arraylet).is_none() { Ok(FastAt::Fail) }
                        else { self.fast_at(arraylet, Value::Smi(n % 500), is_put, value, fuel - 1) }
                    }
                    _ => Ok(FastAt::Fail),
                };
            }
            if cid == self.builtin(BYTE_ARRAY_COW_CLASS) {
                return self.cow_at(recv, n, is_put, value);
            }
            return Ok(FastAt::Fail);
        }
        if self.bytes_len(recv).is_some() { return self.bytes_at(recv, n, is_put, value); }
        if let Some(e) = self.elements(recv) {
            let len = e.len() as i64;
            return self.array_at(recv, len, n, is_put, value);
        }
        Ok(FastAt::Fail)
    }

    pub fn fast_size(&self, recv: Value) -> Result<Option<i64>, Stuck> {
        if let Some(f) = self.fields(recv) {
            let cid = self.class_of(recv).unwrap();
            let need = if cid == self.builtin(LIST_CLASS) { 2 }
                else if cid == self.builtin(BYTE_ARRAY_SLICE_CLASS) { 3 }
                else if cid == self.builtin(LARGE_ARRAY_CLASS) || cid == self.builtin(BYTE_ARRAY_COW_CLASS) { 1 }
                else { 0 };
            if f.len() < need { return Err(FieldRange); }
            if cid == self.builtin(LIST_CLASS) {
                return Ok(match f[1] { Value::Smi(s) => Some(s), _ => None });
            }
            if cid == self.builtin(BYTE_ARRAY_SLICE_CLASS) {
                return Ok(match (f[1], f[2]) {
                    (Value::Smi(from), Value::Smi(to)) if 0 <= from && from <= to => Some(to - from),
                    _ => None,
                });
            }
            if cid == self.builtin(LARGE_ARRAY_CLASS) {
                return Ok(match f[0] { Value::Smi(s) => Some(s), _ => None });
            }
            if cid == self.builtin(BYTE_ARRAY_COW_CLASS) {
                return Ok(self.bytes_len(f[0]).map(|l| l as i64));
            }
            return Ok(None);
        }
        if let Some(l) = self.bytes_len(recv) { return Ok(Some(l as i64)); }
        if let Some(e) = self.elements(recv) { return Ok(Some(e.len() as i64)); }
        Ok(None)
    }

    fn hash_do_loop(&mut self, backing: Value, step: i64, mut c: i64) -> Result<HashDo, Stuck> {
        let mut first_tombstone: i64 = -1;
        let mut first_obj = self.null();
        let mut skipped: i64 = 0;
        let tombstone = self.builtin(TOMBSTONE_CLASS);
        let mut fuel = HASH_FUEL;
        loop {
            if fuel == 0 { return Err(OutOfFuel); }
            fuel -= 1;
            if !self.smi_ok(c as i128) { return Err(SmiRange); }
            let null = self.null();
            let entry = match self.fast_at(backing, Value::Smi(c), false, null, 8)? {
                FastAt::Get(e) => e,
                _ => return Ok(HashDo::Return(null)),
            };
            self.class_id_of(entry)?;
            let is_tomb = matches!(entry, Value::Obj(_)) && self.class_of(entry) == Some(tombstone);
            if !is_tomb {
                if first_tombstone != -1 && skipped > 10 {
                    let f = self.fields(first_obj).ok_or(FieldRange)?;
                    if f.is_empty() { return Err(FieldRange); }
                    let distance = f[0];
                    let new_distance = c - first_tombstone;
                    if !matches!(distance, Value::Smi(_)) || distance == Value::Smi(0) || !self.smi_ok(new_distance as i128) {
                        return Ok(HashDo::Return(Value::Smi(first_tombstone)));
                    }
                    if self.obj(first_obj).unwrap().ro { return Err(ReadOnly); }
                    self.set_field_pub(first_obj, 0, Value::Smi(new_distance));
                }
                return Ok(HashDo::Call(c, entry));
            }
            let f = self.fields(entry).ok_or(FieldRange)?;
            if f.is_empty() { return Err(FieldRange); }
            let skip = f[0];
            if first_tombstone == -1 {
                first_tombstone = c;
                first_obj = entry;
                skipped = 0;
            } else {
                skipped += 1;
            }
            match skip {
                Value::Smi(d) if d != 0 && ((d >= 0) == (step >= 0)) => c += d,
                _ => c += step,
            }
        }
    }

    pub fn set_field_pub(&mut self, inst: Value, f: usize, v: Value) {
        if let Some(ExecObj { body: ExecBody::Instance(fs), .. }) = self.obj_mut(inst) {
            fs[f] = v;
        }
    }

    fn hash_do_start(&mut self, backing: Value, step: i64, block: Value, c: i64) -> Result<HashDo, Stuck> {
        let m = self.block_method(block).map_err(|_| NotBlock)?;
        let arity = self.method_arity(m);
        let ok = if step.rem_euclid(2) != 0 { arity == 2 } else { 2 <= arity && arity <= 3 };
        if !ok { return Ok(HashDo::Return(Value::Smi(c))); }
        self.hash_do_loop(backing, step, c)
    }

    fn hash_do(&mut self, current: Value, backing: Value, step: i64, block: Value) -> Result<HashDo, Stuck> {
        if let Value::Smi(c) = current {
            return self.hash_do_loop(backing, step, c + step);
        }
        if self.fields(backing).is_none() {
            return match self.elements(backing) {
                None => Ok(HashDo::Return(self.null())),
                Some(e) => {
                    let c = if step < 0 { e.len() as i64 + step } else { 0 };
                    self.hash_do_start(backing, step, block, c)
                }
            };
        }
        if self.class_of(backing) != Some(self.builtin(LIST_CLASS)) {
            return Ok(HashDo::Return(self.null()));
        }
        if step < 0 {
            let f = self.fields(backing).unwrap();
            if f.len() < 2 { return Err(FieldRange); }
            return match f[1] {
                Value::Smi(size) => self.hash_do_start(backing, step, block, size + step),
                _ => Ok(HashDo::Return(self.null())),
            };
        }
        self.hash_do_start(backing, step, block, 0)
    }

    pub fn op_hash_do(&mut self) -> R {
        let bci = self.s.bci;
        self.at(7)?;
        self.drop_n(1)?;
        let collection = self.at(6)?;
        let block = self.at(3)?;
        let f = self.fields(collection).ok_or(NotInstance)?;
        if f.len() < 4 { return Err(FieldRange); }
        let backing = f[3];
        let step0 = match self.at(5)? { Value::Smi(s) => s as i32 as i64, _ => return Err(NotSmi) };
        let step = if self.at(4)? == self.true_v() { -step0 } else { step0 };
        let current = self.at(0)?;
        match self.hash_do(current, backing, step, block)? {
            HashDo::Call(c, entry) => {
                self.put(0, Value::Smi(c));
                let target = self.block_method(block).map_err(|_| NotBlock)?;
                self.push(block);
                self.push(entry);
                if self.method_arity(target) > 2 {
                    let null = self.null();
                    let v = match self.fast_at(backing, Value::Smi(c + 1), false, null, 8) {
                        Ok(FastAt::Get(v)) => v,
                        _ => null,
                    };
                    self.push(v);
                }
                self.call_with(target as i64, bci)
            }
            HashDo::Return(v) => {
                self.drop_n(1)?;
                self.return_to_caller(4, v)
            }
        }
    }

    fn smi_at(&self, n: usize) -> Result<i64, Stuck> {
        match self.at(n)? { Value::Smi(v) => Ok(v), _ => Err(NotSmi) }
    }

    fn hf_bail(&mut self, bci: usize) -> R {
        self.drop_n(6)?;
        self.s.bci = bci + 1;
        Ok(Step::Next)
    }

    fn hf_return(&mut self, result: Value) -> R {
        self.drop_n(7)?;
        self.return_to_caller(7, result)
    }

    fn index_get(&mut self, index: Value, slot: i64) -> Option<i64> {
        if let Some(e) = self.elements(index) {
            if 0 <= slot && (slot as usize) < e.len() {
                if let Value::Smi(v) = e[slot as usize] { return Some(v); }
            }
            return None;
        }
        let null = self.null();
        match self.fast_at(index, Value::Smi(slot), false, null, 8) {
            Ok(FastAt::Get(Value::Smi(v))) => Some(v),
            _ => None,
        }
    }

    pub fn op_hash_find(&mut self) -> R {
        let bci = self.s.bci;
        self.at(16)?;
        let block_result = self.at(0)?;
        self.drop_n(1)?;
        let state = self.smi_at(0)?;
        if state == 2 {
            self.put(12, block_result);
            self.put(0, Value::Smi(0));
            let rb = self.at(10)?;
            let target = self.block_method(rb).map_err(|_| NotBlock)?;
            self.push(rb);
            let v = self.at(1)?;  // Faithful to the C++ VM: the state slot.
            self.push(v);
            return self.call_with(target as i64, bci);
        }
        let coll = self.at(15)?;
        let hash_obj = self.at(13)?;
        let cf = self.fields(coll).ok_or(NotInstance)?.clone();
        if cf.len() < 4 { return Err(FieldRange); }
        if state == 0 || state == 3 {
            let nf = self.block_method(self.at(11)?).map_err(|_| NotBlock)?;
            let rb = self.block_method(self.at(10)?).map_err(|_| NotBlock)?;
            let cb = self.block_method(self.at(9)?).map_err(|_| NotBlock)?;
            if !matches!(cf[1], Value::Smi(_)) || !matches!(hash_obj, Value::Smi(_)) || !matches!(cf[0], Value::Smi(_))
                || self.method_arity(nf) != 1 || self.method_arity(rb) != 2 || self.method_arity(cb) != 3 {
                return self.hf_bail(bci);
            }
        }
        let index = cf[2];
        let large = self.builtin(LARGE_ARRAY_CLASS);
        let (_, smi_max) = loader::smi_range(self.p.word_bits);
        let mask = if let Some(e) = self.elements(index) {
            e.len() as i64 - 1
        } else {
            match self.fields(index) {
                Some(f) if self.class_of(index) == Some(large) && !f.is_empty() => match f[0] {
                    Value::Smi(sz) if sz - 1 < smi_max / 4096 => sz - 1,
                    _ => return self.hf_bail(bci),
                },
                _ => return self.hf_bail(bci),
            }
        };
        let hash = match hash_obj { Value::Smi(h) => h, _ => return Err(NotSmi) };
        if state == 1 {
            // NOT_FOUND: enter the new entry into the index (hf_not_found).
            self.put(12, block_result);
            let (ap, deleted) = match (block_result, self.at(2)?) {
                (Value::Smi(a), Value::Smi(d)) => (a, d),
                _ => return Err(NotSmi),
            };
            let new_hap = (ap as i128 + 1) * 4096 + (hash & 0xfff) as i128;
            if !self.smi_ok(new_hap) { return Err(NotSmi); }
            let idx = if deleted < 0 {
                let (slot, left) = match (self.at(3)?, self.fields(coll).unwrap()[1]) {
                    (Value::Smi(s), Value::Smi(l)) => (s, l),
                    _ => return Err(NotSmi),
                };
                let w = self.smi_wrap(left as i128 - 1);
                self.set_field_pub(coll, 1, Value::Smi(w));
                slot & mask
            } else {
                deleted & mask
            };
            if self.obj(coll).unwrap().ro { return Err(NotSmi); }
            if let Some(e) = self.elements(index) {
                if !(0 <= idx && (idx as usize) < e.len()) || self.obj(index).unwrap().ro { return Err(NotSmi); }
                if let ExecBody::Array(e) = &mut self.obj_mut(index).unwrap().body { e[idx as usize] = Value::Smi(new_hap as i64); }
            } else if self.fast_at(index, Value::Smi(idx), true, Value::Smi(new_hap as i64), 8).is_err() {
                return Err(NotSmi);
            }
            return self.hf_return(Value::Smi(-1));
        }
        if state == 3 && self.truthy(block_result) {
            let r = if matches!(self.at(12)?, Value::Smi(_)) { Value::Smi(-1) } else { self.at(4)? };
            return self.hf_return(r);
        }
        let (mut slot, mut step, starting, mut inc) = if state == 0 {
            self.put(2, Value::Smi(-1));
            let slot = hash & mask;
            (slot, 1i64, slot, false)
        } else {
            let (sl, start, stp) = (self.smi_at(3)?, self.smi_at(6)?, self.smi_at(5)?);
            (sl & mask, stp, start, true)
        };
        let tombstone = self.builtin(TOMBSTONE_CLASS);
        let mut fuel = HASH_FUEL;
        loop {
            if fuel == 0 { return Err(OutOfFuel); }
            fuel -= 1;
            let mut exhausted = false;
            if inc {
                slot = (slot + step) & mask;
                step += 1;
                exhausted = slot == starting;
            }
            inc = true;
            let hap = self.index_get(index, slot).ok_or(NotSmi)?;
            let cf = self.fields(coll).unwrap().clone();
            if hap == 0 || exhausted {
                let left = match cf[1] { Value::Smi(l) => l, _ => return Err(NotSmi) };
                if left == 0 || exhausted {
                    self.put(1, cf[0]);
                    self.put(0, Value::Smi(2));
                } else {
                    self.put(3, Value::Smi(slot));
                    self.put(0, Value::Smi(1));
                }
                let ap = self.at(12)?;
                if !matches!(ap, Value::Smi(_)) {
                    let nf = self.at(11)?;
                    let target = self.block_method(nf).map_err(|_| NotBlock)?;
                    self.push(nf);
                    return self.call_with(target as i64, bci);
                }
                self.push(ap);
                self.s.bci = bci;
                return Ok(Step::Next);
            }
            let position = hap.div_euclid(4096) - 1;
            let backing = cf[3];
            if !matches!(backing, Value::Obj(_)) { return Err(NotObject); }
            let null = self.null();
            let k = match self.fast_at(backing, Value::Smi(position), false, null, 8)? {
                FastAt::Get(k) => k,
                _ => return Err(FieldRange),
            };
            if self.class_id_of(k).is_err() || !matches!(self.at(2)?, Value::Smi(_)) { return Err(NotObject); }
            let is_tomb = matches!(k, Value::Obj(_)) && self.class_of(k) == Some(tombstone);
            if self.smi_at(2)? == -1 && is_tomb {
                self.put(2, Value::Smi(slot));
            }
            if (hap & 0xfff) == (hash & 0xfff) && !is_tomb {
                self.put(0, Value::Smi(3));
                self.put(3, Value::Smi(slot));
                self.put(6, Value::Smi(starting));
                self.put(5, Value::Smi(step));
                self.put(4, Value::Smi(position));
                let cb = self.at(9)?;
                let target = self.block_method(cb).map_err(|_| NotBlock)?;
                let key = self.at(14)?;
                self.push(cb);
                self.push(key);
                self.push(k);
                return self.call_with(target as i64, bci);
            }
        }
    }
}
