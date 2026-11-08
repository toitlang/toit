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

//! Cross-checks the opcode table of the spec against `src/bytecodes.h`.

use toit_spec::bytecodes::*;

#[test]
fn opcode_table_matches_bytecodes_h() {
    let header = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../src/bytecodes.h"))
        .expect("cannot read src/bytecodes.h");
    let mut found = Vec::new();
    for line in header.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("BYTECODE(") {
            let parts: Vec<&str> = rest.split(',').map(|p| p.trim()).collect();
            let name = parts[0].to_string();
            let length: u8 = parts[1].parse().expect("length");
            found.push((name, length));
        }
    }
    assert_eq!(found.len(), OPCODE_COUNT as usize, "number of opcodes");
    for (i, (name, length)) in found.iter().enumerate() {
        assert_eq!(OPCODE_NAMES[i], name, "name of opcode {}", i);
        assert_eq!(OPCODE_LENGTHS[i], *length, "length of {}", name);
        assert_eq!(exec_opcode_length(i as u8), *length as usize, "spec length of {}", name);
    }
}
