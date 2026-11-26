// Copyright (C) 2026 Toit contributors.

//! Loads a program from a tables file (`toit.run --verify
//! --emit-canonical=X.tables`) into the verifier's `VProgram`, as the VM's
//! verifier entry point does (`toit_vmverify_verify`).

use toit_spec::v2::vprog::VProgram;
use toit_verified_core::ffi::ProgramTables;
use toit_vmverify::from_vm::{self, Converted, PrimitiveArities};
use toit_vmverify::tables::Tables;

pub struct Loaded {
    // Owned buffers the converted program points into (keep alive).
    _tables: Box<Tables>,
    _pt: Box<ProgramTables>,
    pub conv: Converted<'static>,
    pub counts: &'static [u32],
    pub arities: &'static [u8],
    pub global_count: u64,
    pub prim_arity: Vec<Vec<u8>>,
    pub trusted: bool,
}

impl Loaded {
    pub fn load(path: &str) -> Loaded {
        let mut tables = Box::new(Tables::load(path).unwrap_or_else(|e| panic!("{}", e)));
        let mut pt: Box<ProgramTables> = Box::new(unsafe { std::mem::zeroed() });
        let input = tables.input(&mut pt);
        let counts: &'static [u32] = if input.prim_module_count == 0 { &[] } else {
            unsafe { std::slice::from_raw_parts(input.prim_counts, input.prim_module_count) }
        };
        let arities: &'static [u8] = if input.prim_arities_length == 0 { &[] } else {
            unsafe { std::slice::from_raw_parts(input.prim_arities, input.prim_arities_length) }
        };
        let prims = PrimitiveArities { counts, arities };
        let conv = match unsafe { from_vm::convert(&*input.program, &prims) } {
            Ok(c) => c,
            Err(e) => panic!("{}: malformed tables: {} {}", path, e.what, e.detail),
        };
        let global_count = conv.globals.len() as u64;
        let prim_arity = conv.prim_arity.clone();
        let trusted = input.trusted != 0 || std::env::var("F3STUDY_TRUSTED").is_ok();
        Loaded { _tables: tables, _pt: pt, conv, counts, arities, global_count, prim_arity, trusted }
    }

    /// Converts the VM tables again (the loader step `from_vm::convert`).
    pub fn reconvert(&self) -> Converted<'static> {
        let prims = PrimitiveArities { counts: self.counts, arities: self.arities };
        match unsafe { from_vm::convert(&*self._pt, &prims) } { Ok(c) => c, Err(_) => panic!("convert") }
    }

    pub fn program(&self) -> VProgram<'_> {
        let mut p = self.conv.program();
        p.unchecked = self.trusted;
        p
    }
}
