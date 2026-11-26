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

//! The primitive implementations, by name. Each follows the C++ primitive
//! of the same name (argument unpacking, failure codes, result).

use super::*;
use super::prims::{PR, MAX_BYTE_CONTENT_DEPTH};
use crate::types::Stuck;

type P = Result<PR, Stuck>;

/// Names of the primitives implemented here, by module, for documentation
/// and the `--list-primitives` flag.
pub fn dispatch(m: &mut Machine, name: &str, a: &[Value]) -> P {
    let (module, prim) = name.split_once("::").unwrap_or(("", name));
    match module {
        "core" => core(m, prim, a),
        "timer" => timer(m, prim, a),
        "events" => events(m, prim, a),
        "math" => math(m, prim, a),
        "bitmap" if prim == "blit" => blit(m, a),
        _ => Ok(PR::Unimplemented),
    }
}

/// Extracts a primitive argument or returns the primitive failure.
macro_rules! arg {
    ($e:expr) => {
        match $e {
            Ok(v) => v,
            Err(pr) => return Ok(pr),
        }
    };
}

impl Machine {
    /// `ARGS(word, x)`.
    fn a_word(&self, v: Value) -> Result<i64, PR> {
        match v { Value::Smi(i) => Ok(i), _ => Err(self.fail("WRONG_OBJECT_TYPE")) }
    }
    /// `ARGS(int, x)`: a smi that fits in 32 bits.
    fn a_int(&self, v: Value) -> Result<i64, PR> {
        match v {
            Value::Smi(i) if i as i32 as i64 == i => Ok(i),
            Value::Smi(_) => Err(self.fail("OUT_OF_RANGE")),
            _ if self.large_int(v).is_some() => Err(self.fail("OUT_OF_RANGE")),
            _ => Err(self.fail("WRONG_OBJECT_TYPE")),
        }
    }
    /// `ARGS(int64, x)`.
    fn a_int64(&self, v: Value) -> Result<i64, PR> {
        self.int_of(v).ok_or_else(|| self.fail("WRONG_OBJECT_TYPE"))
    }
    fn a_double(&self, v: Value) -> Result<f64, PR> {
        self.double_bits(v).map(f64::from_bits).ok_or_else(|| self.fail("WRONG_OBJECT_TYPE"))
    }
    fn a_to_double(&self, v: Value) -> Result<f64, PR> {
        if let Some(i) = self.int_of(v) {
            return Ok(i as f64);
        }
        self.a_double(v)
    }
    fn a_large(&self, v: Value) -> Result<i64, PR> {
        self.large_int(v).ok_or_else(|| self.fail("WRONG_OBJECT_TYPE"))
    }
    fn a_blob(&self, v: Value) -> Result<Vec<u8>, PR> {
        self.blob(v, false).ok_or_else(|| self.fail("WRONG_OBJECT_TYPE"))
    }
    fn a_string(&self, v: Value) -> Result<Vec<u8>, PR> {
        self.blob(v, true).ok_or_else(|| self.fail("WRONG_OBJECT_TYPE"))
    }
    fn a_array(&self, v: Value) -> Result<Vec<Value>, PR> {
        self.array(v).cloned().ok_or_else(|| self.fail("WRONG_OBJECT_TYPE"))
    }
    fn a_bool(&self, v: Value) -> Result<bool, PR> {
        if v == self.true_v() {
            Ok(true)
        } else if v == self.false_v() {
            Ok(false)
        } else {
            Err(self.fail("WRONG_OBJECT_TYPE"))
        }
    }
    fn a_other_int(&self, v: Value) -> Result<i64, PR> {
        self.int_of(v).ok_or_else(|| self.fail("WRONG_OBJECT_TYPE"))
    }
    fn str_value(&mut self, s: &str) -> Value {
        self.new_string(s.as_bytes().to_vec())
    }
    fn dbl(&mut self, d: f64) -> PR {
        PR::Ok(self.new_double(d))
    }
    fn int_pr(&mut self, i: i64) -> PR {
        PR::Ok(self.integer(i))
    }
    fn bool_pr(&self, b: bool) -> PR {
        PR::Ok(self.boolean(b))
    }

    /// Writable byte storage for `MutableBlob` arguments: a byte array, a
    /// mutable copy-on-write byte array, or a byte-array slice of those.
    /// Returns the object holding the bytes and the window.
    /// `Object::mutable_byte_content`. An immutable copy-on-write byte
    /// array is made mutable on the way (a fresh backing with a copy of the
    /// content), like the C++ VM does.
    fn mutable_blob(&mut self, v: Value) -> Option<(Value, usize, usize)> {
        self.mutable_blob_at(v, 0)
    }

    /// `mutable_blob` at nesting `depth` (at most `MAX_BYTE_CONTENT_DEPTH`).
    fn mutable_blob_at(&mut self, v: Value, depth: usize) -> Option<(Value, usize, usize)> {
        if let Some(b) = self.byte_array(v) {
            return Some((v, 0, b.len()));
        }
        let f = self.fields(v)?.clone();
        let cid = self.class_of(v)?;
        if depth >= MAX_BYTE_CONTENT_DEPTH {
            return None;
        }
        if cid == self.builtin(BYTE_ARRAY_COW_CLASS) {
            if f[1] != self.true_v() {
                let content = self.blob(f[0], false)?;
                if self.obj(v).map(|o| o.ro).unwrap_or(true) {
                    return None;
                }
                let backing = self.new_bytes(content);
                let t = self.true_v();
                if let Some(ExecObj { body: ExecBody::Instance(fs), .. }) = self.obj_mut(v) {
                    fs[0] = backing;
                    fs[1] = t;
                }
                return self.mutable_blob_at(backing, depth + 1);
            }
            return self.mutable_blob_at(f[0], depth + 1);
        }
        if cid == self.builtin(BYTE_ARRAY_SLICE_CLASS) {
            let (from, to) = match (f[1], f[2]) {
                (Value::Smi(a), Value::Smi(b)) => (a, b),
                _ => return None,
            };
            let (o, start, end) = self.mutable_blob_at(f[0], depth + 1)?;
            if from < 0 || to < from || start + to as usize > end {
                return None;
            }
            return Some((o, start + from as usize, start + to as usize));
        }
        None
    }

    fn write_bytes(&mut self, o: Value, at: usize, data: &[u8]) -> Result<(), Stuck> {
        let obj = self.obj_mut(o).unwrap();
        if obj.ro && !data.is_empty() {
            return Err(Stuck::ReadOnly);
        }
        if let ExecBody::Bytes(b) = &mut obj.body {
            b[at..at + data.len()].copy_from_slice(data);
        }
        Ok(())
    }
}

/// `String::compute_hash_code_for`.
pub fn hash_code_for(bytes: &[u8]) -> i64 {
    let mut hash: u16 = bytes.len() as u16;
    for b in bytes {
        hash = hash.wrapping_mul(31).wrapping_add(*b as u16);
    }
    if hash != 0xffff { hash as i64 } else { 0 }
}

fn utf8_continuation(b: u8) -> bool {
    (b & 0xc0) == 0x80
}

/// `printf("%lld"/"%llo"/"%llx")` and binary for bases 10, 8, 16, 2.
fn printf_int(v: i64, base: i64) -> String {
    match base {
        10 => format!("{}", v),
        16 => format!("{:x}", v as u64),
        8 => format!("{:o}", v as u64),
        _ => format!("{:b}", v as u64),
    }
}

/// The generic path of `int64_to_string`: sign and magnitude digits.
fn generic_int(v: i64, base: i64) -> String {
    if v == 0 {
        return "0".into();
    }
    let mut u = (v as i128).unsigned_abs();
    let mut digits = Vec::new();
    while u != 0 {
        let d = (u % base as u128) as u8;
        u /= base as u128;
        digits.push(if d < 10 { b'0' + d } else { b'a' + d - 10 });
    }
    if v < 0 {
        digits.push(b'-');
    }
    digits.reverse();
    String::from_utf8(digits).unwrap()
}

fn cmp_op(name: &str, x: i64, y: i64) -> bool {
    if name.ends_with("less_than") {
        x < y
    } else if name.ends_with("less_than_or_equal") {
        x <= y
    } else if name.ends_with("greater_than") {
        x > y
    } else if name.ends_with("greater_than_or_equal") {
        x >= y
    } else {
        x == y
    }
}

fn core(m: &mut Machine, name: &str, a: &[Value]) -> P {
    Ok(match name {
        // --- Tasks (machine level, spec_prim.rs).
        "task_new" => return task_new(m, a[0]),
        "task_transfer" => return task_transfer(m, a[0], a[1]),
        "task_has_messages" => {
            m.world.deliver_due(m.steps);
            let b = !m.world.mailbox.is_empty();
            PR::Ok(m.boolean(b))
        }
        "task_receive_message" => {
            m.world.deliver_due(m.steps);
            PR::Ok(m.receive_message())
        }

        // --- Process and system.
        "process_current_id" => PR::Ok(Value::Smi(system::OWN_PID)),
        "process_system_id" => PR::Ok(Value::Smi(system::SYSTEM_PID)),
        "process_send" => {
            let pid = arg!(m.a_int(a[0]));
            let ty = arg!(m.a_int(a[1]));
            let msg = match m.encode_message(a[2], 0) {
                Some(v) => v,
                None => return Ok(m.fail("WRONG_OBJECT_TYPE")),
            };
            if pid == system::SYSTEM_PID || pid < 0 {
                m.world.now_steps = m.steps;
                match m.world.send_to_system(ty, msg) {
                    Ok(ok) => PR::Ok(m.boolean(ok)),
                    Err(what) => PR::UnimplementedNamed(what),
                }
            } else if pid == system::OWN_PID {
                m.world.mailbox.push_back(system::Message::System(ty, system::OWN_GID, system::OWN_PID, msg));
                PR::Ok(m.true_v())
            } else {
                PR::Ok(m.false_v())
            }
        }
        "main_arguments" => {
            let args: Vec<Vec<u8>> = m.world.args.iter().map(|s| s.as_bytes().to_vec()).collect();
            let elems: Vec<Value> = args.into_iter().map(|b| m.new_string(b)).collect();
            PR::Ok(m.new_array(elems))
        }
        "write_on_stdout" | "write_on_stderr" => {
            let mut bytes = arg!(m.a_string(a[0]));
            if a[1] == m.true_v() {
                bytes.push(b'\n');
            }
            if name == "write_on_stdout" {
                m.world.write_stdout(&bytes);
            } else {
                use std::io::Write;
                let _ = std::io::stderr().write_all(&bytes);
            }
            PR::Ok(m.null())
        }
        "get_generic_resource_group" => {
            let id = m.world.next_resource_id;
            m.world.next_resource_id += 1;
            PR::Ok(Value::Smi(id))
        }

        // --- Arrays.
        "array_new" => {
            let len = arg!(m.a_int(a[0]));
            if len == 0 {
                return Ok(PR::Ok(m.p.roots[3]));
            }
            if len < 0 {
                return Ok(m.fail("OUT_OF_BOUNDS"));
            }
            if len > 500 {
                return Ok(m.fail("OUT_OF_RANGE"));
            }
            PR::Ok(m.new_array(vec![a[1]; len as usize]))
        }
        "array_length" => PR::Ok(Value::Smi(arg!(m.a_array(a[0])).len() as i64)),
        "array_at" => {
            let arr = arg!(m.a_array(a[0]));
            let i = arg!(m.a_int(a[1]));
            if i >= 0 && (i as usize) < arr.len() { PR::Ok(arr[i as usize]) } else { m.fail("OUT_OF_BOUNDS") }
        }
        "array_at_put" => {
            let len = arg!(m.a_array(a[0])).len();
            let i = arg!(m.a_int(a[1]));
            if !(i >= 0 && (i as usize) < len) {
                return Ok(m.fail("OUT_OF_BOUNDS"));
            }
            let o = m.obj_mut(a[0]).unwrap();
            if o.ro {
                return Err(Stuck::ReadOnly);
            }
            if let ExecBody::Array(e) = &mut o.body {
                e[i as usize] = a[2];
            }
            PR::Ok(a[2])
        }
        "array_expand" => {
            let old = arg!(m.a_array(a[0]));
            let old_length = arg!(m.a_word(a[1]));
            let length = arg!(m.a_word(a[2]));
            if length == 0 {
                return Ok(PR::Ok(m.p.roots[3]));
            }
            if length < 0 {
                return Ok(m.fail("OUT_OF_BOUNDS"));
            }
            if length > 500 {
                return Ok(m.fail("OUT_OF_RANGE"));
            }
            if old_length < 0 || old_length as usize > old.len() {
                return Ok(m.fail("OUT_OF_RANGE"));
            }
            let mut e = vec![a[3]; length as usize];
            let n = std::cmp::min(length, old_length) as usize;
            e[..n].copy_from_slice(&old[..n]);
            PR::Ok(m.new_array(e))
        }
        "array_replace" => {
            let dest_len = arg!(m.a_array(a[0])).len() as i64;
            let index = arg!(m.a_word(a[1]));
            let source = arg!(m.a_array(a[2]));
            let from = arg!(m.a_word(a[3]));
            let to = arg!(m.a_word(a[4]));
            if index < 0 || from < 0 || from > to || to > source.len() as i64 {
                return Ok(m.fail("OUT_OF_BOUNDS"));
            }
            let len = to - from;
            if index + len > dest_len {
                return Ok(m.fail("OUT_OF_BOUNDS"));
            }
            let chunk = source[from as usize..to as usize].to_vec();
            let o = m.obj_mut(a[0]).unwrap();
            if len > 0 && o.ro {
                return Err(Stuck::ReadOnly);
            }
            if let ExecBody::Array(e) = &mut o.body {
                e[index as usize..(index + len) as usize].copy_from_slice(&chunk);
            }
            PR::Ok(m.null())
        }
        "list_add" => {
            let (recv, value) = (a[0], a[1]);
            if m.is_class(recv, LIST_CLASS) {
                let f = m.fields(recv).unwrap().clone();
                if let Some(arr) = m.array(f[0]) {
                    if let Value::Smi(size) = f[1] {
                        if 0 <= size && (size as usize) < arr.len() {
                            if m.obj(recv).unwrap().ro || m.obj(f[0]).unwrap().ro {
                                return Err(Stuck::ReadOnly);
                            }
                            m.set_field_pub(recv, 1, Value::Smi(size + 1));
                            if let ExecBody::Array(e) = &mut m.obj_mut(f[0]).unwrap().body {
                                e[size as usize] = value;
                            }
                            return Ok(PR::Ok(m.null()));
                        }
                    }
                } else if let Value::Smi(size) = f[1] {
                    if m.smi_ok(size as i128 + 1) {
                        if let FastAt::Put(_) = m.fast_at(f[0], f[1], true, value, 8)? {
                            m.set_field_pub(recv, 1, Value::Smi(size + 1));
                            return Ok(PR::Ok(m.null()));
                        }
                    }
                }
            }
            m.fail("INVALID_ARGUMENT")
        }

        // --- Strings.
        "string_length" => PR::Ok(Value::Smi(arg!(m.a_string(a[0])).len() as i64)),
        "string_at" | "string_raw_at" => {
            let s = arg!(m.a_string(a[0]));
            let i = arg!(m.a_int(a[1]));
            if i < 0 || i as usize >= s.len() {
                return Ok(m.fail("OUT_OF_BOUNDS"));
            }
            let c = s[i as usize] as i64;
            if name == "string_raw_at" || c <= 0x7f {
                return Ok(PR::Ok(Value::Smi(c)));
            }
            if (c & 0xc0) != 0xc0 {
                return Ok(PR::Ok(m.null()));
            }
            let n = if c >= 0xf0 { 4 } else if c >= 0xe0 { 3 } else { 2 };
            let mut r = c & (0x7f >> n);
            for j in 1..n {
                r = (r << 6) | (s.get(i as usize + j).copied().unwrap_or(0) as i64 & 0x3f);
            }
            PR::Ok(Value::Smi(r))
        }
        "string_add" => {
            let mut r = arg!(m.a_string(a[0]));
            let y = arg!(m.a_string(a[1]));
            r.extend_from_slice(&y);
            PR::Ok(m.new_string(r))
        }
        "string_slice" => {
            let s = match m.str_bytes(a[0]) {
                Some(s) => s.clone(),
                None => return Ok(m.fail("WRONG_OBJECT_TYPE")),
            };
            let from = arg!(m.a_word(a[1]));
            let to = arg!(m.a_word(a[2]));
            let len = s.len() as i64;
            if from == 0 && to == len {
                return Ok(PR::Ok(a[0]));
            }
            if from < 0 || to > len || from > to {
                return Ok(m.fail("OUT_OF_BOUNDS"));
            }
            if from != len && utf8_continuation(s[from as usize]) {
                return Ok(m.fail("ILLEGAL_UTF_8"));
            }
            if to != len && to != from && utf8_continuation(s[to as usize]) {
                return Ok(m.fail("ILLEGAL_UTF_8"));
            }
            PR::Ok(m.new_string(s[from as usize..to as usize].to_vec()))
        }
        "concat_strings" => {
            let arr = arg!(m.a_array(a[0]));
            let mut r = Vec::new();
            for v in arr {
                r.extend(arg!(m.a_string(v)));
            }
            PR::Ok(m.new_string(r))
        }
        "string_hash_code" => match m.str_bytes(a[0]) {
            Some(s) => PR::Ok(Value::Smi(hash_code_for(s))),
            None => m.fail("WRONG_OBJECT_TYPE"),
        },
        "blob_hash_code" => PR::Ok(Value::Smi(hash_code_for(&arg!(m.a_blob(a[0]))))),
        "blob_equals" => {
            let x = arg!(m.a_blob(a[0]));
            let y = arg!(m.a_blob(a[1]));
            m.bool_pr(x == y)
        }
        "string_compare" => {
            if a[0] == a[1] {
                return Ok(PR::Ok(Value::Smi(0)));
            }
            let x = arg!(m.a_string(a[0]));
            let y = arg!(m.a_string(a[1]));
            PR::Ok(Value::Smi(match x.cmp(&y) {
                std::cmp::Ordering::Less => -1,
                std::cmp::Ordering::Equal => 0,
                _ => 1,
            }))
        }
        "string_rune_count" => {
            let b = arg!(m.a_blob(a[0]));
            PR::Ok(Value::Smi(b.iter().filter(|c| !utf8_continuation(**c)).count() as i64))
        }
        "string_from_rune" => {
            let r = arg!(m.a_int(a[0]));
            match char::from_u32(r as u32) {
                Some(c) if r >= 0 => {
                    let s = c.to_string();
                    PR::Ok(m.str_value(&s))
                }
                _ => m.fail("INVALID_ARGUMENT"),
            }
        }
        "string_write_to_byte_array" => {
            let src = arg!(m.a_blob(a[0]));
            let (dest, start, end) = match m.mutable_blob(a[1]) {
                Some(d) => d,
                None => return Ok(m.fail("WRONG_OBJECT_TYPE")),
            };
            let from = arg!(m.a_word(a[2]));
            let to = arg!(m.a_word(a[3]));
            let di = arg!(m.a_word(a[4]));
            if to == from {
                return Ok(PR::Ok(a[1]));
            }
            if from < 0 || to > src.len() as i64 || from > to {
                return Ok(m.fail("OUT_OF_BOUNDS"));
            }
            if di < 0 || to - from > (end - start) as i64 - di {
                return Ok(m.fail("OUT_OF_BOUNDS"));
            }
            m.write_bytes(dest, start + di as usize, &src[from as usize..to as usize])?;
            PR::Ok(a[1])
        }
        "blob_index_of" => {
            let b = arg!(m.a_blob(a[0]));
            let byte = arg!(m.a_int(a[1]));
            let from = arg!(m.a_word(a[2]));
            let to = arg!(m.a_word(a[3]));
            if !(0 <= from && from <= to && to <= b.len() as i64) {
                return Ok(m.fail("OUT_OF_BOUNDS"));
            }
            let r = b[from as usize..to as usize]
                .iter()
                .position(|c| *c as i64 == (byte & 0xff))
                .map(|p| p as i64 + from)
                .unwrap_or(-1);
            PR::Ok(Value::Smi(r))
        }
        "smi_to_string_base_10" => {
            let v = arg!(m.a_word(a[0]));
            let s = v.to_string();
            PR::Ok(m.str_value(&s))
        }
        "int64_to_string" => {
            let v = arg!(m.a_int64(a[0]));
            let base = arg!(m.a_int(a[1]));
            if !(2..=36).contains(&base) {
                return Ok(m.fail("OUT_OF_RANGE"));
            }
            let s = if base == 10 { printf_int(v, 10) } else { generic_int(v, base) };
            PR::Ok(m.str_value(&s))
        }
        "uint64_to_string" => {
            let v = arg!(m.a_int64(a[0]));
            let s = (v as u64).to_string();
            PR::Ok(m.str_value(&s))
        }
        "printf_style_int64_to_string" => {
            let v = arg!(m.a_int64(a[0]));
            let base = arg!(m.a_int(a[1]));
            if base != 2 && base != 8 && base != 16 {
                return Ok(m.fail("INVALID_ARGUMENT"));
            }
            let s = printf_int(v, base);
            PR::Ok(m.str_value(&s))
        }

        // --- Byte arrays.
        "byte_array_new" => {
            let len = arg!(m.a_int(a[0]));
            let filler = arg!(m.a_int(a[1]));
            if len < 0 {
                return Ok(m.fail("OUT_OF_BOUNDS"));
            }
            PR::Ok(m.new_bytes(vec![filler as u8; len as usize]))
        }
        "byte_array_new_external" => {
            let len = arg!(m.a_int(a[0]));
            if len < 0 {
                return Ok(m.fail("OUT_OF_BOUNDS"));
            }
            PR::Ok(m.new_bytes(vec![0; len as usize]))
        }
        "byte_array_is_raw_bytes" => match m.byte_array(a[0]) {
            Some(_) => PR::Ok(m.true_v()),
            None => m.fail("WRONG_OBJECT_TYPE"),
        },
        "byte_array_length" => match m.byte_array(a[0]) {
            Some(b) => PR::Ok(Value::Smi(b.len() as i64)),
            None => m.fail("WRONG_OBJECT_TYPE"),
        },
        "byte_array_at" => {
            let b = match m.byte_array(a[0]) {
                Some(b) => b.clone(),
                None => return Ok(m.fail("WRONG_OBJECT_TYPE")),
            };
            let i = arg!(m.a_int(a[1]));
            if i < 0 || i as usize >= b.len() {
                return Ok(m.fail("OUT_OF_BOUNDS"));
            }
            PR::Ok(Value::Smi(b[i as usize] as i64))
        }
        "byte_array_at_put" => {
            let len = match m.byte_array(a[0]) {
                Some(b) => b.len(),
                None => return Ok(m.fail("WRONG_OBJECT_TYPE")),
            };
            let i = arg!(m.a_int(a[1]));
            let v = arg!(m.a_int64(a[2]));
            if i < 0 || i as usize >= len {
                return Ok(m.fail("OUT_OF_BOUNDS"));
            }
            m.write_bytes(a[0], i as usize, &[v as u8])?;
            PR::Ok(Value::Smi(v as u8 as i64))
        }
        "byte_array_replace" => {
            let (dest, start, end) = match m.mutable_blob(a[0]) {
                Some(d) => d,
                None => return Ok(m.fail("WRONG_OBJECT_TYPE")),
            };
            let index = arg!(m.a_int(a[1]));
            // ARGS(Blob): WRONG_BYTES_TYPE.
            let src = match m.blob(a[2], false) {
                Some(b) => b,
                None => return Ok(m.fail("WRONG_BYTES_TYPE")),
            };
            let from = arg!(m.a_int(a[3]));
            let to = arg!(m.a_int(a[4]));
            if index < 0 || from < 0 || to < 0 || to > src.len() as i64 {
                return Ok(m.fail("OUT_OF_BOUNDS"));
            }
            let len = to - from;
            if len < 0 || index + len > (end - start) as i64 {
                return Ok(m.fail("OUT_OF_BOUNDS"));
            }
            m.write_bytes(dest, start + index as usize, &src[from as usize..to as usize])?;
            PR::Ok(m.null())
        }
        "byte_array_is_valid_string_content" | "byte_array_convert_to_string" => {
            let b = arg!(m.a_blob(a[0]));
            let start = arg!(m.a_int(a[1]));
            let end = arg!(m.a_int(a[2]));
            if !(0 <= start && start <= end && end as usize <= b.len()) {
                return Ok(m.fail("OUT_OF_BOUNDS"));
            }
            let chunk = &b[start as usize..end as usize];
            let valid = std::str::from_utf8(chunk).is_ok();
            if name == "byte_array_is_valid_string_content" {
                return Ok(m.bool_pr(valid));
            }
            if !valid {
                return Ok(m.fail("ILLEGAL_UTF_8"));
            }
            PR::Ok(m.new_string(chunk.to_vec()))
        }

        // --- Smis (slow paths of the operators).
        "smi_add" | "smi_subtract" | "smi_multiply" | "smi_divide" | "smi_mod" => {
            let x = arg!(m.a_word(a[0])) as i128;
            let y = arg!(m.a_other_int(a[1])) as i128;
            if (name == "smi_divide" || name == "smi_mod") && y == 0 {
                return Ok(PR::Fail(m.error("DIVISION_BY_ZERO")));
            }
            let r = match name {
                "smi_add" => x + y,
                "smi_subtract" => x - y,
                "smi_multiply" => x * y,
                "smi_divide" => x / y,
                _ => x % y,
            };
            m.int_pr(r as i64)
        }
        "smi_less_than" | "smi_less_than_or_equal" | "smi_greater_than" | "smi_greater_than_or_equal"
        | "smi_equals" => {
            let x = arg!(m.a_word(a[0]));
            let y = arg!(m.a_other_int(a[1]));
            m.bool_pr(cmp_op(name, x, y))
        }
        "smi_unary_minus" => {
            let x = arg!(m.a_word(a[0]));
            m.int_pr(-x)
        }
        "smi_not" => {
            let x = arg!(m.a_word(a[0]));
            PR::Ok(Value::Smi(!x))
        }
        "smi_and" | "smi_or" | "smi_xor" => {
            let x = arg!(m.a_word(a[0]));
            let y = arg!(m.a_other_int(a[1]));
            m.int_pr(match name {
                "smi_and" => x & y,
                "smi_or" => x | y,
                _ => x ^ y,
            })
        }
        "smi_shift_right" => {
            let x = arg!(m.a_word(a[0]));
            let n = arg!(m.a_int64(a[1]));
            if n < 0 {
                return Ok(m.fail("NEGATIVE_ARGUMENT"));
            }
            if n >= m.word_bit_size() {
                return Ok(PR::Ok(Value::Smi(if x < 0 { -1 } else { 0 })));
            }
            PR::Ok(Value::Smi(x >> n))
        }
        "smi_unsigned_shift_right" | "smi_shift_left" => {
            let x = match a[0] {
                Value::Smi(x) => x,
                _ => return Ok(m.fail("WRONG_OBJECT_TYPE")),
            };
            let n = arg!(m.a_int64(a[1]));
            if n < 0 {
                return Ok(m.fail("NEGATIVE_ARGUMENT"));
            }
            if n >= 64 {
                return Ok(PR::Ok(Value::Smi(0)));
            }
            if name == "smi_shift_left" {
                m.int_pr(x.wrapping_shl(n as u32))
            } else {
                m.int_pr(((x as u64) >> n) as i64)
            }
        }

        // --- Large integers.
        "large_integer_add" | "large_integer_subtract" | "large_integer_multiply" | "large_integer_divide"
        | "large_integer_mod" | "large_integer_and" | "large_integer_or" | "large_integer_xor" => {
            let x = arg!(m.a_large(a[0]));
            let y = arg!(m.a_other_int(a[1]));
            if (name == "large_integer_divide" || name == "large_integer_mod") && y == 0 {
                return Ok(PR::Fail(m.error("DIVISION_BY_ZERO")));
            }
            m.int_pr(match name {
                "large_integer_add" => x.wrapping_add(y),
                "large_integer_subtract" => x.wrapping_sub(y),
                "large_integer_multiply" => x.wrapping_mul(y),
                "large_integer_divide" => x.wrapping_div(y),
                "large_integer_mod" => x.wrapping_rem(y),
                "large_integer_and" => x & y,
                "large_integer_or" => x | y,
                _ => x ^ y,
            })
        }
        "large_integer_less_than" | "large_integer_less_than_or_equal" | "large_integer_greater_than"
        | "large_integer_greater_than_or_equal" | "large_integer_equals" => {
            let x = arg!(m.a_large(a[0]));
            let y = arg!(m.a_other_int(a[1]));
            m.bool_pr(cmp_op(name, x, y))
        }
        "large_integer_unary_minus" => {
            let x = arg!(m.a_large(a[0]));
            m.int_pr(x.wrapping_neg())
        }
        "large_integer_not" => {
            let x = arg!(m.a_large(a[0]));
            m.int_pr(!x)
        }
        "large_integer_shift_right" | "large_integer_unsigned_shift_right" | "large_integer_shift_left" => {
            let x = arg!(m.a_large(a[0]));
            let n = arg!(m.a_int64(a[1]));
            if n < 0 {
                return Ok(m.fail("NEGATIVE_ARGUMENT"));
            }
            m.int_pr(match name {
                "large_integer_shift_right" => {
                    if n >= 64 { if x < 0 { -1 } else { 0 } } else { x >> n }
                }
                "large_integer_unsigned_shift_right" => {
                    if n >= 64 { 0 } else { ((x as u64) >> n) as i64 }
                }
                _ => {
                    if n >= 64 { 0 } else { x.wrapping_shl(n as u32) }
                }
            })
        }

        // --- Floats.
        "number_to_float" => {
            let d = arg!(m.a_to_double(a[0]));
            m.dbl(d)
        }
        "number_to_integer" => {
            if m.int_of(a[0]).is_some() {
                return Ok(PR::Ok(a[0]));
            }
            let d = arg!(m.a_double(a[0]));
            if d.is_nan() {
                return Ok(m.fail("INVALID_ARGUMENT"));
            }
            if d < i64::MIN as f64 || d >= i64::MAX as f64 {
                return Ok(m.fail("OUT_OF_RANGE"));
            }
            m.int_pr(d as i64)
        }
        "float_unary_minus" => {
            let d = arg!(m.a_double(a[0]));
            m.dbl(-d)
        }
        "float_add" | "float_subtract" | "float_multiply" | "float_divide" | "float_mod" => {
            let x = arg!(m.a_double(a[0]));
            let y = arg!(m.a_double(a[1]));
            m.dbl(match name {
                "float_add" => x + y,
                "float_subtract" => x - y,
                "float_multiply" => x * y,
                "float_divide" => x / y,
                _ => x % y,
            })
        }
        "float_less_than" | "float_less_than_or_equal" | "float_greater_than" | "float_greater_than_or_equal"
        | "float_equals" => {
            let x = arg!(m.a_double(a[0]));
            let y = arg!(m.a_double(a[1]));
            m.bool_pr(match name {
                "float_less_than" => x < y,
                "float_less_than_or_equal" => x <= y,
                "float_greater_than" => x > y,
                "float_greater_than_or_equal" => x >= y,
                _ => x == y,
            })
        }
        "float_round" => {
            let x = arg!(m.a_double(a[0]));
            let p = arg!(m.a_int(a[1]));
            if !(0..=15).contains(&p) {
                return Ok(m.fail("INVALID_ARGUMENT"));
            }
            if x.is_nan() {
                return Ok(m.fail("OUT_OF_RANGE"));
            }
            if x > 1e54 {
                return Ok(PR::Ok(a[0]));
            }
            let factor = 10f64.powi(p as i32) as i32 as f64;
            m.dbl((x * factor).round() / factor)
        }
        "float_sign" => {
            let x = arg!(m.a_double(a[0]));
            let s = if x.is_nan() { 1 } else if x.is_sign_negative() { -1 } else if x == 0.0 { 0 } else { 1 };
            PR::Ok(Value::Smi(s))
        }
        "float_is_nan" => {
            let x = arg!(m.a_double(a[0]));
            m.bool_pr(x.is_nan())
        }
        "float_is_finite" => {
            let x = arg!(m.a_double(a[0]));
            m.bool_pr(x.is_finite())
        }
        "float_sqrt" | "float_ceil" | "float_floor" | "float_trunc" => {
            let x = arg!(m.a_double(a[0]));
            m.dbl(match name {
                "float_sqrt" => x.sqrt(),
                "float_ceil" => x.ceil(),
                "float_floor" => x.floor(),
                _ => x.trunc(),
            })
        }
        "float_to_raw" => {
            let x = arg!(m.a_double(a[0]));
            m.int_pr(x.to_bits() as i64)
        }
        "raw_to_float" => {
            let x = arg!(m.a_int64(a[0]));
            m.dbl(f64::from_bits(x as u64))
        }
        "float_to_raw32" => {
            let x = arg!(m.a_double(a[0]));
            m.int_pr((x as f32).to_bits() as i64)
        }
        "raw32_to_float" => {
            let x = arg!(m.a_int64(a[0]));
            if (x as u64) >> 32 != 0 {
                return Ok(m.fail("OUT_OF_RANGE"));
            }
            m.dbl(f32::from_bits(x as u32) as f64)
        }
        "float_to_string" => {
            let x = arg!(m.a_double(a[0]));
            let s = if x.is_nan() {
                "nan".to_string()
            } else if x.is_infinite() {
                if x < 0.0 { "-inf".into() } else { "inf".into() }
            } else if a[1] == m.null() {
                if x == 0.0 {
                    if x.is_sign_negative() { "-0.0".into() } else { "0.0".into() }
                } else {
                    super::floatfmt::shortest(x)
                }
            } else {
                let p = match a[1] {
                    Value::Smi(p) => p,
                    _ if m.large_int(a[1]).is_some() => return Ok(m.fail("OUT_OF_BOUNDS")),
                    _ => return Ok(m.fail("WRONG_OBJECT_TYPE")),
                };
                if !(0..=64).contains(&p) {
                    return Ok(m.fail("OUT_OF_BOUNDS"));
                }
                format!("{:.*}", p as usize, x)
            };
            PR::Ok(m.str_value(&s))
        }
        "float_parse" => {
            let b = arg!(m.a_blob(a[0]));
            let from = arg!(m.a_word(a[1]));
            let to = arg!(m.a_word(a[2]));
            if !(0 <= from && from < to && to as usize <= b.len()) {
                return Ok(m.fail("OUT_OF_RANGE"));
            }
            let s = String::from_utf8_lossy(&b[from as usize..to as usize]).into_owned();
            if s.starts_with(|c: char| c.is_ascii_whitespace()) {
                return Ok(m.fail("ERROR"));
            }
            match parse_strtod(&s) {
                Some(d) => m.dbl(d),
                None => m.fail("ERROR"),
            }
        }
        "int_parse" => {
            let b = arg!(m.a_blob(a[0]));
            let from = arg!(m.a_word(a[1]));
            let to = arg!(m.a_word(a[2]));
            if !(0 <= from && from < to && to as usize <= b.len()) {
                return Ok(m.fail("OUT_OF_RANGE"));
            }
            if to - from > 18 {
                return Ok(m.fail("OUT_OF_RANGE"));
            }
            let (from, to) = (from as usize, to as usize);
            let mut result: u64 = 0;
            let mut negative = false;
            let mut index = from;
            if b[index] == b'-' {
                negative = true;
                index += 1;
                if index == to {
                    return Ok(m.fail("INVALID_ARGUMENT"));
                }
            }
            while index < to {
                let c = b[index];
                if c.is_ascii_digit() {
                    result = result * 10 + (c - b'0') as u64;
                } else if c == b'_' {
                    if index == from || index == to - 1 || (negative && index == from + 1) {
                        return Ok(m.fail("INVALID_ARGUMENT"));
                    }
                } else {
                    return Ok(m.fail("INVALID_ARGUMENT"));
                }
                index += 1;
            }
            m.int_pr(if negative { (result as i64).wrapping_neg() } else { result as i64 })
        }
        "compare_to" | "min_special_compare_to" => {
            let r = m.compare_numbers(a[0], a[1]);
            if r == 0 {
                return Ok(m.fail("INVALID_ARGUMENT"));
            }
            if name == "compare_to" {
                PR::Ok(Value::Smi((r & 3) as i64 - 2))
            } else {
                m.bool_pr(r & 4 != 0)
            }
        }
        "count_leading_zeros" => {
            let v = arg!(m.a_int64(a[0]));
            PR::Ok(Value::Smi(v.leading_zeros() as i64))
        }
        "popcount" => {
            let v = arg!(m.a_int64(a[0]));
            PR::Ok(Value::Smi(v.count_ones() as i64))
        }

        // --- JSON helpers.
        "hash_simple_json_string" => {
            let b = arg!(m.a_blob(a[0]));
            let off = arg!(m.a_word(a[1]));
            if off < 0 {
                return Ok(m.fail("INVALID_ARGUMENT"));
            }
            for i in off as usize..b.len() {
                if b[i] == b'\\' {
                    return Ok(PR::Ok(Value::Smi(-1)));
                }
                if b[i] == b'"' {
                    return Ok(PR::Ok(Value::Smi(hash_code_for(&b[off as usize..i]))));
                }
            }
            PR::Ok(Value::Smi(-1))
        }
        "json_skip_whitespace" => {
            let b = arg!(m.a_blob(a[0]));
            let off = arg!(m.a_word(a[1]));
            if off < 0 {
                return Ok(m.fail("INVALID_ARGUMENT"));
            }
            let mut i = off as usize;
            while i < b.len() && matches!(b[i], b' ' | b'\n' | b'\t' | b'\r') {
                i += 1;
            }
            PR::Ok(Value::Smi(i as i64))
        }
        "compare_simple_json_string" => {
            let b = arg!(m.a_blob(a[0]));
            let off = arg!(m.a_word(a[1]));
            let s = arg!(m.a_string(a[2]));
            if off < 0 {
                return Ok(m.fail("INVALID_ARGUMENT"));
            }
            let off = off as usize;
            if s.len() as i64 >= b.len() as i64 - off as i64 {
                return Ok(m.bool_pr(false));
            }
            let rest = &b[off..];
            if rest.iter().position(|c| *c == b'"') != Some(s.len()) {
                return Ok(m.bool_pr(false));
            }
            m.bool_pr(rest[..s.len()] == s[..])
        }
        "size_of_json_number" => {
            let b = arg!(m.a_blob(a[0]));
            let off = arg!(m.a_word(a[1]));
            if off < 0 || off >= b.len() as i64 - 1 {
                return Ok(m.fail("INVALID_ARGUMENT"));
            }
            const NUMBER_TABLE: u32 = 0x3ff6820;
            const FLOAT_TABLE: u32 = 0x4020;
            let mut is_float = 0;
            let mut p = off as usize;
            while p < b.len() {
                let c = b[p];
                if (NUMBER_TABLE >> (c & 0x1f)) & 1 == 0 || c == b'\r' {
                    break;
                }
                is_float |= (FLOAT_TABLE >> (c & 0x1f)) & 1;
                p += 1;
            }
            PR::Ok(Value::Smi(if is_float != 0 { -(p as i64) } else { p as i64 }))
        }
        "rebuild_hash_index" => {
            let old = match m.array(a[0]) {
                Some(o) => o.clone(),
                None => return Ok(m.fail("OUT_OF_RANGE")),
            };
            let mut new = match m.array(a[1]) {
                Some(n) => n.clone(),
                None => return Ok(m.fail("OUT_OF_RANGE")),
            };
            // A non-empty power-of-two index and smi entries are required;
            // anything else fails before the index is touched.
            let len = new.len() as i64;
            if len == 0 || (len & (len - 1)) != 0 {
                return Ok(m.fail("INVALID_ARGUMENT"));
            }
            let mask = len - 1;
            let mut entries = Vec::with_capacity(old.len());
            for o in old {
                match o {
                    Value::Smi(h) => entries.push(h),
                    _ => return Ok(m.fail("INVALID_ARGUMENT")),
                }
            }
            for hap in entries {
                if hap == 0 { continue; }  // Empty slot.
                let mut slot = hap & mask;
                let mut step = 1;
                while new[slot as usize] != Value::Smi(0) {
                    // A full index fails instead of probing forever.
                    if step > len {
                        return Ok(m.fail("INVALID_ARGUMENT"));
                    }
                    slot = (slot + step) & mask;
                    step += 1;
                }
                new[slot as usize] = Value::Smi(hap);
            }
            if m.obj(a[1]).unwrap().ro {
                return Err(Stuck::ReadOnly);
            }
            m.obj_mut(a[1]).unwrap().body = ExecBody::Array(new);
            PR::Ok(m.null())
        }

        // --- Objects and the VM.
        "object_class_id" => PR::Ok(Value::Smi(m.class_id_of(a[0])?)),
        "word_size" => PR::Ok(Value::Smi(m.p.word_bits as i64 / 8)),
        "add_finalizer" => {
            if m.fields(a[0]).is_none() {
                return Ok(m.fail("WRONG_OBJECT_TYPE"));
            }
            if !m.obj(a[0]).unwrap().ro {
                if m.world.finalizers.contains(&a[0]) {
                    return Ok(m.fail("ALREADY_EXISTS"));
                }
                m.world.finalizers.push(a[0]);
            }
            PR::Ok(m.null())
        }
        "remove_finalizer" => {
            let had = match m.world.finalizers.iter().position(|v| *v == a[0]) {
                Some(i) => {
                    m.world.finalizers.remove(i);
                    true
                }
                None => false,
            };
            m.bool_pr(had)
        }
        "gc_count" => PR::Ok(Value::Smi(0)),
        "encode_error" | "encode_object" => {
            // The C++ VM encodes the error (and the stack trace) for the
            // system process. The emulation returns an opaque byte array with
            // the stringified arguments; programs only pass it on.
            let mut bytes = b"spec-trace:".to_vec();
            for v in a {
                if let Some(s) = m.blob(*v, true) {
                    bytes.extend(s);
                }
                bytes.push(b';');
            }
            PR::Ok(m.new_bytes(bytes))
        }
        "time" => {
            let since_wakeup = arg!(m.a_bool(a[0]));
            // Both clocks are the virtual monotonic clock (timers use the same one).
            let _ = since_wakeup;
            let t = m.world.clock_us;
            m.int_pr(t)
        }
        "random" => {
            m.world.random = m.world.random.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            PR::Ok(Value::Smi(((m.world.random >> 33) & 0xfffffff) as i64))
        }
        "vm_sdk_version" | "app_sdk_version" => PR::Ok(m.p.roots[5]),
        "vm_sdk_info" | "app_sdk_info" => PR::Ok(m.p.roots[6]),
        "platform" => PR::Ok(m.str_value("Linux")),
        "architecture" => PR::Ok(m.str_value("x86_64")),
        "program_name" => match m.world.program_name.clone() {
            Some(n) => PR::Ok(m.str_value(&n)),
            None => PR::Ok(m.null()),
        },
        "program_path" => PR::Ok(m.null()),
        "literal_index" => PR::Ok(match m.p.literals.iter().position(|v| *v == a[0]) {
            Some(i) => Value::Smi(i as i64),
            None => m.null(),
        }),
        _ => PR::Unimplemented,
    })
}

/// `strtod` on a complete string (decimal, hexadecimal, inf, nan).
fn parse_strtod(s: &str) -> Option<f64> {
    let t = s.to_ascii_lowercase();
    let (neg, body) = match t.strip_prefix('-') {
        Some(r) => (true, r.to_string()),
        None => (false, t.strip_prefix('+').unwrap_or(&t).to_string()),
    };
    let v = if body == "inf" || body == "infinity" {
        f64::INFINITY
    } else if body.starts_with("nan") {
        f64::NAN
    } else if let Some(hex) = body.strip_prefix("0x") {
        let (mant, exp) = match hex.split_once('p') {
            Some((a, b)) => (a, b.parse::<i32>().ok()?),
            None => (hex, 0),
        };
        let (ip, fp) = mant.split_once('.').unwrap_or((mant, ""));
        let mut v = 0f64;
        for c in ip.chars() {
            v = v * 16.0 + c.to_digit(16)? as f64;
        }
        let mut scale = 1.0 / 16.0;
        for c in fp.chars() {
            v += c.to_digit(16)? as f64 * scale;
            scale /= 16.0;
        }
        v * 2f64.powi(exp)
    } else {
        if body.is_empty() || !body.chars().all(|c| c.is_ascii_digit() || matches!(c, '.' | 'e' | '-' | '+')) {
            return None;
        }
        body.parse::<f64>().ok()?
    };
    Some(if neg { -v } else { v })
}

/// `bitmap.blit` (primitive_bitmap.cc).
fn blit(m: &mut Machine, a: &[Value]) -> P {
    let (dest, start, end) = match m.mutable_blob(a[0]) {
        Some(d) => d,
        None => return Ok(m.fail("WRONG_OBJECT_TYPE")),
    };
    let dest_pixel_stride = arg!(m.a_word(a[1]));
    let dest_line_stride = arg!(m.a_word(a[2]));
    let src = arg!(m.a_blob(a[3]));
    let src_pixel_stride = arg!(m.a_word(a[4]));
    let src_line_stride = arg!(m.a_word(a[5]));
    let pixels_per_line = arg!(m.a_word(a[6]));
    let lut = a[7];
    let shift = arg!(m.a_word(a[8]));
    let mask = arg!(m.a_word(a[9]));
    let operation = arg!(m.a_word(a[10]));
    if !(0..6).contains(&operation) {
        return Ok(m.fail("OUT_OF_BOUNDS"));
    }
    if ((dest_line_stride | src_line_stride | pixels_per_line) & -0x800000) != 0 {
        return Ok(m.fail("INVALID_ARGUMENT"));
    }
    if (src_pixel_stride & -0x80) != 0 {
        return Ok(m.fail("INVALID_ARGUMENT"));
    }
    if !(-0x80 < dest_pixel_stride && dest_pixel_stride <= 0x80) {
        return Ok(m.fail("INVALID_ARGUMENT"));
    }
    let lookup: Vec<u8> = if lut == m.null() {
        (0..=255u8).collect()
    } else {
        let b = arg!(m.a_blob(lut));
        if b.len() < 0x100 {
            return Ok(m.fail("INVALID_ARGUMENT"));
        }
        b
    };
    let abs_dest_pixel_stride = dest_pixel_stride.abs();
    if dest_line_stride == 0 && src_line_stride == 0 {
        return Ok(m.fail("INVALID_ARGUMENT"));
    }
    let mut d: Vec<u8> = match &m.obj(dest).unwrap().body {
        ExecBody::Bytes(b) => b[start..end].to_vec(),
        _ => unreachable!(),
    };
    let mut src_offset: i64 = 0;
    let mut dest_offset: i64 = 0;
    let src_read_width = (pixels_per_line - 1) * src_pixel_stride;
    let mut dest_write_width = (pixels_per_line - 1) * abs_dest_pixel_stride;
    if abs_dest_pixel_stride != dest_pixel_stride {
        if operation == 3 {
            return Ok(m.fail("INVALID_ARGUMENT"));
        }
        dest_offset += dest_write_width;
        dest_write_width = 0;
    }
    if operation == 3 {
        dest_write_width += 1;
    }
    let (src_len, dest_len) = (src.len() as i64, d.len() as i64);
    while src_offset + src_read_width < src_len && dest_offset + dest_write_width < dest_len {
        let mut si = src_offset;
        let mut di = dest_offset;
        for _ in 0..pixels_per_line {
            let pixel = src[si as usize];
            let mut looked_up: u16 = lookup[pixel as usize] as u16;
            looked_up |= looked_up << 8;
            looked_up >>= shift & 7;
            looked_up &= mask as u16;
            let i = di as usize;
            match operation {
                0 => d[i] = looked_up as u8,
                1 => d[i] |= looked_up as u8,
                2 => d[i] = std::cmp::min(d[i] as u16 + looked_up, 0xff) as u8,
                4 => d[i] &= looked_up as u8,
                5 => d[i] ^= looked_up as u8,
                _ => {
                    let v = (d[i] as u32 | ((d[i + 1] as u32) << 8)) + looked_up as u32;
                    let v = std::cmp::min(v, 0xffff);
                    d[i] = v as u8;
                    d[i + 1] = (v >> 8) as u8;
                }
            }
            si += src_pixel_stride;
            di += dest_pixel_stride;
        }
        src_offset += src_line_stride;
        dest_offset += dest_line_stride;
    }
    m.write_bytes(dest, start, &d)?;
    Ok(PR::Ok(m.null()))
}

fn math(m: &mut Machine, name: &str, a: &[Value]) -> P {
    let x = arg!(m.a_to_double(a[0]));
    let r = match name {
        "sin" => x.sin(),
        "cos" => x.cos(),
        "tan" => x.tan(),
        "sinh" => x.sinh(),
        "cosh" => x.cosh(),
        "tanh" => x.tanh(),
        "asin" => x.asin(),
        "acos" => x.acos(),
        "atan" => x.atan(),
        "sqrt" => x.sqrt(),
        "exp" => x.exp(),
        "log" => x.ln(),
        "atan2" => x.atan2(arg!(m.a_to_double(a[1]))),
        "pow" => x.powf(arg!(m.a_to_double(a[1]))),
        _ => return Ok(PR::Unimplemented),
    };
    Ok(m.dbl(r))
}

// ---------------------------------------------------------------------------
// Timers and events (virtual clock, see system.rs).

fn timer(m: &mut Machine, name: &str, a: &[Value]) -> P {
    Ok(match name {
        "init" => {
            let id = m.world.next_resource_id;
            m.world.next_resource_id += 1;
            PR::Ok(Value::Smi(id))
        }
        "create" => {
            let id = m.world.next_resource_id;
            m.world.next_resource_id += 1;
            m.world.timers.push(system::Timer { id, deadline: None, monitor: None, state: 0 });
            PR::Ok(Value::Smi(id))
        }
        "arm" => {
            let id = arg!(m.a_word(a[0]));
            let us = arg!(m.a_int64(a[1]));
            match m.world.timers.iter_mut().find(|t| t.id == id) {
                Some(t) => {
                    t.deadline = Some(us);
                    PR::Ok(m.null())
                }
                None => m.fail("ALREADY_CLOSED"),
            }
        }
        "delete" => {
            let id = arg!(m.a_word(a[1]));
            m.world.timers.retain(|t| t.id != id);
            PR::Ok(m.null())
        }
        _ => PR::Unimplemented,
    })
}

fn events(m: &mut Machine, name: &str, a: &[Value]) -> P {
    Ok(match name {
        "register_monitor_notifier" => {
            // (monitor, resource_group, resource): attach the monitor to a timer.
            let id = arg!(m.a_word(a[2]));
            let monitor = if a[0] == m.null() { None } else { Some(a[0]) };
            if let Some(t) = m.world.timers.iter_mut().find(|t| t.id == id) {
                t.monitor = monitor;
            }
            PR::Ok(m.null())
        }
        "unregister_monitor_notifier" => {
            let id = arg!(m.a_word(a[1]));
            if let Some(t) = m.world.timers.iter_mut().find(|t| t.id == id) {
                t.monitor = None;
            }
            PR::Ok(m.null())
        }
        "read_state" => {
            // (resource_group, resource): read and clear the state bits.
            let id = arg!(m.a_word(a[1]));
            let state = match m.world.timers.iter_mut().find(|t| t.id == id) {
                Some(t) => std::mem::replace(&mut t.state, 0),
                None => 0,
            };
            PR::Ok(Value::Smi(state as i64))
        }
        _ => PR::Unimplemented,
    })
}

// ---------------------------------------------------------------------------
// Task primitives (spec_prim::task_new_step, task_transfer_step).

fn task_new(m: &mut Machine, code: Value) -> P {
    if m.fields(code).is_none() {
        return Ok(m.fail("WRONG_OBJECT_TYPE"));
    }
    if m.format == 2 {
        return task_new2(m, code);
    }
    let entry = m.entry_method(ENTRY_TASK);
    let task_class = m.builtin(TASK_CLASS) as usize;
    if !m.valid_method(entry) || task_class >= m.p.class_bits.len() {
        return Err(Stuck::Fatal);
    }
    let field_count = ((m.p.class_bits[task_class] >> 5) & 0x7ff) as i64 - 1;
    if field_count < 2 {
        return Err(Stuck::Fatal);
    }
    let entry = entry as usize + 4;
    let stack_id = m.s.heap.len();
    let task = Value::Obj(stack_id + 1);
    let false_v = m.false_v();
    let words = vec![
        code,
        Value::RetAddr(entry),
        Value::FrameMarker,
        task,
        false_v,
        Value::RetAddr(entry + 1),
        Value::FrameMarker,
    ];
    let stack_class = m.builtin(STACK_CLASS);
    m.alloc(ExecObj { class_id: stack_class, ro: false, body: ExecBody::Stack(words, 0) });
    let null = m.null();
    let mut fields = vec![null; field_count as usize];
    fields[0] = Value::Obj(stack_id);
    fields[1] = Value::Smi(m.s.next_task_id);
    m.alloc(ExecObj { class_id: task_class as u16, ro: false, body: ExecBody::Instance(fields) });
    m.s.next_task_id += 1;
    Ok(PR::Ok(task))
}

/// Format 2 (`v2::prim::task_new_step`): a task that never ran has an
/// empty frame stack and its code as the only stack slot.
fn task_new2(m: &mut Machine, code: Value) -> P {
    let task_class = m.builtin(TASK_CLASS) as usize;
    if m.entry_method2(ENTRY_TASK).is_none() || task_class >= m.p.class_bits.len() {
        return Err(Stuck::Fatal);
    }
    let field_count = ((m.p.class_bits[task_class] >> 5) & 0x7ff) as i64 - 1;
    if field_count < 2 {
        return Err(Stuck::Fatal);
    }
    let stack_id = m.s.heap.len();
    let task = Value::Obj(stack_id + 1);
    let stack_class = m.builtin(STACK_CLASS);
    m.alloc(ExecObj { class_id: stack_class, ro: false, body: ExecBody::Stack2(vec![code], Vec::new(), 0) });
    let null = m.null();
    let mut fields = vec![null; field_count as usize];
    fields[0] = Value::Obj(stack_id);
    fields[1] = Value::Smi(m.s.next_task_id);
    m.alloc(ExecObj { class_id: task_class as u16, ro: false, body: ExecBody::Instance(fields) });
    m.s.next_task_id += 1;
    Ok(PR::Ok(task))
}

fn is_task(m: &Machine, v: Value) -> bool {
    m.is_class(v, TASK_CLASS) && m.fields(v).map(|f| f.len() >= 2).unwrap_or(false)
}

fn stack_of(m: &Machine, task: Value) -> Option<Value> {
    let st = m.fields(task)?[0];
    match m.obj(st) {
        Some(ExecObj { body: ExecBody::Stack(..), .. }) if m.format == 1 => Some(st),
        Some(ExecObj { body: ExecBody::Stack2(..), .. }) if m.format == 2 => Some(st),
        _ => None,
    }
}

fn task_transfer(m: &mut Machine, to: Value, detach: Value) -> P {
    let from = Value::Obj(m.s.task);
    if !is_task(m, to) || !(detach == m.true_v() || detach == m.false_v()) {
        return Ok(m.fail("WRONG_OBJECT_TYPE"));
    }
    if from == to {
        return Ok(PR::Fail(to));
    }
    // Format 2 (`v2::prim::task_transfer_step`): the running task always
    // has its stack (`v2::sound::running_ok`; a program cannot write a
    // task's stack field).
    if m.format == 2 && !(is_task(m, from) && stack_of(m, from).is_some()) {
        return Err(Stuck::Fatal);
    }
    let to_stack = match stack_of(m, to) {
        Some(s) => s,
        None => return Ok(m.fail("ERROR")),
    };
    let from_stack = match (is_task(m, from), stack_of(m, from)) {
        (true, Some(s)) => s,
        _ => return Err(Stuck::Fatal),
    };
    if m.format == 2 {
        let resumable = match &m.obj(to_stack).unwrap().body {
            ExecBody::Stack2(w, f, _) => !f.is_empty() || !w.is_empty(),
            _ => false,
        };
        if !resumable {
            return Ok(m.fail("ERROR"));
        }
        return task_transfer2(m, from, from_stack, to, to_stack, detach);
    }
    let words = std::mem::take(&mut m.s.stack);
    let try_h = m.s.try_h;
    m.obj_mut(from_stack).unwrap().body = ExecBody::Stack(words, try_h);
    if detach == m.true_v() {
        m.set_field_pub(from, 0, Value::Smi(0));
    }
    let (words, try_h) = match &m.obj(to_stack).unwrap().body {
        ExecBody::Stack(w, h) => (w.clone(), *h),
        _ => return Err(Stuck::Fatal),
    };
    m.s.stack = words;
    m.s.try_h = try_h;
    m.s.task = match to {
        Value::Obj(id) => id,
        _ => unreachable!(),
    };
    m.push(to);
    m.s.bci += 4;
    Ok(PR::Done)
}

/// Format 2 (`v2::prim::task_transfer_step`). The running task is saved
/// with its frame stack, suspended at the PRIMITIVE. The target continues
/// after its PRIMITIVE with itself pushed (the failure path of
/// `task-transfer-to_`). A task that never ran gets the frames of
/// `__entry__task(code)` having called `task-transfer-to_(task, false)`
/// from its bci 1, like `Interpreter::prepare_task`.
fn task_transfer2(m: &mut Machine, from: Value, from_stack: Value, to: Value, to_stack: Value, detach: Value) -> P {
    let current = match m.top_frame() {
        Ok(f) => f.method,
        Err(_) => return Err(Stuck::Fatal),
    };
    let words = std::mem::take(&mut m.s.stack);
    let frames = std::mem::take(&mut m.s.frames);
    let bci = m.s.bci;
    m.obj_mut(from_stack).unwrap().body = ExecBody::Stack2(words, frames, bci);
    if detach == m.true_v() {
        m.set_field_pub(from, 0, Value::Smi(0));
    }
    let (words, frames, saved_bci) = match &m.obj(to_stack).unwrap().body {
        ExecBody::Stack2(w, f, b) => (w.clone(), f.clone(), *b),
        _ => return Err(Stuck::Fatal),
    };
    if frames.is_empty() {
        // A new task.
        let code = match words.first() { Some(c) => *c, None => return Err(Stuck::Fatal) };
        let entry = match m.entry_method2(ENTRY_TASK) { Some(e) => e, None => return Err(Stuck::Fatal) };
        let entry_bci = m.p.methods[entry].entry;
        let false_v = m.false_v();
        m.s.stack = vec![code, to, false_v];
        m.s.frames = vec![
            Frame { method: entry, ret: entry_bci, base: 0, handler: false },
            Frame { method: current, ret: entry_bci + 1, base: 1, handler: false },
        ];
        m.s.bci = bci + 4;
    } else {
        m.s.stack = words;
        m.s.frames = frames;
        m.s.bci = saved_bci + 4;
    }
    m.s.task = match to {
        Value::Obj(id) => id,
        _ => unreachable!(),
    };
    m.push(to);
    Ok(PR::Done)
}
