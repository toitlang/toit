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

//! TRUSTED: the abstract program and initial heap, built directly from the
//! memory the verified core executes.
//!
//! The input is the `toit_v2_program` struct the VM hands to `toit_v2_run`
//! (filled by the same C++ function, `v2_program_tables`), with the
//! program's initial global values. Every table is copied as is; object
//! references in the roots, globals and literals are followed through the
//! program image, breadth first (a work list, no recursion), and every
//! reachable object becomes one `ExecObj`. Nothing is interpreted beyond
//! what the core itself reads: an object's kind is its header's class tag
//! (which must agree with its class), an instance has the field count of
//! its class (`class_bits`), as the core's `instance_fields` computes it.
//!
//! Every read is bounds-checked against the program image
//! `[program_heap_start, program_heap_start + program_heap_size)`: a
//! malformed image (a flash image is not re-read by the snapshot reader)
//! makes the conversion fail, never read elsewhere.
//!
//! The correspondence with the dump path (tools/spec_dump.toit and
//! toit_spec::interp::loader) is tested by tests/differential.py on every
//! suite program (canonical.rs).

use std::collections::HashMap;
use toit_spec::interp::loader::{Loaded, Names};
use toit_spec::types::{ExecBody, ExecObj, ExecProgram, MethodInfo, Value};
use toit_verified_core::ffi::{ProgramTables, V2Method};
use toit_verified_core::layout::*;

/// Why the memory could not be converted. `detail` is a table index or an
/// offset into the program image.
#[derive(Debug)]
pub struct Malformed {
    pub what: &'static str,
    pub detail: usize,
}

fn bad<T>(what: &'static str, detail: usize) -> Result<T, Malformed> {
    Err(Malformed { what, detail })
}

/// The VM's primitive table: the arity of every primitive, by module.
pub struct PrimitiveArities<'a> {
    pub counts: &'a [u32],
    pub arities: &'a [u8],
}

/// A table of the VM as a slice.
///
/// # Safety
/// `ptr..ptr+len` must be readable and unchanged while the slice lives.
unsafe fn table<'a, T>(ptr: *const T, len: usize) -> &'a [T] {
    if len == 0 { &[] } else { std::slice::from_raw_parts(ptr, len) }
}

/// The program image: all reads of objects go through it.
struct Image {
    start: usize,
    end: usize,
}

impl Image {
    /// The byte range `[addr, addr + len)`, if it lies in the image.
    fn range(&self, addr: usize, len: usize) -> Option<&'static [u8]> {
        let last = addr.checked_add(len)?;
        if addr < self.start || last > self.end { return None; }
        // SAFETY: inside the program image, which is mapped and immutable
        // while the program is loaded.
        Some(unsafe { table(addr as *const u8, len) })
    }

    /// Word `k` of the object at untagged address `addr`.
    fn word(&self, addr: usize, k: usize) -> Result<usize, Malformed> {
        let at = k.checked_mul(WORD_SIZE).and_then(|o| addr.checked_add(o));
        match at.and_then(|a| self.range(a, WORD_SIZE)) {
            Some(b) => Ok(usize::from_ne_bytes(b.try_into().unwrap())),
            None => bad("object extends past the program image", addr.wrapping_sub(self.start)),
        }
    }

    fn bytes(&self, addr: usize, len: usize) -> Result<Vec<u8>, Malformed> {
        match self.range(addr, len) {
            Some(b) => Ok(b.to_vec()),
            None => bad("object content outside the program image", addr.wrapping_sub(self.start)),
        }
    }
}

struct Converter<'a> {
    image: Image,
    class_bits: &'a [u16],
    /// Untagged address -> object id (index into `queue`).
    ids: HashMap<usize, usize>,
    /// Untagged addresses, in id order.
    queue: Vec<usize>,
}

impl<'a> Converter<'a> {
    /// A value as the core sees a word: a smi, or a reference to an object
    /// of the program image (which gets an id).
    fn value(&mut self, w: usize) -> Result<Value, Malformed> {
        if w & SMI_TAG_MASK == SMI_TAG {
            return Ok(Value::Smi((w as i64) >> SMI_TAG_SIZE));
        }
        if w & NON_SMI_TAG_MASK != HEAP_TAG {
            return bad("a word is neither a smi nor an object reference", w);
        }
        let addr = w - HEAP_TAG;
        if addr < self.image.start || addr >= self.image.end || (addr - self.image.start) % WORD_SIZE != 0 {
            return bad("an object reference is not a word in the program image", w);
        }
        if let Some(&id) = self.ids.get(&addr) {
            return Ok(Value::Obj(id));
        }
        let id = self.queue.len();
        self.ids.insert(addr, id);
        self.queue.push(addr);
        Ok(Value::Obj(id))
    }

    fn values(&mut self, words: &[usize]) -> Result<Vec<Value>, Malformed> {
        words.iter().map(|&w| self.value(w)).collect()
    }

    /// The object at untagged address `addr`.
    fn object(&mut self, addr: usize) -> Result<ExecObj, Malformed> {
        let offset = addr - self.image.start;
        let header = self.image.word(addr, HEADER_WORD)?;
        if header & SMI_TAG_MASK != SMI_TAG {
            return bad("object header is not a smi", offset);
        }
        let header = (header as i64) >> SMI_TAG_SIZE;
        let tag = ((header >> CLASS_TAG_OFFSET) as usize) & CLASS_TAG_MASK;
        let class_id = header >> CLASS_ID_OFFSET;
        if class_id < 0 || class_id as usize >= self.class_bits.len() {
            return bad("object class id outside the class table", offset);
        }
        let bits = self.class_bits[class_id as usize];
        if (bits as usize) & CLASS_TAG_MASK != tag {
            return bad("object tag differs from its class's tag", offset);
        }
        let body = match tag {
            INSTANCE_TAG | TASK_TAG => {
                let fields = ((bits >> CLASS_ID_OFFSET) & INSTANCE_SIZE_MASK) as usize;
                if fields == 0 {
                    return bad("instance class without a header word", offset);
                }
                let mut f = Vec::with_capacity(fields - 1);
                for k in 0..fields - 1 {
                    let w = self.image.word(addr, INSTANCE_FIELDS_WORD + k)?;
                    f.push(self.value(w)?);
                }
                ExecBody::Instance(f)
            }
            ARRAY_TAG => {
                let length = self.image.word(addr, ARRAY_LENGTH_WORD)?;
                // The elements must be in the image before any is read.
                self.image.word(addr, ARRAY_ELEMENTS_WORD.saturating_add(length).saturating_sub(1))?;
                let mut e = Vec::with_capacity(length);
                for k in 0..length {
                    let w = self.image.word(addr, ARRAY_ELEMENTS_WORD + k)?;
                    e.push(self.value(w)?);
                }
                ExecBody::Array(e)
            }
            BYTE_ARRAY_TAG => {
                let raw = self.image.word(addr, BYTE_ARRAY_LENGTH_WORD)? as isize;
                if raw >= 0 {
                    ExecBody::Bytes(self.image.bytes(addr + BYTE_ARRAY_CONTENT_BYTE, raw as usize)?)
                } else {
                    let length = (-1 - raw) as usize;
                    let content = self.image.word(addr, BYTE_ARRAY_EXTERNAL_ADDRESS_WORD)?;
                    ExecBody::Bytes(self.image.bytes(content, length)?)
                }
            }
            STRING_TAG => {
                let at = self.image.range(addr + STRING_INTERNAL_LENGTH_BYTE, 4)
                    .ok_or(Malformed { what: "string header outside the program image", detail: offset })?;
                let internal = u32::from_ne_bytes(at.try_into().unwrap()) as usize;
                if internal != STRING_SENTINEL {
                    ExecBody::Str(self.image.bytes(addr + STRING_CONTENT_BYTE, internal)?)
                } else {
                    let length = self.image.word(addr, STRING_EXTERNAL_LENGTH_WORD)?;
                    let content = self.image.word(addr, STRING_EXTERNAL_ADDRESS_WORD)?;
                    ExecBody::Str(self.image.bytes(content, length)?)
                }
            }
            DOUBLE_TAG => ExecBody::Double(self.image.word(addr, DOUBLE_VALUE_WORD)? as u64),
            LARGE_INTEGER_TAG => ExecBody::LargeInt(self.image.word(addr, LARGE_INTEGER_VALUE_WORD)? as i64),
            ODDBALL_TAG => ExecBody::Oddball,
            // Stacks (and anything else) are not program data.
            _ => return bad("object of a machine class in the program image", offset),
        };
        Ok(ExecObj { class_id: class_id as u16, ro: true, body })
    }
}

/// Builds the abstract program, its heap and its initial globals from the
/// tables the core executes.
///
/// # Safety
/// Every pointer of `p` must be valid for its length (the fixed-size
/// tables for their layout.rs counts), and the program image must be
/// mapped and unchanged during the call.
pub unsafe fn convert(p: &ProgramTables, prims: &PrimitiveArities) -> Result<(Loaded, Vec<Vec<u8>>), Malformed> {
    if p.roots_length != ROOT_COUNT {
        return bad("unexpected number of roots", p.roots_length);
    }
    if p.global_max_height > 0xffff {
        return bad("global max stack height too large", p.global_max_height);
    }
    let methods: &[V2Method] = table(p.methods, p.methods_length);
    let builtin_words: &[usize] = table(p.builtin_class_ids, BUILTIN_COUNT);
    let mut builtin = Vec::with_capacity(BUILTIN_COUNT);
    for (i, &w) in builtin_words.iter().enumerate() {
        let v = (w as i64) >> SMI_TAG_SIZE;
        if w & SMI_TAG_MASK != SMI_TAG || !(0..=0xffff).contains(&v) {
            return bad("builtin class id is not a class id", i);
        }
        builtin.push(v as u16);
    }
    let mut c = Converter {
        image: Image {
            start: p.program_heap_start,
            end: p.program_heap_start.checked_add(p.program_heap_size)
                .ok_or(Malformed { what: "program image wraps around", detail: 0 })?,
        },
        class_bits: table(p.class_bits, p.class_bits_length),
        ids: HashMap::new(),
        queue: Vec::new(),
    };
    // The order of the dump: roots, globals, literals.
    let roots = c.values(table(p.roots, ROOT_COUNT))?;
    let globals = c.values(table(p.globals, p.globals_length))?;
    let literals = c.values(table(p.literals, p.literals_length))?;
    let mut heap = Vec::new();
    let mut next = 0;
    while next < c.queue.len() {
        let addr = c.queue[next];
        heap.push(c.object(addr)?);
        next += 1;
    }
    let program = ExecProgram {
        word_bits: (WORD_SIZE * 8) as u8,
        bytecodes: table(p.bytecodes, p.bytecodes_length).to_vec(),
        // Format 2 has no method-start bitmap.
        method_start: Vec::new(),
        dispatch: table(p.dispatch, p.dispatch_length).to_vec(),
        class_bits: c.class_bits.to_vec(),
        class_check_ids: table(p.class_check_ids, p.class_check_ids_length).to_vec(),
        interface_check_offsets: table(p.interface_check_offsets, p.interface_check_offsets_length).to_vec(),
        invoke_offsets: table(p.invoke_offsets, INVOKE_OFFSET_COUNT).to_vec(),
        entry_points: table(p.entry_points, ENTRY_POINT_COUNT).to_vec(),
        builtin,
        roots,
        literals,
        methods: methods.iter().map(|m| MethodInfo {
            arity: m.arity,
            kind: m.kind,
            max_height: p.global_max_height as u16,
            selector: m.selector,
            aux: m.aux,
            recv_start: m.recv_start,
            recv_end: m.recv_end,
            entry: m.entry as usize,
            end: m.end as usize,
        }).collect(),
    };
    let mut arity = Vec::with_capacity(prims.counts.len());
    let mut at = 0usize;
    for (module, &n) in prims.counts.iter().enumerate() {
        let n = n as usize;
        match prims.arities.get(at..at + n) {
            Some(a) => arity.push(a.to_vec()),
            None => return bad("primitive table shorter than its counts", module),
        }
        at += n;
    }
    let loaded = Loaded { format: 2, program, heap, globals, names: Names::default() };
    Ok((loaded, arity))
}
