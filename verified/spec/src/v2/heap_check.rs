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

//! The loader's well-formedness of the program heap (`v2::soundness::
//! wf_loaded`), checked on a loaded program (plain Rust, part of the
//! trusted loader): object classes exist, instances of instance classes
//! have their class's field count, every reference in the heap, the roots,
//! the literals and the globals is in range, and the heap has no machine
//! objects (suspended stacks, unwinding tokens, tasks).

use crate::interp::loader::Loaded;
use crate::types::*;

fn good(heap_len: usize, v: &Value) -> bool {
    match v {
        Value::Smi(_) => true,
        Value::Obj(id) => *id < heap_len,
        _ => false,
    }
}

pub fn check_heap(l: &Loaded) -> Result<(), String> {
    let p = &l.program;
    let n = l.heap.len();
    let class_count = p.class_bits.len();
    for (id, o) in l.heap.iter().enumerate() {
        let cl = o.class_id as usize;
        if cl >= class_count {
            return Err(format!("object {} has class {} outside the class table", id, cl));
        }
        if cl == p.builtin[19] as usize {
            return Err(format!("object {} is a task", id));
        }
        let bits = p.class_bits[cl];
        let fields = ((bits >> 5) & 0x7ff) as i64 - 1;
        if (bits & 0xf == 2 || bits & 0xf == 8) && fields >= 1 {
            match &o.body {
                ExecBody::Instance(f) if f.len() as i64 == fields => {}
                _ => return Err(format!("object {} of instance class {} does not have {} fields", id, cl, fields)),
            }
        }
        match &o.body {
            ExecBody::Instance(f) | ExecBody::Array(f) => {
                if !f.iter().all(|v| good(n, v)) {
                    return Err(format!("object {} has a bad reference", id));
                }
            }
            ExecBody::Stack(..) | ExecBody::Stack2(..) | ExecBody::Pending(_) => {
                return Err(format!("object {} is a machine object", id));
            }
            _ => {}
        }
    }
    for (what, vs) in [("roots", &p.roots), ("literals", &p.literals), ("globals", &l.globals)] {
        if !vs.iter().all(|v| good(n, v)) {
            return Err(format!("bad reference in the {}", what));
        }
    }
    Ok(())
}
