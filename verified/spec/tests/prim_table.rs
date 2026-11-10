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

//! Cross-checks the verifier's primitive table (`v2::prim_arity`) against
//! `src/primitive.h`, and the task primitive numbers the soundness theorem
//! uses.

use toit_spec::v2::prim_arity::PRIM_TABLE;

#[test]
fn prim_table_matches_primitive_h() {
    let header = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../src/primitive.h"))
        .expect("cannot read src/primitive.h");
    // Module order from MODULES(M).
    let mut modules: Vec<(String, String)> = Vec::new();
    for line in header.lines() {
        let t = line.trim();
        if let Some(rest) = t.strip_prefix("M(") {
            let parts: Vec<&str> = rest.split(|c| c == ',' || c == ')').map(|p| p.trim()).collect();
            modules.push((parts[0].to_string(), parts[1].to_string()));
        }
    }
    assert_eq!(modules.len(), PRIM_TABLE.len(), "number of modules");
    for (i, (name, macro_name)) in modules.iter().enumerate() {
        assert_eq!(PRIM_TABLE[i].0, name, "module {}", i);
        let start = header.find(&format!("#define {}(PRIMITIVE)", macro_name)).expect("module define");
        let mut prims: Vec<(String, u8)> = Vec::new();
        for line in header[start..].lines().skip(1) {
            let t = line.trim();
            if let Some(rest) = t.strip_prefix("PRIMITIVE(") {
                let parts: Vec<&str> = rest.split(|c| c == ',' || c == ')').map(|p| p.trim()).collect();
                prims.push((parts[0].to_string(), parts[1].parse().expect("arity")));
            } else {
                break;
            }
        }
        let table: Vec<(String, u8)> = PRIM_TABLE[i].1.iter().map(|(n, a)| (n.to_string(), *a)).collect();
        assert_eq!(table, prims, "primitives of module {}", name);
    }
    let core = PRIM_TABLE[0].1;
    assert_eq!(core[toit_spec::v2::verifier::X_PRIM_TASK_NEW as usize], ("task_new", 1));
    assert_eq!(core[toit_spec::v2::verifier::X_PRIM_TASK_TRANSFER as usize], ("task_transfer", 2));
}
