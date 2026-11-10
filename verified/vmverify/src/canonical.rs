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

//! A canonical text form of an abstract program, its heap and globals, for
//! the differential test (verified/tools/vmverify_differential.toit) of the
//! two ways to build them: from VM memory (`from_vm`) and from a dump
//! (`toit_spec::interp::loader`). Test code, not on the verification path.
//!
//! Object ids are renumbered breadth first from the roots, the globals and
//! the literals (in that order), so the numbering and objects nothing
//! references do not matter. Large integers are printed as values
//! (`L<value>`): the dump has them as integers (the loader creates one
//! object per occurrence), the VM as shared heap objects.

use std::collections::HashMap;
use std::fmt::Write;
use toit_spec::types::{ExecBody, ExecObj, Value};
use toit_spec::v2::vprog::VProgram;

fn hex(out: &mut String, bytes: &[u8]) {
    if bytes.is_empty() {
        out.push('-');
    }
    for b in bytes {
        let _ = write!(out, "{:02x}", b);
    }
}

fn list<T: std::fmt::Display>(out: &mut String, name: &str, values: &[T]) {
    let _ = write!(out, "{} {}", name, values.len());
    for v in values {
        let _ = write!(out, " {}", v);
    }
    out.push('\n');
}

struct Numbering<'a> {
    heap: &'a [ExecObj],
    ids: HashMap<usize, usize>,
    order: Vec<usize>,
}

impl<'a> Numbering<'a> {
    fn value(&mut self, out: &mut String, v: &Value) {
        match v {
            Value::Smi(i) => { let _ = write!(out, " i{}", i); }
            Value::Obj(id) => {
                if let Some(o) = self.heap.get(*id) {
                    if let ExecBody::LargeInt(i) = o.body {
                        let _ = write!(out, " L{}", i);
                        return;
                    }
                }
                let next = self.ids.len();
                let c = *self.ids.entry(*id).or_insert_with(|| next);
                if c == next { self.order.push(*id); }
                let _ = write!(out, " o{}", c);
            }
            other => { let _ = write!(out, " ?{:?}", std::mem::discriminant(other)); }
        }
    }

    fn values(&mut self, out: &mut String, name: &str, vs: &[Value]) {
        let _ = write!(out, "{} {}", name, vs.len());
        for v in vs {
            self.value(out, v);
        }
        out.push('\n');
    }
}

/// The canonical form. `prim_arity` is the primitive table the verifier
/// uses for this program.
pub fn canonical(p: &VProgram, heap: &[ExecObj], globals: &[Value], prim_arity: &[Vec<u8>]) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "format {} word_bits {}", 2, p.word_bits);
    let _ = write!(out, "bytecodes {} ", p.bytecodes.len());
    hex(&mut out, &p.bytecodes);
    out.push('\n');
    let _ = writeln!(out, "methods {}", p.methods.len());
    for m in p.methods {
        let _ = writeln!(out, "m {} {} {} {} {} {} {} {} {}", m.arity, m.kind, p.max_height, m.selector, m.aux,
                         m.recv_start, m.recv_end, m.entry, m.end);
    }
    list(&mut out, "dispatch", p.dispatch);
    list(&mut out, "class_bits", p.class_bits);
    list(&mut out, "class_check_ids", p.class_check_ids);
    list(&mut out, "interface_check_offsets", p.interface_check_offsets);
    list(&mut out, "invoke_offsets", p.invoke_offsets);
    list(&mut out, "entry_points", p.entry_points);
    list(&mut out, "builtin", p.builtin);
    let _ = writeln!(out, "primitive_modules {}", prim_arity.len());
    for a in prim_arity {
        list(&mut out, "pm", a);
    }
    let mut n = Numbering { heap, ids: HashMap::new(), order: Vec::new() };
    n.values(&mut out, "roots", p.roots);
    n.values(&mut out, "globals", globals);
    n.values(&mut out, "literals", p.literals);
    // Breadth first: printing an object numbers the objects it references.
    let mut objects = String::new();
    let mut next = 0;
    while next < n.order.len() {
        let id = n.order[next];
        let o = &heap[id];
        let _ = write!(objects, "o {} {} {}", next, o.class_id, o.ro);
        match &o.body {
            ExecBody::Instance(f) => n.values(&mut objects, " instance", f),
            ExecBody::Array(e) => n.values(&mut objects, " array", e),
            ExecBody::Bytes(b) => { objects.push_str(" bytes "); hex(&mut objects, b); objects.push('\n'); }
            ExecBody::Str(b) => { objects.push_str(" string "); hex(&mut objects, b); objects.push('\n'); }
            ExecBody::Double(bits) => { let _ = writeln!(objects, " double {}", bits); }
            ExecBody::LargeInt(i) => { let _ = writeln!(objects, " large {}", i); }
            ExecBody::Oddball => objects.push_str(" oddball\n"),
            _ => objects.push_str(" machine-object\n"),
        }
        next += 1;
    }
    let _ = writeln!(out, "objects {}", n.order.len());
    out.push_str(&objects);
    out
}
