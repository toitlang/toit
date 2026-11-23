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
//! program's initial global values. The tables are borrowed, not copied
//! (`Converted::program` is a `VProgram` of slices into the VM's memory;
//! the method table is the VM's records and the bytecodes holding the
//! method headers, `MTable`); only the 23 builtin class ids are decoded.
//! Object references in the roots, globals and literals are followed
//! through the program image, breadth first (a work list, no recursion),
//! and every reachable object becomes one `ExecObj`, one at a time
//! (`Objects`, a `heap_check::ObjStream`: the verdict checks each object
//! as it is converted and keeps none; `collect_heap` keeps them all, for
//! the canonical form). Nothing is interpreted beyond
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
//! toit_spec::interp::loader) is tested by
//! verified/tools/vmverify_differential.toit on every suite program
//! (canonical.rs).
//!
//! No panic paths (README.md, "No panics on devices"): no indexing without
//! `get`, and every allocation is fallible (`toit_spec::xvec`); a failed
//! one ends the conversion with `Malformed::oom` (the verdict
//! OUT_OF_MEMORY).

use alloc::vec::Vec;
use toit_spec::xvec::{try_copy, try_filled, try_push, try_with_capacity, Oom};
use toit_spec::types::{ExecBody, ExecObj, Value};
use toit_spec::v2::heap_check::ObjStream;
use toit_spec::v2::vprog::{MTable, VProgram};
use toit_verified_core::ffi::ProgramTables;
use toit_verified_core::layout::*;

/// `HALF_WORD_SIZE`: string lengths are half words.
const HALF: usize = core::mem::size_of::<toit_verified_core::view::HalfWord>();

/// The program as converted from VM memory: borrowed tables, the decoded
/// builtin class ids, roots, literals, globals, and the program heap as a
/// stream of objects.
pub struct Converted<'a> {
    pub bytecodes: &'a [u8],
    pub methods: MTable<'a>,
    pub max_height: u16,
    pub dispatch: &'a [i32],
    pub class_bits: &'a [u16],
    pub class_check_ids: &'a [u16],
    pub interface_check_offsets: &'a [u16],
    pub invoke_offsets: &'a [i32],
    pub entry_points: &'a [i32],
    pub builtin: Vec<u16>,
    pub roots: Vec<Value>,
    pub literals: Vec<Value>,
    pub globals: Vec<Value>,
    /// The program heap, converted on demand in id order.
    pub objects: Objects<'a>,
    /// The VM's primitive table (arities by module).
    pub prim_arity: Vec<Vec<u8>>,
}

impl<'a> Converted<'a> {
    /// The program, and the object stream (for `x_loaded_ok_stream`).
    pub fn split(&mut self) -> (VProgram<'_>, &mut Objects<'a>) {
        let p = VProgram {
            word_bits: (WORD_SIZE * 8) as u8,
            max_height: self.max_height,
            bytecodes: self.bytecodes,
            methods: self.methods,
            dispatch: self.dispatch,
            class_bits: self.class_bits,
            class_check_ids: self.class_check_ids,
            interface_check_offsets: self.interface_check_offsets,
            invoke_offsets: self.invoke_offsets,
            entry_points: self.entry_points,
            builtin: &self.builtin,
            roots: &self.roots,
            literals: &self.literals,
            unchecked: false,
        };
        (p, &mut self.objects)
    }

    /// Converts every object (from the start of the stream; test support:
    /// the canonical form).
    pub fn collect_heap(&mut self) -> Result<Vec<ExecObj>, Malformed> {
        let mut heap = Vec::new();
        while let Some((o, _)) = self.objects.next_obj() {
            try_push(&mut heap, o)?;
        }
        match self.objects.error.take() {
            Some(e) => Err(e),
            None => Ok(heap),
        }
    }

    pub fn program(&self) -> VProgram<'_> {
        VProgram {
            word_bits: (WORD_SIZE * 8) as u8,
            max_height: self.max_height,
            bytecodes: self.bytecodes,
            methods: self.methods,
            dispatch: self.dispatch,
            class_bits: self.class_bits,
            class_check_ids: self.class_check_ids,
            interface_check_offsets: self.interface_check_offsets,
            invoke_offsets: self.invoke_offsets,
            entry_points: self.entry_points,
            builtin: &self.builtin,
            roots: &self.roots,
            literals: &self.literals,
            unchecked: false,
        }
    }
}

/// Why the memory could not be converted. `detail` is a table index or an
/// offset into the program image. `oom`: not the memory but an allocation
/// of the conversion failed.
#[derive(Debug)]
pub struct Malformed {
    pub what: &'static str,
    pub detail: usize,
    pub oom: bool,
}

impl Malformed {
    pub const fn oom() -> Malformed {
        Malformed { what: "out of memory", detail: 0, oom: true }
    }
}

impl From<Oom> for Malformed {
    fn from(_: Oom) -> Malformed {
        Malformed::oom()
    }
}

fn bad<T>(what: &'static str, detail: usize) -> Result<T, Malformed> {
    // Devices report the reason code only (`text!`): without the texts the
    // linker drops them (0.6 KB).
    let what = if cfg!(feature = "std") { what } else { "" };
    Err(Malformed { what, detail, oom: false })
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
    if len == 0 { &[] } else { core::slice::from_raw_parts(ptr, len) }
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
            // No `unwrap`: its panic message would link the formatting
            // machinery on devices (the length is right by construction).
            Some(b) => match b.try_into() {
                Ok(a) => Ok(usize::from_ne_bytes(a)),
                Err(_) => bad("object extends past the program image", addr.wrapping_sub(self.start)),
            },
            None => bad("object extends past the program image", addr.wrapping_sub(self.start)),
        }
    }

    /// The 64-bit payload (a double's bits, a large integer) starting at
    /// word `k` of the object at `addr` (two words on 32-bit targets).
    fn word64(&self, addr: usize, k: usize) -> Result<u64, Malformed> {
        let at = k.checked_mul(WORD_SIZE).and_then(|o| addr.checked_add(o));
        match at.and_then(|a| self.range(a, 8)) {
            Some(b) => match b.try_into() {
                Ok(a) => Ok(u64::from_ne_bytes(a)),
                Err(_) => bad("object extends past the program image", addr.wrapping_sub(self.start)),
            },
            None => bad("object extends past the program image", addr.wrapping_sub(self.start)),
        }
    }

    fn bytes(&self, addr: usize, len: usize) -> Result<Vec<u8>, Malformed> {
        match self.range(addr, len) {
            Some(b) => Ok(try_copy(b)?),
            None => bad("object content outside the program image", addr.wrapping_sub(self.start)),
        }
    }

    fn string_bytes(&self, addr: usize, len: usize) -> Result<Vec<u8>, Malformed> {
        let storage = len.checked_add(1).and_then(|n| self.range(addr, n));
        match storage.and_then(|bytes| bytes.split_last()) {
            Some((&0, content)) => Ok(try_copy(content)?),
            _ => bad("string lacks a terminator inside the program image", addr.wrapping_sub(self.start)),
        }
    }
}

/// Untagged address -> object id: an open-addressing hash table of ids
/// (`id + 1`, 0 = free) whose addresses are `queue[id]`, at most 3/4 full:
/// 5.3-10.7 bytes per object on 32-bit targets, about half of a `BTreeMap`
/// (the in-VM peak of the verifier, README.md "Memory").
struct IdTable {
    slots: Vec<u32>,
    count: usize,
}

impl IdTable {
    const fn new() -> IdTable {
        IdTable { slots: Vec::new(), count: 0 }
    }

    fn start(addr: usize, mask: usize) -> usize {
        // Fibonacci hashing of the word index.
        ((addr / WORD_SIZE).wrapping_mul(0x9E37_79B9) >> 7) & mask
    }

    /// The id of the object at `addr`, if it has one. (The table's size is
    /// a power of two and every id is below `queue.len()`; the `get`s only
    /// avoid panic paths.)
    fn get(&self, addr: usize, queue: &[usize]) -> Option<usize> {
        if self.slots.is_empty() { return None; }
        let mask = self.slots.len() - 1;
        let mut i = Self::start(addr, mask);
        loop {
            let s = *self.slots.get(i)? as usize;
            if s == 0 { return None; }
            if *queue.get(s - 1)? == addr { return Some(s - 1); }
            i = (i + 1) & mask;
        }
    }

    /// Records `id` (not present yet) for the address `queue[id]`.
    fn insert(&mut self, id: usize, queue: &[usize]) -> Result<(), Malformed> {
        if id >= u32::MAX as usize { return bad("too many objects", id); }
        if (self.count + 1) * 4 > self.slots.len() * 3 {
            let size = if self.slots.is_empty() { 64 } else { self.slots.len() * 2 };
            let old = core::mem::replace(&mut self.slots, try_filled(0, size)?);
            for s in old {
                if s != 0 { self.place(s, queue); }
            }
        }
        self.place(id as u32 + 1, queue);
        self.count += 1;
        Ok(())
    }

    fn place(&mut self, slot: u32, queue: &[usize]) {
        let mask = self.slots.len().wrapping_sub(1);
        let Some(&addr) = queue.get((slot as usize).wrapping_sub(1)) else { return };
        let mut i = Self::start(addr, mask);
        loop {
            match self.slots.get_mut(i) {
                Some(s) if *s == 0 => { *s = slot; return; }
                Some(_) => i = (i + 1) & mask,
                None => return,
            }
        }
    }
}

/// The program heap, breadth first from the roots, globals and literals.
pub struct Objects<'a> {
    image: Image,
    class_bits: &'a [u16],
    /// Untagged address -> object id (index into `queue`).
    ids: IdTable,
    /// Untagged addresses, in id order.
    queue: Vec<usize>,
    /// The next object to convert.
    next: usize,
    /// Why the stream ended early (a malformed object): the program is
    /// rejected.
    pub error: Option<Malformed>,
}

impl<'a> ObjStream for Objects<'a> {
    /// The next object and the number of objects found so far.
    fn next_obj(&mut self) -> Option<(ExecObj, usize)> {
        if self.error.is_some() { return None; }
        let addr = *self.queue.get(self.next)?;
        match self.object(addr) {
            Ok(o) => {
                self.next += 1;
                Some((o, self.queue.len()))
            }
            Err(e) => {
                self.error = Some(e);
                None
            }
        }
    }
}

impl<'a> Objects<'a> {
    /// Every object was converted, without error.
    pub fn complete(&self) -> bool {
        self.error.is_none() && self.next == self.queue.len()
    }

    /// The number of objects converted.
    pub fn count(&self) -> usize {
        self.next
    }

    /// Frees the work list (after the stream).
    pub fn release(&mut self) {
        self.ids = IdTable::new();
        self.queue = Vec::new();
    }

    /// A value as the core sees a word: a smi, or a reference to an object
    /// of the program image (which gets an id).
    fn value(&mut self, w: usize) -> Result<Value, Malformed> {
        if w & SMI_TAG_MASK == SMI_TAG {
            return Ok(Value::Smi(((w as isize) >> SMI_TAG_SIZE) as i64));
        }
        if w & NON_SMI_TAG_MASK != HEAP_TAG {
            return bad("a word is neither a smi nor an object reference", w);
        }
        let addr = w - HEAP_TAG;
        if addr < self.image.start || addr >= self.image.end || (addr - self.image.start) % WORD_SIZE != 0 {
            return bad("an object reference is not a word in the program image", w);
        }
        if let Some(id) = self.ids.get(addr, &self.queue) {
            return Ok(Value::Obj(id));
        }
        let id = self.queue.len();
        try_push(&mut self.queue, addr)?;
        self.ids.insert(id, &self.queue)?;
        Ok(Value::Obj(id))
    }

    fn values(&mut self, words: &[usize]) -> Result<Vec<Value>, Malformed> {
        let mut r = try_with_capacity(words.len())?;
        for &w in words {
            try_push(&mut r, self.value(w)?)?;
        }
        Ok(r)
    }

    /// The object at untagged address `addr`.
    fn object(&mut self, addr: usize) -> Result<ExecObj, Malformed> {
        let offset = addr - self.image.start;
        let header = self.image.word(addr, HEADER_WORD)?;
        if header & SMI_TAG_MASK != SMI_TAG {
            return bad("object header is not a smi", offset);
        }
        let header = ((header as isize) >> SMI_TAG_SIZE) as i64;
        let tag = ((header >> CLASS_TAG_OFFSET) as usize) & CLASS_TAG_MASK;
        let class_id = header >> CLASS_ID_OFFSET;
        let Some(&bits) = usize::try_from(class_id).ok().and_then(|c| self.class_bits.get(c)) else {
            return bad("object class id outside the class table", offset);
        };
        if (bits as usize) & CLASS_TAG_MASK != tag {
            return bad("object tag differs from its class's tag", offset);
        }
        let body = match tag {
            INSTANCE_TAG | TASK_TAG => {
                let fields = ((bits >> CLASS_ID_OFFSET) & INSTANCE_SIZE_MASK) as usize;
                if fields == 0 {
                    return bad("instance class without a header word", offset);
                }
                let mut f = try_with_capacity(fields - 1)?;
                for k in 0..fields - 1 {
                    let w = self.image.word(addr, INSTANCE_FIELDS_WORD + k)?;
                    try_push(&mut f, self.value(w)?)?;
                }
                ExecBody::Instance(f)
            }
            ARRAY_TAG => {
                let length = self.image.word(addr, ARRAY_LENGTH_WORD)?;
                // The elements must be in the image before any is read.
                self.image.word(addr, ARRAY_ELEMENTS_WORD.saturating_add(length).saturating_sub(1))?;
                let mut e = try_with_capacity(length)?;
                for k in 0..length {
                    let w = self.image.word(addr, ARRAY_ELEMENTS_WORD + k)?;
                    try_push(&mut e, self.value(w)?)?;
                }
                ExecBody::Array(e)
            }
            BYTE_ARRAY_TAG => {
                // The core's heap model (verified/core/TRUSTED.md V5): a byte
                // array is `Bytes` exactly when it is internal, or external
                // with the raw-bytes tag at a non-null address (whose content
                // must then lie in the image); any other external byte array
                // (a mapped file, a resource proxy) is an opaque object
                // without contents, as `Heap::bytes_len` sees it.
                let raw = self.image.word(addr, BYTE_ARRAY_LENGTH_WORD)? as isize;
                if raw >= 0 {
                    ExecBody::Bytes(self.image.bytes(addr + BYTE_ARRAY_CONTENT_BYTE, raw as usize)?)
                } else {
                    let length = (-1 - raw) as usize;
                    let tag = self.image.word(addr, BYTE_ARRAY_EXTERNAL_TAG_WORD)?;
                    let content = self.image.word(addr, BYTE_ARRAY_EXTERNAL_ADDRESS_WORD)?;
                    if tag == RAW_BYTE_TAG && content != 0 {
                        ExecBody::Bytes(self.image.bytes(content, length)?)
                    } else {
                        ExecBody::Oddball
                    }
                }
            }
            STRING_TAG => {
                // A half word: 32 bits on 64-bit targets, 16 on 32-bit ones.
                let Some(at) = self.image.range(addr + STRING_INTERNAL_LENGTH_BYTE, HALF) else {
                    return bad("string header outside the program image", offset);
                };
                let internal = match (at.len(), at) {
                    (4, &[a, b, c, d]) => u32::from_ne_bytes([a, b, c, d]) as usize,
                    (2, &[a, b]) => u16::from_ne_bytes([a, b]) as usize,
                    _ => return bad("string header outside the program image", offset),
                };
                if internal != STRING_SENTINEL {
                    ExecBody::Str(self.image.string_bytes(addr + STRING_CONTENT_BYTE, internal)?)
                } else {
                    let length = self.image.word(addr, STRING_EXTERNAL_LENGTH_WORD)?;
                    let content = self.image.word(addr, STRING_EXTERNAL_ADDRESS_WORD)?;
                    ExecBody::Str(self.image.string_bytes(content, length)?)
                }
            }
            DOUBLE_TAG => ExecBody::Double(self.image.word64(addr, DOUBLE_VALUE_WORD)?),
            LARGE_INTEGER_TAG => ExecBody::LargeInt(self.image.word64(addr, LARGE_INTEGER_VALUE_WORD)? as i64),
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
/// tables for their layout.rs counts), and the tables and the program
/// image must be mapped and unchanged while the result lives.
pub unsafe fn convert<'a>(p: &ProgramTables, prims: &PrimitiveArities) -> Result<Converted<'a>, Malformed> {
    if p.roots_length != ROOT_COUNT {
        return bad("unexpected number of roots", p.roots_length);
    }
    if p.global_max_height > 0xffff {
        return bad("global max stack height too large", p.global_max_height);
    }
    let bytecodes: &'a [u8] = table(p.bytecodes, p.bytecodes_length);
    let methods = MTable { code: bytecodes, recs: table(p.methods, p.methods_length) };
    let builtin_words: &[usize] = table(p.builtin_class_ids, BUILTIN_COUNT);
    let mut builtin = try_with_capacity(BUILTIN_COUNT)?;
    for (i, &w) in builtin_words.iter().enumerate() {
        let v = ((w as isize) >> SMI_TAG_SIZE) as i64;
        if w & SMI_TAG_MASK != SMI_TAG || !(0..=0xffff).contains(&v) {
            return bad("builtin class id is not a class id", i);
        }
        try_push(&mut builtin, v as u16)?;
    }
    let Some(end) = p.program_heap_start.checked_add(p.program_heap_size) else {
        return bad("program image wraps around", 0);
    };
    let mut c = Objects {
        image: Image {
            start: p.program_heap_start,
            end,
        },
        class_bits: table(p.class_bits, p.class_bits_length),
        ids: IdTable::new(),
        queue: Vec::new(),
        next: 0,
        error: None,
    };
    // The order of the dump: roots, globals, literals.
    let roots = c.values(table(p.roots, ROOT_COUNT))?;
    let globals = c.values(table(p.globals, p.globals_length))?;
    let literals = c.values(table(p.literals, p.literals_length))?;
    let mut arity = try_with_capacity(prims.counts.len())?;
    let mut at = 0usize;
    for (module, &n) in prims.counts.iter().enumerate() {
        let n = n as usize;
        match at.checked_add(n).and_then(|e| prims.arities.get(at..e)) {
            Some(a) => try_push(&mut arity, try_copy(a)?)?,
            None => return bad("primitive table shorter than its counts", module),
        }
        at += n;
    }
    Ok(Converted {
        bytecodes,
        methods,
        max_height: p.global_max_height as u16,
        dispatch: table(p.dispatch, p.dispatch_length),
        class_bits: c.class_bits,
        class_check_ids: table(p.class_check_ids, p.class_check_ids_length),
        interface_check_offsets: table(p.interface_check_offsets, p.interface_check_offsets_length),
        invoke_offsets: table(p.invoke_offsets, INVOKE_OFFSET_COUNT),
        entry_points: table(p.entry_points, ENTRY_POINT_COUNT),
        builtin,
        roots,
        literals,
        globals,
        objects: c,
        prim_arity: arity,
    })
}

// The fixtures are laid out for 64-bit words (32-bit targets are covered by
// the 32-bit host runs of the VM, verified/core/PROGRESS.md "Phase 5").
#[cfg(all(test, target_pointer_width = "64"))]
mod tests {
    use super::*;

    // Class 0: an instance class with 2 fields (size 3 words); class 1: an
    // array class; class 2: a byte-array class.
    const CLASS_BITS: [u16; 4] = [
        (3 << CLASS_ID_OFFSET) as u16 | INSTANCE_TAG as u16,
        ARRAY_TAG as u16,
        BYTE_ARRAY_TAG as u16,
        STRING_TAG as u16,
    ];

    fn smi(v: i64) -> usize { (v << SMI_TAG_SIZE) as usize }
    fn header(class_id: usize, tag: usize) -> usize { smi(((class_id << CLASS_ID_OFFSET) | tag) as i64) }

    struct Fixture {
        image: Vec<usize>,
        roots: Vec<usize>,
        builtin: Vec<usize>,
        invoke: Vec<i32>,
        entry: Vec<i32>,
        methods: Vec<u32>,
        globals: Vec<usize>,
        literals: Vec<usize>,
    }

    impl Fixture {
        /// An image with: word 0 an instance of class 0 with fields [smi 7,
        /// ref to the array]; word 3 an array of length 2 [smi 1, ref to
        /// the instance]; word 7 a byte array of 3 bytes.
        fn new() -> Fixture {
            Fixture::sized(10)
        }

        /// As `new`, with `words` words of image (at least 10).
        fn sized(words: usize) -> Fixture {
            let mut f = Fixture {
                image: vec![0; words],
                roots: vec![smi(0); ROOT_COUNT],
                builtin: vec![smi(0); BUILTIN_COUNT],
                invoke: vec![0; INVOKE_OFFSET_COUNT],
                entry: vec![0; ENTRY_POINT_COUNT],
                methods: Vec::new(),
                globals: Vec::new(),
                literals: Vec::new(),
            };
            let base = f.image.as_ptr() as usize;
            f.image[0] = header(0, INSTANCE_TAG);
            f.image[1] = smi(7);
            f.image[2] = base + 3 * WORD_SIZE + HEAP_TAG;
            f.image[3] = header(1, ARRAY_TAG);
            f.image[4] = 2;
            f.image[5] = smi(1);
            f.image[6] = base + HEAP_TAG;
            f.image[7] = header(2, BYTE_ARRAY_TAG);
            f.image[8] = 3;
            f.image[9] = usize::from_ne_bytes([1, 2, 3, 0, 0, 0, 0, 0]);
            f.globals.push(base + HEAP_TAG);
            f.literals.push(base + 7 * WORD_SIZE + HEAP_TAG);
            f
        }

        fn tables(&self) -> ProgramTables {
            ProgramTables {
                bytecodes: std::ptr::null(),
                bytecodes_length: 0,
                methods: self.methods.as_ptr(),
                methods_length: self.methods.len(),
                dispatch: std::ptr::null(),
                dispatch_length: 0,
                class_bits: CLASS_BITS.as_ptr(),
                class_bits_length: CLASS_BITS.len(),
                class_check_ids: std::ptr::null(),
                class_check_ids_length: 0,
                interface_check_offsets: std::ptr::null(),
                interface_check_offsets_length: 0,
                invoke_offsets: self.invoke.as_ptr(),
                entry_points: self.entry.as_ptr(),
                builtin_class_ids: self.builtin.as_ptr(),
                roots: self.roots.as_ptr(),
                roots_length: ROOT_COUNT,
                literals: self.literals.as_ptr(),
                literals_length: self.literals.len(),
                globals: self.globals.as_ptr() as *mut usize,
                globals_length: self.globals.len(),
                program_heap_start: self.image.as_ptr() as usize,
                program_heap_size: self.image.len() * WORD_SIZE,
                remembered_set_bias: 0,
                global_max_height: 5,
                stack_array_word: 0,
            }
        }

        /// The converted program and its heap.
        fn convert(&self) -> Result<(Converted<'_>, Vec<ExecObj>), Malformed> {
            let prims = PrimitiveArities { counts: &[], arities: &[] };
            let mut c = unsafe { convert(&self.tables(), &prims) }?;
            let heap = c.collect_heap()?;
            Ok((c, heap))
        }
    }

    #[test]
    fn converts_objects_breadth_first() {
        let f = Fixture::new();
        let (l, heap) = f.convert().unwrap();
        // Globals first (the roots are smis): the instance is object 0, the
        // literal byte array 1, the array (reached through the instance) 2.
        assert_eq!(heap.len(), 3);
        assert!(matches!(l.globals[0], Value::Obj(0)));
        assert!(matches!(l.literals[0], Value::Obj(1)));
        match &heap[0].body {
            ExecBody::Instance(fields) => {
                assert!(matches!(fields[..], [Value::Smi(7), Value::Obj(2)]));
            }
            _ => panic!("not an instance"),
        }
        match &heap[1].body {
            ExecBody::Bytes(b) => assert_eq!(b, &vec![1, 2, 3]),
            _ => panic!("not bytes"),
        }
        match &heap[2].body {
            ExecBody::Array(e) => assert!(matches!(e[..], [Value::Smi(1), Value::Obj(0)])),
            _ => panic!("not an array"),
        }
        assert!(heap.iter().all(|o| o.ro));
    }

    #[test]
    fn rejects_references_outside_the_image() {
        let mut f = Fixture::new();
        f.image[2] = f.image.as_ptr() as usize + 10 * WORD_SIZE + HEAP_TAG;
        assert!(f.convert().is_err());
        let mut f = Fixture::new();
        f.image[2] = f.image.as_ptr() as usize + 4 + HEAP_TAG;  // Not word aligned.
        assert!(f.convert().is_err());
        let mut f = Fixture::new();
        f.globals[0] = 3;  // Neither a smi nor a heap reference.
        assert!(f.convert().is_err());
    }

    #[test]
    fn rejects_objects_past_the_image() {
        let mut f = Fixture::new();
        f.image[4] = 1 << 40;  // Array length past the end of the image.
        assert!(f.convert().is_err());
        let mut f = Fixture::new();
        f.image[8] = 100;  // Byte-array content past the end of the image.
        assert!(f.convert().is_err());
        let mut f = Fixture::new();
        f.image[8] = (-1i64 - 3) as usize;  // External, content address 0.
        f.image[9] = 0;
        assert!(f.convert().is_err());
    }

    #[test]
    fn models_external_byte_arrays_as_the_core() {
        // Word 7: an external byte array of 3 bytes (address word 9, tag
        // word 10); its content at word 11.
        let external = |tag: usize, content: bool| {
            let mut f = Fixture::sized(12);
            let base = f.image.as_ptr() as usize;
            f.image[8] = (-1i64 - 3) as usize;
            f.image[9] = if content { base + 11 * WORD_SIZE } else { 0 };
            f.image[10] = tag;
            f.image[11] = usize::from_ne_bytes([4, 5, 6, 0, 0, 0, 0, 0]);
            f
        };
        // Raw bytes in the image: a byte array of the model.
        let f = external(RAW_BYTE_TAG, true);
        let (_, heap) = f.convert().unwrap();
        match &heap[1].body {
            ExecBody::Bytes(b) => assert_eq!(b, &vec![4, 5, 6]),
            _ => panic!("not bytes"),
        }
        // A mapped file or another external tag, or raw bytes without an
        // address: opaque (TRUSTED.md V5), never bytes.
        for (tag, content) in [(MAPPED_FILE_TAG, true), (1, true), (RAW_BYTE_TAG, false)] {
            let f = external(tag, content);
            let (_, heap) = f.convert().unwrap();
            assert!(matches!(heap[1].body, ExecBody::Oddball), "tag {} content {}", tag, content);
        }
        // Raw bytes whose content lies outside the image: rejected.
        let mut f = external(RAW_BYTE_TAG, true);
        f.image[9] = 8;
        assert!(f.convert().is_err());
    }

    #[test]
    fn checks_the_terminator_of_internal_and_external_strings() {
        for external in [false, true] {
            let mut f = Fixture::sized(if external { 12 } else { 10 });
            f.image[7] = header(3, STRING_TAG);
            let length_at = 7 + STRING_INTERNAL_LENGTH_BYTE / WORD_SIZE;
            let mut halves = f.image[length_at].to_ne_bytes();
            let offset = STRING_INTERNAL_LENGTH_BYTE % WORD_SIZE;
            let mut set_length = |f: &mut Fixture, n: usize| {
                let internal = if external { STRING_SENTINEL } else { n };
                halves[offset..offset + HALF].copy_from_slice(&(internal as u32).to_ne_bytes());
                f.image[length_at] = usize::from_ne_bytes(halves);
                if external {
                    f.image[7 + STRING_EXTERNAL_LENGTH_WORD] = n;
                    f.image[7 + STRING_EXTERNAL_ADDRESS_WORD] = f.image.as_ptr() as usize + 11 * WORD_SIZE;
                }
            };
            let data = f.image.len() - 1;
            f.image[data] = usize::from_ne_bytes([b'a', 0, b'b', 0, 0, 0, 0, 0]);
            set_length(&mut f, 3);
            let (_, heap) = f.convert().unwrap();
            assert!(matches!(&heap[1].body, ExecBody::Str(bytes) if bytes == b"a\0b"));
            set_length(&mut f, 2);
            assert!(f.convert().is_err());
            set_length(&mut f, WORD_SIZE);
            assert!(f.convert().is_err());
        }
    }

    #[test]
    fn rejects_headers_that_disagree_with_the_class() {
        let mut f = Fixture::new();
        f.image[3] = header(0, ARRAY_TAG);  // Class 0 is an instance class.
        assert!(f.convert().is_err());
        let mut f = Fixture::new();
        f.image[3] = header(9, ARRAY_TAG);  // No class 9.
        assert!(f.convert().is_err());
        let mut f = Fixture::new();
        f.image[3] = header(1, STACK_TAG);  // Not program data.
        assert!(f.convert().is_err());
    }
}
