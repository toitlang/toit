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
    /// Header offset -> (absolute bci of the first instruction, end of
    /// the body, name).
    pub methods: BTreeMap<usize, (usize, usize, String)>,
    pub classes: BTreeMap<u16, String>,
    /// Module name and primitive names, by module index.
    pub primitives: Vec<(String, Vec<String>)>,
}

impl Names {
    /// The method containing absolute bci `bci`: its header offset (the
    /// method id of format 1), its entry and its name.
    pub fn method_at(&self, bci: usize) -> Option<(usize, usize, &str)> {
        self.methods
            .range(..=bci)
            .next_back()
            .filter(|(_, (_, end, _))| bci <= *end)
            .map(|(id, (entry, _, name))| (*id, *entry, name.as_str()))
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
    /// Bytecode format: 1 or 2.
    pub format: u8,
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
    let format: u8 = match header.get(1) {
        Some(&"1") => 1,
        Some(&"2") => 2,
        _ => return err("unsupported dump version"),
    };
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
        // Format 2 has no method-start bitmap: method ids are indices into
        // the method table, which is read from the bytecodes below.
        if format == 1 {
            method_start[id] = true;
        }
        // Format 2: the entry and the end are fixed below, from the method
        // table.
        names.methods.insert(id, (id + 4, id + 4 + size, m.get(4).unwrap_or(&"?").to_string()));
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
    let gm = r.line("global_max_stack_height")?;
    let global_max_height: u16 = gm.get(1).and_then(|h| h.parse().ok()).ok_or("bad global max stack height")?;
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
    // Format 2: the method table is the records of the last literal and the
    // headers they point at (format note 21).
    let (method_table, recs) = if format == 2 {
        let literal = match literals.last() {
            Some(Value::Obj(id)) => match &heap[*id].body {
                ExecBody::Bytes(b) => b.clone(),
                _ => return err("no method table literal"),
            },
            _ => return err("no method table literal"),
        };
        let recs = table_literal_records(&literal, bytecodes.len())?;
        (method_table_v2(&bytecodes, &recs, global_max_height)?, recs)
    } else {
        (Vec::new(), Vec::new())
    };
    if format == 2 {
        if method_table.len() != names.methods.len() {
            return err("the method table and the debug names disagree");
        }
        let mut header = V2_TAG.len();
        for (info, (id, (entry, end, _))) in method_table.iter().zip(names.methods.iter_mut()) {
            if *id != header {
                return err("a debug name is not at a method header");
            }
            *entry = info.entry;
            *end = info.end;
            header = info.end;
        }
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
        methods: method_table,
        recs,
    };
    if format == 2 {
        check_tables_v2(&program)?;
    }
    Ok(Loaded { format, program, heap, globals, names })
}

pub const V2_TAG: &[u8; 4] = b"TBC2";
/// The method table literal (format note 21, `V2MethodTable` in
/// src/interpreter_v2.h): marker, count, bytecodes length, 0, then the
/// records.
pub const V2_TABLE_MARKER: u32 = 0x3254_4d54; // "TMT2".

/// The records of a format-2 program's method table, from the bytes of its
/// last literal.
pub fn table_literal_records(literal: &[u8], bytecodes_length: usize) -> Result<Vec<u32>, String> {
    let word = |i: usize| u32::from_le_bytes([literal[i], literal[i + 1], literal[i + 2], literal[i + 3]]);
    if literal.len() < 16 || word(0) != V2_TABLE_MARKER {
        return err("no method table literal");
    }
    let count = word(4) as usize;
    if word(8) as usize != bytecodes_length || literal.len() != 16 + 4 * count {
        return err("malformed method table literal");
    }
    Ok((0..count).map(|i| word(16 + 4 * i)).collect())
}

/// Decodes the method table of a format-2 program from its records and
/// the method headers (format note 21), with the loader's checks of
/// `V2MethodTable::compute` (src/v2_method_table.cc): every header inside
/// the bytecodes before its entry, the methods back to back from the tag
/// on with nonempty bodies, every header in its canonical form. The
/// decoding is the verified `vprog::MTable::at`. Every method gets the
/// program's `global_max_height`, which bounds them all.
pub fn method_table_v2(bytecodes: &[u8], recs: &[u32], global_max_height: u16) -> Result<Vec<MethodInfo>, String> {
    use crate::v2::vprog::*;
    if bytecodes.len() < 4 || &bytecodes[0..4] != V2_TAG {
        return err("format-2 bytecodes must start with the tag TBC2");
    }
    if bytecodes.len() >= 0x100_0000 {
        return err("bytecodes too large");
    }
    if recs.is_empty() || recs.len() >= 0x100_0000 {
        return err("bad method count");
    }
    let table = MTable { code: bytecodes, recs };
    let mut header = V2_TAG.len();
    let mut methods = Vec::new();
    for (i, &r) in recs.iter().enumerate() {
        let entry = (r >> RECORD_ENTRY_SHIFT) as usize;
        if entry <= header || entry >= bytecodes.len() {
            return err(format!("bad method entry {}", i));
        }
        let b = bytecodes[entry - 1];
        if b & !(KIND_MASK | KIND_SINGLE) != 0 || (b & KIND_SINGLE != 0 && b & KIND_MASK != 0) {
            return err("bad method kind byte");
        }
        if entry < x_hdr_size(b) || entry - x_hdr_size(b) != header {
            return err(format!("method {} does not follow the previous one", i));
        }
        if b != 3 && entry % 2 == 0 {
            return err(format!("method {} has an even entry (unaligned header fields)", i));
        }
        let m = table.at(i);
        let (rs, re) = (m.recv_start as u32, m.recv_end as u32);
        let range_ok = match b & KIND_MASK {
            // A method: one class or none, or a range of at least two.
            0 => b & KIND_SINGLE != 0 || (rs < 0xffff && rs + 1 < re),
            // An accessor: a range, or none.
            1 => if rs == 0xffff { re == 0xffff } else { rs < re },
            _ => true,
        };
        if !range_ok {
            return err("bad receiver range");
        }
        if m.end() <= entry || m.end() > bytecodes.len() {
            return err(format!("empty or truncated body of method {}", i));
        }
        header = m.end();
        methods.push(MethodInfo {
            arity: m.arity,
            kind: m.kind,
            max_height: global_max_height,
            selector: m.selector,
            aux: m.aux,
            recv_start: m.recv_start,
            recv_end: m.recv_end,
            entry,
            end: m.end(),
        });
    }
    Ok(methods)
}

/// The loader's part of the well-formedness of a format-2 program
/// (`v2::wf_program`): table shapes and method references in the tables.
/// Everything else is the structural verifier's job.
fn check_tables_v2(p: &ExecProgram) -> Result<(), String> {
    if p.methods.is_empty() || p.methods.len() >= 0x1000_0000 {
        return err("bad method count");
    }
    for &d in &p.dispatch {
        if d != -1 && !(0 <= d && (d as usize) < p.methods.len()) {
            return err("dispatch entry is not a method index");
        }
    }
    if p.literals.len() < 7 {
        return err("format-2 programs have the failure strings as literals 2..6");
    }
    // Two of the verifier's table checks (`v2::verifier::tables_ok`,
    // `this_field_ok`), done here so that every program the tests load
    // exercises them: virtual dispatch respects declared receiver ranges,
    // and the classes of a receiver range have the fields LOAD_FIELD_THIS
    // and STORE_FIELD_THIS use. Also: every method body is a sequence of
    // whole instructions.
    let class_count = p.class_bits.len() as i64;
    for (d, &t) in p.dispatch.iter().enumerate() {
        if t < 0 { continue; }
        let info = p.methods[t as usize];
        if info.selector == 0xffff || info.recv_start == 0xffff { continue; }
        let cl = d as i64 - info.selector as i64;
        if 0 <= cl && cl < class_count && !(info.recv_start as i64 <= cl && cl < info.recv_end as i64) {
            return err(format!("dispatch entry {} (class {}) outside the receiver range of method {}", d, cl, t));
        }
    }
    for (m, info) in p.methods.iter().enumerate() {
        let mut bci = info.entry;
        let mut last = 0xff;
        while bci < info.end {
            let op = p.bytecodes[bci];
            last = op;
            if op as usize >= crate::v2::bytecodes::OPCODE_LENGTHS2.len() {
                return err(format!("bad opcode {} in method {}", op, m));
            }
            if op == crate::v2::bytecodes::LOAD_FIELD_THIS || op == crate::v2::bytecodes::STORE_FIELD_THIS {
                let f = p.bytecodes[bci + 1] as i64;
                if info.recv_start == 0xffff {
                    return err(format!("method {} uses this without a receiver range", m));
                }
                for cl in info.recv_start as i64..(info.recv_end as i64).min(class_count) {
                    let fields = ((p.class_bits[cl as usize] >> 5) & 0x7ff) as i64 - 1;
                    if f >= fields {
                        return err(format!("method {}: class {} has no field {}", m, cl, f));
                    }
                }
            }
            bci += crate::v2::bytecodes::OPCODE_LENGTHS2[op as usize] as usize;
        }
        if bci != info.end {
            return err(format!("method {}: the last instruction crosses the end", m));
        }
        use crate::v2::bytecodes::*;
        if ![RETURN, RETURN_NULL, THROW, BRANCH, BRANCH_BACK, INVOKE_STATIC_TAIL, INVOKE_LAMBDA_TAIL,
             INVOKE_INITIALIZER_TAIL, NON_LOCAL_RETURN, NON_LOCAL_BRANCH].contains(&last) {
            return err(format!("method {} does not end in a terminator", m));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::v2::vprog::*;

    /// The bytecodes and records of methods given as (header bytes in
    /// address order, arity, body length).
    fn program(methods: &[(&[u8], u8, usize)]) -> (Vec<u8>, Vec<u32>) {
        let mut b = V2_TAG.to_vec();
        let mut recs = Vec::new();
        for (header, arity, body) in methods {
            b.extend_from_slice(header);
            recs.push((b.len() as u32) << 8 | *arity as u32);
            b.extend(std::iter::repeat(91).take(*body));
        }
        (b, recs)
    }

    #[test]
    fn decodes_every_field() {
        // A method of arity 2 with selector 300, receiver range [129, 131)
        // and a 1-byte body; a lambda capturing 3 with a 131-byte body; a
        // field accessor for field 5 with receiver range [7, 8); a static
        // method (no selector, no receiver); a block of arity 1.
        let (b, recs) = program(&[
            (&[131, 0, 129, 0, 0x2c, 0x01, 0], 2, 1),
            (&[3, 0, 2], 1, 131),
            (&[5, 0, 8, 0, 7, 0, 0xff, 0xff, 1], 1, 1),
            (&[0xff, 0xff, 0xff, 0xff, KIND_SINGLE], 0, 2),
            (&[3], 1, 1),
        ]);
        let t = method_table_v2(&b, &recs, 9).unwrap();
        assert_eq!(t.len(), 5);
        assert_eq!((t[0].arity, t[0].kind, t[0].selector, t[0].recv_start, t[0].recv_end), (2, 0, 300, 129, 131));
        assert_eq!((t[0].entry, t[0].end, t[0].max_height), (11, 12, 9));
        assert_eq!((t[1].kind, t[1].aux, t[1].selector, t[1].recv_start, t[1].end - t[1].entry), (2, 3, 0xffff, 0xffff, 131));
        assert_eq!((t[2].kind, t[2].aux, t[2].recv_start, t[2].recv_end, t[2].arity, t[2].selector), (1, 5, 7, 8, 1, 0xffff));
        assert_eq!((t[3].kind, t[3].selector, t[3].recv_start, t[3].recv_end, t[3].end - t[3].entry), (0, 0xffff, 0xffff, 0xffff, 2));
        assert_eq!((t[4].kind, t[4].arity, t[4].selector, t[4].recv_start, t[4].end), (3, 1, 0xffff, 0xffff, b.len()));
    }

    #[test]
    fn rejects_malformed_headers() {
        let bad: &[(&[u8], u8, usize)] = &[
            (&[0x8], 0, 1),                                  // Unknown kind byte bit.
            (&[0, 0, 3 | KIND_SINGLE], 0, 1),                // A block with the single bit.
            (&[4, 0, 3, 0, 0xff, 0xff, 0], 0, 1),            // Range of one class in the long form.
            (&[4, 0, 0xff, 0xff, 0xff, 0xff, 0], 0, 1),      // Range from 0xffff.
            (&[0, 0, 3, 0, 3, 0, 0xff, 0xff, 1], 0, 1),      // An accessor with an empty range.
            (&[2], 0, 0),                                    // Lambda without its captured count.
        ];
        for m in bad {
            let (b, recs) = program(&[*m]);
            assert!(method_table_v2(&b, &recs, 0).is_err(), "{:?}", m.0);
        }
        // Not back to back: a gap after the tag.
        let (mut b, mut recs) = program(&[(&[3], 1, 1)]);
        b.insert(4, 0);
        recs[0] += 1;
        assert!(method_table_v2(&b, &recs, 0).is_err());
        // A method with an even entry (after a block with a 2-byte body).
        let (b, recs) = program(&[(&[3], 1, 2), (&[0xff, 0xff, 0xff, 0xff, KIND_SINGLE], 0, 1)]);
        assert_eq!(recs[1] >> 8, 12);
        assert!(method_table_v2(&b, &recs, 0).is_err());
        // An entry past the bytecodes.
        let (b, _) = program(&[(&[3], 1, 1)]);
        assert!(method_table_v2(&b, &[0x10000], 0).is_err());
    }
}
