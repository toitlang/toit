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

//! Reads the flat program description written by `tools/spec_dump.toit`
//! (class `SpecDump` in `tools/snapshot.toit`).

use crate::types::*;
use std::collections::BTreeMap;

/// Debug names, used for diagnostics and primitive dispatch.
#[derive(Default)]
pub struct Names {
    /// Method id -> (bytecode size, name).
    pub methods: BTreeMap<usize, (usize, String)>,
    pub classes: BTreeMap<u16, String>,
    /// Module name and primitive names, by module index.
    pub primitives: Vec<(String, Vec<String>)>,
}

impl Names {
    /// The method containing absolute bci `bci`.
    pub fn method_at(&self, bci: usize) -> Option<(usize, &str)> {
        self.methods
            .range(..=bci)
            .next_back()
            .filter(|(id, (size, _))| bci <= **id + 4 + *size)
            .map(|(id, (_, name))| (*id, name.as_str()))
    }

    pub fn class_name(&self, id: usize) -> String {
        self.classes.get(&(id as u16)).cloned().unwrap_or_else(|| format!("class#{}", id))
    }

    pub fn primitive(&self, module: u8, index: u16) -> String {
        match self.primitives.get(module as usize) {
            Some((m, names)) => match names.get(index as usize) {
                Some(n) => format!("{}::{}", m, n),
                None => format!("{}::#{}", m, index),
            },
            None => format!("#{}::#{}", module, index),
        }
    }
}

pub struct Loaded {
    pub program: ExecProgram,
    /// Program heap followed by large integers created for literals.
    pub heap: Vec<ExecObj>,
    pub globals: Vec<Value>,
    pub names: Names,
}

struct Reader<'a> {
    lines: std::iter::Peekable<std::str::Lines<'a>>,
}

fn err<T>(msg: impl Into<String>) -> Result<T, String> {
    Err(msg.into())
}

fn hex(s: &str) -> Result<Vec<u8>, String> {
    if s == "-" {
        return Ok(Vec::new());
    }
    if s.len() % 2 != 0 {
        return err("odd hex length");
    }
    (0..s.len() / 2)
        .map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).map_err(|e| e.to_string()))
        .collect()
}

impl<'a> Reader<'a> {
    fn line(&mut self, key: &str) -> Result<Vec<&'a str>, String> {
        let line = self.lines.next().ok_or_else(|| format!("missing '{}'", key))?;
        let parts: Vec<&str> = line.split(' ').filter(|p| !p.is_empty()).collect();
        if parts.first() != Some(&key) {
            return err(format!("expected '{}', got '{}'", key, line.chars().take(40).collect::<String>()));
        }
        Ok(parts)
    }

    fn ints<T: std::str::FromStr>(&mut self, key: &str) -> Result<Vec<T>, String> {
        let parts = self.line(key)?;
        let n: usize = parts[1].parse().map_err(|_| "bad count")?;
        if parts.len() != n + 2 {
            return err(format!("bad length for {}", key));
        }
        parts[2..].iter().map(|p| p.parse::<T>().map_err(|_| format!("bad int in {}: {}", key, p))).collect()
    }
}

/// Raw value from the dump; integers are resolved once the word size is known.
#[derive(Clone, Copy)]
enum Raw {
    Int(i64),
    Obj(usize),
}

fn raw(s: &str) -> Result<Raw, String> {
    match s.as_bytes().first() {
        Some(b'i') => Ok(Raw::Int(s[1..].parse().map_err(|_| format!("bad int {}", s))?)),
        Some(b'o') => Ok(Raw::Obj(s[1..].parse().map_err(|_| format!("bad ref {}", s))?)),
        _ => err(format!("bad value {}", s)),
    }
}

fn raws(parts: &[&str]) -> Result<Vec<Raw>, String> {
    let n: usize = parts[0].parse().map_err(|_| "bad count")?;
    if parts.len() != n + 1 {
        return err("bad value list length");
    }
    parts[1..].iter().map(|p| raw(p)).collect()
}

pub fn smi_range(word_bits: u8) -> (i64, i64) {
    if word_bits == 32 { (-(1 << 30), (1 << 30) - 1) } else { (-(1 << 62), (1 << 62) - 1) }
}

pub fn load(text: &str, word_bits: u8) -> Result<Loaded, String> {
    let mut r = Reader { lines: text.lines().peekable() };
    let header = r.line("toit-spec-dump")?;
    if header.get(1) != Some(&"1") {
        return err("unsupported dump version");
    }
    let bc = r.line("bytecodes")?;
    let bytecodes = hex(bc[2])?;
    if bytecodes.len() != bc[1].parse::<usize>().unwrap_or(usize::MAX) {
        return err("bytecode length mismatch");
    }
    let mut names = Names::default();
    let methods = r.line("methods")?;
    let method_count: usize = methods[1].parse().map_err(|_| "bad method count")?;
    let mut method_start = vec![false; bytecodes.len()];
    for _ in 0..method_count {
        let m = r.line("m")?;
        let id: usize = m[1].parse().map_err(|_| "bad method id")?;
        let size: usize = m[2].parse().map_err(|_| "bad method size")?;
        if id >= bytecodes.len() {
            return err("method id out of range");
        }
        method_start[id] = true;
        names.methods.insert(id, (size, m.get(4).unwrap_or(&"?").to_string()));
    }
    let dispatch: Vec<i32> = r.ints("dispatch")?;
    let class_bits: Vec<u16> = r.ints("class_bits")?;
    let class_check_ids: Vec<u16> = r.ints("class_check_ids")?;
    let interface_check_offsets: Vec<u16> = r.ints("interface_check_offsets")?;
    let invoke_offsets: Vec<i32> = r.ints("invoke_bytecode_offsets")?;
    let entry_points: Vec<i32> = r.ints("entry_points")?;
    let builtin_raw = raws(&r.line("builtin_class_ids")?[1..])?;
    let roots_raw = raws(&r.line("roots")?[1..])?;
    let globals_raw = raws(&r.line("globals")?[1..])?;
    let literals_raw = raws(&r.line("literals")?[1..])?;
    r.line("global_max_stack_height")?;
    let pm = r.line("primitive_modules")?;
    let module_count: usize = pm[1].parse().map_err(|_| "bad module count")?;
    for _ in 0..module_count {
        let m = r.line("pm")?;
        let prims = m[3..].iter().map(|s| s.to_string()).collect();
        names.primitives.push((m[1].to_string(), prims));
    }
    let cn = r.line("class_names")?;
    let class_count: usize = cn[1].parse().map_err(|_| "bad class count")?;
    for _ in 0..class_count {
        let c = r.line("c")?;
        names.classes.insert(c[1].parse().map_err(|_| "bad class id")?, c.get(2).unwrap_or(&"?").to_string());
    }
    let ol = r.line("objects")?;
    let object_count: usize = ol[1].parse().map_err(|_| "bad object count")?;

    let builtin: Vec<u16> = builtin_raw
        .iter()
        .map(|v| match v {
            Raw::Int(i) => Ok(*i as u16),
            _ => err("builtin class id is not an int"),
        })
        .collect::<Result<_, _>>()?;
    if builtin.len() != 23 {
        return err("expected 23 builtin class ids");
    }
    let large_integer_class = builtin[crate::interp::LARGE_INTEGER_CLASS];
    let (min, max) = smi_range(word_bits);

    // First pass: object headers and raw contents.
    enum RawBody {
        Fields(bool, Vec<Raw>),
        Bytes(bool, Vec<u8>),
        Double(u64),
        Oddball,
    }
    let mut raw_objects: Vec<(u16, RawBody)> = Vec::with_capacity(object_count);
    for index in 0..object_count {
        let o = r.line("o")?;
        let id: usize = o[1].parse().map_err(|_| "bad object id")?;
        if id != index {
            return err("objects out of order");
        }
        let class_id: u16 = o[2].parse().map_err(|_| "bad class id")?;
        let body = match o[3] {
            "instance" => RawBody::Fields(true, raws(&o[4..])?),
            "array" => RawBody::Fields(false, raws(&o[4..])?),
            "bytes" => RawBody::Bytes(false, hex(o.get(5).copied().unwrap_or("-"))?),
            "string" => RawBody::Bytes(true, hex(o.get(5).copied().unwrap_or("-"))?),
            "double" => RawBody::Double(o[4].parse::<i64>().map_err(|_| "bad double")? as u64),
            "oddball" => RawBody::Oddball,
            k => return err(format!("unknown object kind {}", k)),
        };
        raw_objects.push((class_id, body));
    }
    r.line("end")?;

    // Second pass: resolve integers. Integers outside the smi range become
    // read-only LargeInteger objects appended after the program heap.
    let mut heap: Vec<ExecObj> = Vec::with_capacity(object_count);
    let mut extra: Vec<ExecObj> = Vec::new();
    let resolve = |v: Raw, extra: &mut Vec<ExecObj>| -> Value {
        match v {
            Raw::Obj(id) => Value::Obj(id),
            Raw::Int(i) if min <= i && i <= max => Value::Smi(i),
            Raw::Int(i) => {
                extra.push(ExecObj { class_id: large_integer_class, ro: true, body: ExecBody::LargeInt(i) });
                Value::Obj(object_count + extra.len() - 1)
            }
        }
    };
    for (class_id, body) in raw_objects {
        let body = match body {
            RawBody::Fields(true, f) => ExecBody::Instance(f.into_iter().map(|v| resolve(v, &mut extra)).collect()),
            RawBody::Fields(false, f) => ExecBody::Array(f.into_iter().map(|v| resolve(v, &mut extra)).collect()),
            RawBody::Bytes(false, b) => ExecBody::Bytes(b),
            RawBody::Bytes(true, b) => ExecBody::Str(b),
            RawBody::Double(bits) => ExecBody::Double(bits),
            RawBody::Oddball => ExecBody::Oddball,
        };
        heap.push(ExecObj { class_id, ro: true, body });
    }
    let roots: Vec<Value> = roots_raw.into_iter().map(|v| resolve(v, &mut extra)).collect();
    let globals: Vec<Value> = globals_raw.into_iter().map(|v| resolve(v, &mut extra)).collect();
    let literals: Vec<Value> = literals_raw.into_iter().map(|v| resolve(v, &mut extra)).collect();
    heap.extend(extra);
    for v in roots.iter().chain(globals.iter()).chain(literals.iter()) {
        if let Value::Obj(id) = v {
            if *id >= heap.len() {
                return err("reference out of range");
            }
        }
    }
    if roots.len() != 35 || invoke_offsets.len() != 19 || entry_points.len() != 9 {
        return err("unexpected table sizes");
    }

    let program = ExecProgram {
        word_bits,
        bytecodes,
        method_start,
        dispatch,
        class_bits,
        class_check_ids,
        interface_check_offsets,
        invoke_offsets,
        entry_points,
        builtin,
        roots,
        literals,
    };
    Ok(Loaded { program, heap, globals, names })
}
