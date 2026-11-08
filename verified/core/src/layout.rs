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

//! Every constant the Rust core assumes about the C++ VM.
//!
//! Each constant is exported by name through `ffi::toit_vcore_layout_entry`
//! and compared against the C++ headers by `verified/layout_check.cc`, which
//! runs as part of the build. Add new assumptions here, never inline.

use vstd::prelude::*;

verus! {

// --- Frames (src/interpreter.h) -------------------------------------------
/// Words pushed by a call: return address, then frame marker.
pub const FRAME_SIZE: usize = 2;
/// Slot of the frame marker, relative to the stack pointer after a call.
pub const FRAME_MARKER_SLOT: usize = 0;
/// Slot of the return address (a raw bcp), relative to the stack pointer
/// after a call.
pub const RETURN_ADDRESS_SLOT: usize = 1;

// --- Try/finally link frames (src/interpreter.h) --------------------------
pub const LINK_REASON_SLOT: usize = 1;
pub const LINK_TARGET_SLOT: usize = 2;
pub const LINK_RESULT_SLOT: usize = 3;
/// Number of words `LINK` pushes.
pub const LINK_WORDS: usize = 4;

// --- Smis (src/objects.h) ------------------------------------------------
pub const SMI_TAG_SIZE: usize = 1;
pub const SMI_TAG_MASK: usize = 1;
pub const SMI_TAG: usize = 0;
/// `1 << SMI_TAG_SIZE`: Smi::from(v) is `v * SMI_SCALE` for non-negative v.
pub const SMI_SCALE: usize = 2;

/// Smi::from(0xbeef): initial "result" word pushed by LINK.
pub const SMI_LINK_RESULT_INIT: usize = 0xbeef * 2;
/// Smi::from(-0xdead): initial "target" word pushed by LINK.
pub const SMI_LINK_TARGET_INIT: usize = usize::MAX - (0xdead * 2 - 1);
/// Smi::from(-1): "normal unwind" reason pushed by LINK.
pub const SMI_LINK_REASON_INIT: usize = usize::MAX - 1;

// --- Block references (src/top.h, src/interpreter.h) ---------------------
pub const BLOCK_SALT: usize = 0x01020304;

// --- Method headers (src/objects.h, class Method) ------------------------
pub const METHOD_KIND_HEIGHT_OFFSET: usize = 1;
/// max_height = (header[KIND_HEIGHT_OFFSET] >> KIND_BITS) * HEIGHT_SCALE.
pub const METHOD_KIND_BITS_DIVISOR: u8 = 4;
pub const METHOD_HEIGHT_SCALE: usize = 4;
pub const METHOD_ENTRY_OFFSET: usize = 4;

// --- Opcodes and lengths (src/bytecodes.h) -------------------------------
pub const OP_LOAD_LOCAL: u8 = 0;
pub const OP_LOAD_LOCAL_WIDE: u8 = 1;
pub const OP_STORE_LOCAL: u8 = 3;
pub const OP_LOAD_OUTER: u8 = 5;
pub const OP_STORE_OUTER: u8 = 6;
pub const OP_LOAD_LOCAL_0: u8 = 14;
pub const OP_LOAD_LOCAL_1: u8 = 15;
pub const OP_LOAD_LOCAL_2: u8 = 16;
pub const OP_LOAD_LOCAL_3: u8 = 17;
pub const OP_LOAD_LOCAL_4: u8 = 18;
pub const OP_LOAD_LOCAL_5: u8 = 19;
pub const OP_LOAD_SMI_U8: u8 = 26;
pub const OP_POP: u8 = 40;
pub const OP_POP_1: u8 = 41;
pub const OP_INVOKE_STATIC: u8 = 53;
pub const OP_RETURN: u8 = 91;
pub const OP_NON_LOCAL_RETURN: u8 = 93;
pub const OP_NON_LOCAL_RETURN_WIDE: u8 = 94;
pub const OP_LINK: u8 = 97;
pub const OP_UNLINK: u8 = 98;

pub const LEN_LOAD_LOCAL: usize = 2;
pub const LEN_LOAD_LOCAL_WIDE: usize = 3;
pub const LEN_STORE_LOCAL: usize = 2;
pub const LEN_LOAD_OUTER: usize = 2;
pub const LEN_STORE_OUTER: usize = 2;
pub const LEN_LOAD_LOCAL_N: usize = 1;
pub const LEN_LOAD_SMI_U8: usize = 2;
pub const LEN_POP: usize = 2;
pub const LEN_POP_1: usize = 1;
pub const LEN_INVOKE_STATIC: usize = 3;
pub const LEN_RETURN: usize = 3;
pub const LEN_NON_LOCAL_RETURN: usize = 2;
pub const LEN_NON_LOCAL_RETURN_WIDE: usize = 5;
pub const LEN_LINK: usize = 2;
pub const LEN_UNLINK: usize = 2;

// --- Limits the core imposes on its inputs (checked at entry) -------------
/// Larger stacks are declined (the C++ interpreter runs them).
pub const MAX_STACK_WORDS: usize = 0x1000_0000;
/// Larger bytecode blobs and dispatch tables are declined.
pub const MAX_CODE_BYTES: usize = 0x4000_0000;

} // verus!
