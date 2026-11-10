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

//! Every constant the core assumes about the C++ VM.
//!
//! Each constant is exported by name through `ffi::toit_vcore_layout_entry`
//! and compared against the C++ headers by `verified/layout_check.cc`, which
//! runs as part of the build (a mismatch fails it). Add new assumptions
//! here, never inline.

use vstd::prelude::*;

verus! {

pub const WORD_SIZE: usize = 8;

// --- Tagging (src/objects.h, class Object) -------------------------------
pub const SMI_TAG_SIZE: usize = 1;
pub const SMI_TAG_MASK: usize = 1;
pub const SMI_TAG: usize = 0;
pub const NON_SMI_TAG_MASK: usize = 3;
pub const HEAP_TAG: usize = 1;
/// Primitive errors are marked with this tag (`Error::ERROR_TAG`).
pub const ERROR_TAG: usize = 3;
/// `Smi::MIN_SMI_VALUE`, `Smi::MAX_SMI_VALUE` (64-bit words).
pub const MIN_SMI: i64 = -0x4000_0000_0000_0000;
pub const MAX_SMI: i64 = 0x3fff_ffff_ffff_ffff;

// --- Heap objects (src/objects.h) ----------------------------------------
/// Word offset of the header from the untagged object address.
pub const HEADER_WORD: usize = 0;
/// Class tag: `(header smi value >> CLASS_TAG_OFFSET) & CLASS_TAG_MASK`.
pub const CLASS_TAG_OFFSET: usize = 0;
pub const CLASS_TAG_MASK: usize = 15;
/// Class id: `header smi value >> CLASS_ID_OFFSET`.
pub const CLASS_ID_OFFSET: usize = 5;
/// Instance size in words: `(class_bits >> CLASS_ID_OFFSET) & INSTANCE_SIZE_MASK`.
pub const INSTANCE_SIZE_MASK: u16 = 0x7ff;

pub const ARRAY_TAG: usize = 0;
pub const STRING_TAG: usize = 1;
pub const INSTANCE_TAG: usize = 2;
pub const ODDBALL_TAG: usize = 3;
pub const DOUBLE_TAG: usize = 4;
pub const BYTE_ARRAY_TAG: usize = 5;
pub const LARGE_INTEGER_TAG: usize = 6;
pub const STACK_TAG: usize = 7;
pub const TASK_TAG: usize = 8;

/// The fields of a task the VM owns (`Task::STACK_INDEX`, `Task::ID_INDEX`).
pub const TASK_STACK_FIELD: usize = 0;
pub const TASK_ID_FIELD: usize = 1;

/// Word offset of field 0 of an instance (`Instance::_offset_from(0)`).
pub const INSTANCE_FIELDS_WORD: usize = 1;
/// Array: length word and element 0 (`Array::LENGTH_OFFSET`, `_offset_from(0)`).
pub const ARRAY_LENGTH_WORD: usize = 1;
pub const ARRAY_ELEMENTS_WORD: usize = 2;
/// Double and LargeInteger: the 64-bit payload.
pub const DOUBLE_VALUE_WORD: usize = 1;
pub const LARGE_INTEGER_VALUE_WORD: usize = 1;
/// ByteArray: raw length (negative: external), inline content, external
/// address and tag.
pub const BYTE_ARRAY_LENGTH_WORD: usize = 1;
pub const BYTE_ARRAY_CONTENT_BYTE: usize = 16;
pub const BYTE_ARRAY_EXTERNAL_ADDRESS_WORD: usize = 2;
pub const BYTE_ARRAY_EXTERNAL_TAG_WORD: usize = 3;
/// `RawByteTag` and `MappedFileTag` (src/tags.h).
pub const RAW_BYTE_TAG: usize = 0;
pub const MAPPED_FILE_TAG: usize = 2;
/// String: 32-bit internal length at this byte offset (SENTINEL means
/// external), content after the internal header; external length and
/// address words.
pub const STRING_INTERNAL_LENGTH_BYTE: usize = 12;
pub const STRING_CONTENT_BYTE: usize = 16;
pub const STRING_SENTINEL: usize = 65535;
pub const STRING_EXTERNAL_LENGTH_WORD: usize = 2;
pub const STRING_EXTERNAL_ADDRESS_WORD: usize = 3;

/// Write barrier: card `address >> CARD_SIZE_LOG_2` is marked with
/// `NEW_SPACE_POINTERS` at `remembered_set_bias + card`.
pub const CARD_SIZE_LOG_2: usize = 8;
pub const NEW_SPACE_POINTERS: u8 = 1;

// --- Stack objects (src/objects.h, class Stack) --------------------------
/// Word offsets of the header fields from the untagged address.
pub const STACK_LENGTH_WORD: usize = 2;
pub const STACK_TOP_WORD: usize = 3;
/// Format 2: the record top, the end of the frame and finally records
/// (the format-1 try top).
pub const STACK_RECORD_TOP_WORD: usize = 4;
/// Format 2: the bci the task is suspended at in the low
/// `STACK_FIN_COUNT_SHIFT` bits, the number of finally records above them
/// (the format-1 pending stack-check method).
pub const STACK_BCI_WORD: usize = 5;
pub const STACK_FIN_COUNT_SHIFT: usize = 32;
// The word offset of array element 0 depends on the build (the guard zone
// is larger in debug builds); C++ passes it in the context.
pub const FRAME_WORDS: usize = 4;
pub const FRAME_METHOD: usize = 0;
pub const FRAME_RET: usize = 1;
pub const FRAME_BASE: usize = 2;
pub const FRAME_HANDLER: usize = 3;
/// Finally records (format note 17) follow the frame records, 4 words
/// each: the frame running the finally code, the height of its slots, the
/// resumed unwinding (`kind + 4 * frame`, kind 0 throw, 1 return, 2
/// branch) and the branch target (`bci | height << 32`, else 0). Only the
/// core reads them; C++ copies them with the frame records.
pub const FIN_WORDS: usize = 4;
pub const FIN_FRAME: usize = 0;
pub const FIN_HEIGHT: usize = 1;
pub const FIN_RESUME: usize = 2;
pub const FIN_TARGET: usize = 3;
pub const STACK_RESERVE: usize = 8;

// --- Program tables (src/program.h) ---------------------------------------
pub const ROOT_NULL: usize = 0;
pub const ROOT_TRUE: usize = 1;
pub const ROOT_FALSE: usize = 2;
pub const ROOT_OUT_OF_MEMORY_ERROR: usize = 4;
pub const ROOT_ERROR: usize = 12;
pub const ROOT_STACK_OVERFLOW: usize = 28;
pub const ROOT_COUNT: usize = 35;
pub const BUILTIN_COUNT: usize = 23;
pub const ENTRY_POINT_COUNT: usize = 9;
pub const INVOKE_OFFSET_COUNT: usize = 19;

pub const BUILTIN_ARRAY: usize = 1;
pub const BUILTIN_BYTE_ARRAY_COW: usize = 3;
pub const BUILTIN_BYTE_ARRAY_SLICE: usize = 4;
pub const BUILTIN_LIST: usize = 7;
pub const BUILTIN_OBJECT: usize = 15;
pub const BUILTIN_SMI: usize = 18;
pub const BUILTIN_TASK: usize = 19;
pub const BUILTIN_LARGE_ARRAY: usize = 20;
pub const BUILTIN_LAZY_INITIALIZER: usize = 21;
pub const BUILTIN_EXCEPTION: usize = 22;

pub const ENTRY_MAIN: usize = 0;
pub const ENTRY_SPAWN: usize = 1;
pub const ENTRY_TASK: usize = 2;
pub const ENTRY_RUN_GLOBAL_INITIALIZER: usize = 8;

/// `Array::ARRAYLET_SIZE`.
pub const ARRAYLET_SIZE: usize = 500;

// --- Interpreter results (Interpreter::Result::State) ---------------------
pub const RESULT_PREEMPTED: usize = 0;
pub const RESULT_YIELDED: usize = 1;
pub const RESULT_TERMINATED: usize = 2;
pub const RESULT_RESET: usize = 3;
pub const RESULT_DEEP_SLEEP: usize = 4;
/// `Interpreter::PREEMPTION_MARKER`.
pub const PREEMPTION_MARKER: usize = usize::MAX;

// --- FFI helper results (src/interpreter_v2.h) -----------------------------
pub const V2_OK: usize = 0;
pub const V2_STACK_OVERFLOW: usize = 1;
pub const V2_OUT_OF_MEMORY: usize = 2;
pub const V2_PRIMITIVE_SUCCESS: usize = 0;
pub const V2_PRIMITIVE_FAILURE: usize = 1;
pub const V2_PRIMITIVE_THROW: usize = 2;
pub const V2_PRIMITIVE_MISSING: usize = 0;
pub const V2_PRIMITIVE_FOUND: usize = 1;
/// `TOIT_V2_ACCEPTED`: the launch-time verifier accepted the program on the
/// table the process runs (`ffi::Accepted`).
pub const V2_ACCEPTED: usize = 0x56455249464945;
pub const V2_REPORT_STUCK: usize = 0;
pub const V2_REPORT_UNCAUGHT: usize = 1;
pub const V2_REPORT_TASK_RETURNED: usize = 2;
pub const V2_MESSAGE_NONE: usize = 0;
pub const V2_MESSAGE_WORD: usize = 1;
pub const V2_MESSAGE_ARRAY: usize = 2;
pub const V2_MESSAGE_PRIMITIVE: usize = 3;
pub const V2_MESSAGE_MAX_WORDS: usize = 4;

// --- Method kinds (src/interpreter_v2.h) -----------------------------------
pub const KIND_METHOD: u8 = 0;
pub const KIND_FIELD_ACCESSOR: u8 = 1;
pub const KIND_LAMBDA: u8 = 2;
pub const KIND_BLOCK: u8 = 3;
pub const NO_VALUE: u16 = 0xffff;

// --- Block references -------------------------------------------------------
/// A block reference `(frame, slot)` is the smi `frame << BLOCK_SLOT_BITS |
/// slot`. The layout check asserts `Stack::max_length() < 1 <<
/// BLOCK_SLOT_BITS`.
pub const BLOCK_SLOT_BITS: usize = 20;

/// Format 2: literals 0..7 are true, false and the values of the five
/// failures the machine raises (format note 5); toit_v2_run checks the
/// table has at least that many.
pub const FAILURE_LITERALS: usize = 7;
/// The longest format-2 instruction (NON_LOCAL_BRANCH).
pub const MAX_INSTRUCTION_LENGTH: usize = 6;

/// Size limits the core imposes on the program tables (checked at entry).
pub const MAX_TABLE: usize = 0x1000_0000;

} // verus!
