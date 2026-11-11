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

//! Test support (not on the verification path): the verifier's FFI input
//! (`toit_vmverify_input` with its `toit_v2_program` tables and the
//! program image) saved to a file and loaded back into owned buffers, so
//! that a fuzz driver (src/bin/toit_vmverify_fuzz.rs) can call
//! `toit_vmverify_verify` in-process on mutated copies of the exact memory
//! the VM hands the verifier.
//!
//! `toit.run --emit-canonical=FILE.tables PROGRAM` writes the file (any
//! other name writes the canonical form). Object references in the tables
//! and the image are relocated to the loaded image.

use crate::ffi::VerifyInput;
use toit_verified_core::ffi::{ProgramTables, V2Method};
use toit_verified_core::layout::*;

const MAGIC: &[u8; 8] = b"TVMTBL01";

unsafe fn bytes<'a, T>(ptr: *const T, len: usize) -> &'a [u8] {
    if len == 0 { &[] } else { std::slice::from_raw_parts(ptr as *const u8, len * std::mem::size_of::<T>()) }
}

/// Writes `input` (tables, image, primitive table) to `path`.
///
/// # Safety
/// As `toit_vmverify_verify`.
pub unsafe fn save(input: &VerifyInput, path: &str) -> std::io::Result<()> {
    let p = &*input.program;
    let mut out: Vec<u8> = Vec::new();
    out.extend_from_slice(MAGIC);
    let header = [
        WORD_SIZE, p.bytecodes_length, p.methods_length, p.dispatch_length, p.class_bits_length,
        p.class_check_ids_length, p.interface_check_offsets_length, p.literals_length, p.globals_length,
        p.program_heap_start, p.program_heap_size, p.global_max_height, input.prim_module_count,
        input.prim_arities_length, input.trusted,
    ];
    for h in header {
        out.extend_from_slice(&(h as u64).to_le_bytes());
    }
    out.extend_from_slice(bytes(p.bytecodes, p.bytecodes_length));
    out.extend_from_slice(bytes(p.methods, p.methods_length));
    out.extend_from_slice(bytes(p.dispatch, p.dispatch_length));
    out.extend_from_slice(bytes(p.class_bits, p.class_bits_length));
    out.extend_from_slice(bytes(p.class_check_ids, p.class_check_ids_length));
    out.extend_from_slice(bytes(p.interface_check_offsets, p.interface_check_offsets_length));
    out.extend_from_slice(bytes(p.invoke_offsets, INVOKE_OFFSET_COUNT));
    out.extend_from_slice(bytes(p.entry_points, ENTRY_POINT_COUNT));
    out.extend_from_slice(bytes(p.builtin_class_ids, BUILTIN_COUNT));
    out.extend_from_slice(bytes(p.roots, ROOT_COUNT));
    out.extend_from_slice(bytes(p.literals, p.literals_length));
    out.extend_from_slice(bytes(p.globals as *const usize, p.globals_length));
    out.extend_from_slice(bytes(p.program_heap_start as *const u8, p.program_heap_size));
    out.extend_from_slice(bytes(input.prim_counts, input.prim_module_count));
    out.extend_from_slice(bytes(input.prim_arities, input.prim_arities_length));
    std::fs::write(path, out)
}

/// Owned copies of the verifier's input; `input()` points into them.
pub struct Tables {
    pub bytecodes: Vec<u8>,
    pub methods: Vec<V2Method>,
    pub dispatch: Vec<i32>,
    pub class_bits: Vec<u16>,
    pub class_check_ids: Vec<u16>,
    pub interface_check_offsets: Vec<u16>,
    pub invoke_offsets: Vec<i32>,
    pub entry_points: Vec<i32>,
    pub builtin: Vec<usize>,
    pub roots: Vec<usize>,
    pub literals: Vec<usize>,
    pub globals: Vec<usize>,
    /// The program image, in words (so it is word aligned).
    pub image: Vec<usize>,
    pub image_bytes: usize,
    pub global_max_height: usize,
    pub prim_counts: Vec<u32>,
    pub prim_arities: Vec<u8>,
    pub trusted: bool,
}

struct Reader<'a> {
    data: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], String> {
        let end = self.at.checked_add(n).filter(|e| *e <= self.data.len()).ok_or("truncated tables file")?;
        let r = &self.data[self.at..end];
        self.at = end;
        Ok(r)
    }

    fn u64(&mut self) -> Result<usize, String> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()) as usize)
    }

    fn vec<T: Copy>(&mut self, n: usize) -> Result<Vec<T>, String> {
        let size = std::mem::size_of::<T>();
        let raw = self.take(n.checked_mul(size).ok_or("bad length")?)?;
        let mut v: Vec<T> = Vec::with_capacity(n);
        // SAFETY: T is plain old data (integers, V2Method) of `size` bytes.
        unsafe {
            std::ptr::copy_nonoverlapping(raw.as_ptr(), v.as_mut_ptr() as *mut u8, raw.len());
            v.set_len(n);
        }
        Ok(v)
    }
}

impl Tables {
    pub fn load(path: &str) -> Result<Tables, String> {
        let data = std::fs::read(path).map_err(|e| format!("{}: {}", path, e))?;
        let mut r = Reader { data: &data, at: 0 };
        if r.take(8)? != MAGIC {
            return Err(format!("{}: not a tables file", path));
        }
        let mut h = [0usize; 15];
        for x in h.iter_mut() {
            *x = r.u64()?;
        }
        let [word, nb, nm, nd, ncb, ncc, nico, nl, ng, start, size, gmh, npm, npa, trusted] = h;
        if word != WORD_SIZE {
            return Err("word size differs".into());
        }
        let mut t = Tables {
            bytecodes: r.vec(nb)?,
            methods: r.vec(nm)?,
            dispatch: r.vec(nd)?,
            class_bits: r.vec(ncb)?,
            class_check_ids: r.vec(ncc)?,
            interface_check_offsets: r.vec(nico)?,
            invoke_offsets: r.vec(INVOKE_OFFSET_COUNT)?,
            entry_points: r.vec(ENTRY_POINT_COUNT)?,
            builtin: r.vec(BUILTIN_COUNT)?,
            roots: r.vec(ROOT_COUNT)?,
            literals: r.vec(nl)?,
            globals: r.vec(ng)?,
            image: Vec::new(),
            image_bytes: size,
            global_max_height: gmh,
            prim_counts: Vec::new(),
            prim_arities: Vec::new(),
            trusted: trusted != 0,
        };
        let raw = r.take(size)?;
        t.image = vec![0usize; size.div_ceil(WORD_SIZE)];
        // SAFETY: the image buffer has at least `size` bytes.
        unsafe { std::ptr::copy_nonoverlapping(raw.as_ptr(), t.image.as_mut_ptr() as *mut u8, size) };
        t.prim_counts = r.vec(npm)?;
        t.prim_arities = r.vec(npa)?;
        t.relocate(start);
        Ok(t)
    }

    /// A copy, with the references moved to the copy's image.
    pub fn duplicate(&self) -> Tables {
        let mut t = Tables {
            bytecodes: self.bytecodes.clone(),
            methods: self.methods.clone(),
            dispatch: self.dispatch.clone(),
            class_bits: self.class_bits.clone(),
            class_check_ids: self.class_check_ids.clone(),
            interface_check_offsets: self.interface_check_offsets.clone(),
            invoke_offsets: self.invoke_offsets.clone(),
            entry_points: self.entry_points.clone(),
            builtin: self.builtin.clone(),
            roots: self.roots.clone(),
            literals: self.literals.clone(),
            globals: self.globals.clone(),
            image: self.image.clone(),
            image_bytes: self.image_bytes,
            global_max_height: self.global_max_height,
            prim_counts: self.prim_counts.clone(),
            prim_arities: self.prim_arities.clone(),
            trusted: self.trusted,
        };
        t.relocate(self.start());
        t
    }

    fn start(&self) -> usize {
        self.image.as_ptr() as usize
    }

    /// Moves references into the image from `old` (the VM's address) to
    /// the loaded copy: tagged references, and untagged word-aligned
    /// addresses (external byte-array contents).
    fn relocate(&mut self, old: usize) {
        let new = self.start();
        let end = old + self.image_bytes;
        let fix = |w: &mut usize| {
            if *w & NON_SMI_TAG_MASK == HEAP_TAG {
                let a = *w - HEAP_TAG;
                if old <= a && a < end { *w = a - old + new + HEAP_TAG; }
            } else if *w & (WORD_SIZE - 1) == 0 && old <= *w && *w < end {
                *w = *w - old + new;
            }
        };
        self.roots.iter_mut().for_each(fix);
        self.literals.iter_mut().for_each(fix);
        self.globals.iter_mut().for_each(fix);
        self.image.iter_mut().for_each(fix);
    }

    /// The verifier's input over these buffers. `tables` must outlive the
    /// returned input's use.
    pub fn input(&mut self, tables: &mut ProgramTables) -> VerifyInput {
        *tables = ProgramTables {
            bytecodes: self.bytecodes.as_ptr(),
            bytecodes_length: self.bytecodes.len(),
            methods: self.methods.as_ptr(),
            methods_length: self.methods.len(),
            dispatch: self.dispatch.as_ptr(),
            dispatch_length: self.dispatch.len(),
            class_bits: self.class_bits.as_ptr(),
            class_bits_length: self.class_bits.len(),
            class_check_ids: self.class_check_ids.as_ptr(),
            class_check_ids_length: self.class_check_ids.len(),
            interface_check_offsets: self.interface_check_offsets.as_ptr(),
            interface_check_offsets_length: self.interface_check_offsets.len(),
            invoke_offsets: self.invoke_offsets.as_ptr(),
            entry_points: self.entry_points.as_ptr(),
            builtin_class_ids: self.builtin.as_ptr(),
            roots: self.roots.as_ptr(),
            roots_length: self.roots.len(),
            literals: self.literals.as_ptr(),
            literals_length: self.literals.len(),
            globals: self.globals.as_mut_ptr(),
            globals_length: self.globals.len(),
            program_heap_start: self.start(),
            program_heap_size: self.image_bytes,
            remembered_set_bias: 0,
            global_max_height: self.global_max_height,
            stack_array_word: 0,
        };
        VerifyInput {
            program: tables as *const ProgramTables,
            prim_counts: self.prim_counts.as_ptr(),
            prim_module_count: self.prim_counts.len(),
            prim_arities: self.prim_arities.as_ptr(),
            prim_arities_length: self.prim_arities.len(),
            trusted: self.trusted as usize,
            certificate: core::ptr::null(),
            certificate_length: 0,
        }
    }
}
