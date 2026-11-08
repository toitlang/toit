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

/// Format 2: the spec's lengths agree with the interpreter's table and with
/// the disassembler's table in tools/snapshot.toit (BYTE-CODES-V2), and the
/// numbers shared with format 1 keep their names.
#[test]
fn opcode_table_v2_matches_snapshot_toit() {
    use toit_spec::v2::bytecodes::*;
    let tool = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../tools/snapshot.toit"))
        .expect("cannot read tools/snapshot.toit");
    let start = tool.find("BYTE-CODES-V2 ::= [").expect("BYTE-CODES-V2");
    let end = start + tool[start..].find("\n]").expect("end of BYTE-CODES-V2");
    let mut found = Vec::new();
    for line in tool[start..end].lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("Bytecode \"") {
            let name = rest.split('"').next().unwrap().to_string();
            let length: u8 = rest.split('"').nth(1).unwrap().split_whitespace().next().unwrap().parse().expect("length");
            found.push((name, length));
        }
    }
    assert_eq!(found.len(), OPCODE_COUNT2 as usize, "number of format-2 opcodes");
    for (i, (name, length)) in found.iter().enumerate() {
        assert_eq!(OPCODE_NAMES2[i], name, "name of format-2 opcode {}", i);
        assert_eq!(OPCODE_LENGTHS2[i], *length, "length of {}", name);
        assert_eq!(exec_opcode_length2(i as u8), *length as usize, "spec length of {}", name);
        let shared = !(i == STORE_FIELD_THIS as usize || i == TRY as usize || i == LOAD_FIELD_THIS as usize);
        if shared {
            assert_eq!(toit_spec::bytecodes::OPCODE_NAMES[i], name, "format-1 name of opcode {}", i);
        }
    }
}
