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

//! Prints the canonical form (canonical.rs) of a dumped program
//! (tools/spec_dump.toit), read with the reference loader
//! (toit_spec::interp::loader), with the verifier's generated primitive
//! table. The other side of verified/tools/vmverify_differential.toit.
//!
//! Usage: toit_vmverify_canonical <dump> <out>

use toit_spec::interp::loader;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() != 2 {
        eprintln!("Usage: toit_vmverify_canonical <dump> <out>");
        std::process::exit(2);
    }
    let text = std::fs::read_to_string(&args[0]).unwrap_or_else(|e| {
        eprintln!("cannot read {}: {}", args[0], e);
        std::process::exit(2);
    });
    let loaded = loader::load(&text, 64).unwrap_or_else(|e| {
        eprintln!("cannot load {}: {}", args[0], e);
        std::process::exit(1);
    });
    let arity: Vec<Vec<u8>> = toit_spec::v2::prim_arity::PRIM_TABLE.iter()
        .map(|(_, prims)| prims.iter().map(|(_, a)| *a).collect())
        .collect();
    let e = &loaded.program;
    let h = toit_spec::v2::vprog::max_height_of(e);
    let methods = toit_spec::v2::vprog::vmethods_of(e, h).unwrap_or_else(|| {
        eprintln!("cannot convert the method table of {}", args[0]);
        std::process::exit(1);
    });
    let p = toit_spec::v2::vprog::vprogram_of(e, methods, h);
    let text = toit_vmverify::canonical::canonical(&p, &loaded.heap, &loaded.globals, &arity);
    if std::fs::write(&args[1], text).is_err() {
        eprintln!("cannot write {}", args[1]);
        std::process::exit(2);
    }
}
