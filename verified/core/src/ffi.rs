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

//! TRUSTED: the C ABI. The structs must match `src/interpreter_v2.h`
//! (checked by the layout check). `Runtime` wraps the C++ functions the
//! core calls; every one that may GC consumes the stack view.

use vstd::prelude::*;
use core::ffi::c_void;
use core::sync::atomic::AtomicUsize;
use crate::layout::*;
use crate::view::*;
use toit_spec::types::{HeapObj, Body, Value};

verus! {

/// An entry of the method table (`toit::V2Method`).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct V2Method {
    pub entry: u32,
    pub end: u32,
    pub selector: u16,
    pub aux: u16,
    pub recv_start: u16,
    pub recv_end: u16,
    pub arity: u8,
    pub kind: u8,
    pub unused: u16,
}

} // verus!

/// `toit_v2_program`.
#[repr(C)]
pub struct ProgramTables {
    pub bytecodes: *const u8,
    pub bytecodes_length: usize,
    pub methods: *const V2Method,
    pub methods_length: usize,
    pub dispatch: *const i32,
    pub dispatch_length: usize,
    pub class_bits: *const u16,
    pub class_bits_length: usize,
    pub class_check_ids: *const u16,
    pub class_check_ids_length: usize,
    pub interface_check_offsets: *const u16,
    pub interface_check_offsets_length: usize,
    pub invoke_offsets: *const i32,
    pub entry_points: *const i32,
    pub builtin_class_ids: *const usize,
    pub roots: *const usize,
    pub roots_length: usize,
    pub literals: *const usize,
    pub literals_length: usize,
    pub globals: *mut usize,
    pub globals_length: usize,
    pub program_heap_start: usize,
    pub program_heap_size: usize,
    pub remembered_set_bias: usize,
    pub global_max_height: usize,
    pub stack_array_word: usize,
}

/// `toit_v2_context`.
#[repr(C)]
pub struct Context {
    pub process: *mut c_void,
    pub program: ProgramTables,
    pub watermark: *const AtomicUsize,
    pub preempt_a_lot: usize,
    pub accepted: usize,
    pub result_state: usize,
    pub result_value: i64,
}

extern "C" {
    fn toit_v2_current_stack(process: *mut c_void) -> usize;
    fn toit_v2_allocate_instance(process: *mut c_void, class_id: usize) -> usize;
    fn toit_v2_allocate_double(process: *mut c_void, bits: u64) -> usize;
    fn toit_v2_allocate_exception(process: *mut c_void, value: usize, message_kind: usize,
                                  words: *const usize, count: usize) -> usize;
    fn toit_v2_allocate_array(process: *mut c_void, length: usize, filler: usize) -> usize;
    fn toit_v2_grow_stack(process: *mut c_void, needed: usize) -> usize;
    fn toit_v2_lookup_primitive(process: *mut c_void, module: usize, index: usize,
                                entry: *mut *const c_void, arity: *mut usize, rust: *mut usize) -> usize;
    fn toit_v2_try_allocate_large_integer(process: *mut c_void, value: i64) -> usize;
    fn toit_v2_try_allocate_double(process: *mut c_void, bits: u64) -> usize;
    fn toit_v2_try_allocate_array(process: *mut c_void, length: usize, filler: usize) -> usize;
    fn toit_v2_try_allocate_string(process: *mut c_void, length: usize) -> usize;
    fn toit_v2_try_allocate_byte_array(process: *mut c_void, length: usize) -> usize;
    fn toit_v2_primitive_gc(process: *mut c_void, attempt: usize);
    fn toit_v2_leave_primitive(process: *mut c_void);
    fn toit_v2_call_primitive(process: *mut c_void, entry: *const c_void, arity: usize,
                              first_argument: usize, result: *mut usize) -> usize;
    fn toit_v2_report(process: *mut c_void, kind: usize, bci: usize, detail: usize);
}

verus! {

/// Evidence that the launch-time verifier (verified/vmverify, the proven
/// `check::verify` and `x_loaded_ok`) accepted the program on the tables
/// the core runs: the verified run loop (`step::run_loop`) takes it. Its
/// field is private to this module, so the only way to get one is
/// `toit_v2_run` seeing `TOIT_V2_ACCEPTED`, which `Interpreter::run_v2`
/// writes only for a `V2MethodTable` that `V2Verifier::verify`'s accept
/// path marked. It is the runtime fact behind the `Ghost::assume_new` of
/// the abstract program, certificate and mode there (TRUSTED.md, Loader).
pub struct Accepted {
    _private: (),
}

/// A C++ primitive found in the process' policy. `rust`: the policy
/// resolves it to the VM's own primitive (not a denying stub) and the Rust
/// primitives are enabled (`TOIT_V2_RUST_PRIMITIVES=1`), so the core may run
/// its Rust port (src/prims) instead.
#[verifier::external_body]
pub struct PrimitiveRef {
    entry: *const c_void,
    rust: bool,
}

impl PrimitiveRef {
    #[verifier::external_body]
    #[inline(always)]
    pub fn rust(&self) -> bool {
        self.rust
    }
}

/// The C++ functions the core calls (src/interpreter_v2.h). Each that may
/// GC takes the (only) stack view by mutable reference and replaces it by a
/// fresh one derived from the process after the call: the old view, whose
/// pointers may be stale, is unreachable afterwards. The caller must have
/// stored its state into the stack object before the call.
#[verifier::external_body]
pub struct Runtime {
    process: *mut c_void,
    array_word: usize,
}

impl Runtime {
    /// A view of the current task's stack.
    #[verifier::external_body]
    pub fn stack(&self) -> StackMem {
        unsafe { StackMem::from_stack(toit_v2_current_stack(self.process), self.array_word) }
    }

    /// MAY GC. An instance of the class with null fields, or 0.
    #[verifier::external_body]
    pub fn allocate_instance(&self, stack: &mut StackMem, class_id: usize) -> usize {
        let r = unsafe { toit_v2_allocate_instance(self.process, class_id) };
        *stack = self.stack();
        r
    }

    /// MAY GC. An `Exception_` with the given value (a program-heap object)
    /// and the encoded stack trace of the current task, or 0. The message
    /// words (object references among them) are only read by C++ before
    /// its first GC point.
    #[verifier::external_body]
    pub fn allocate_exception(&self, stack: &mut StackMem, value: usize, kind: usize,
                              words: &[usize; V2_MESSAGE_MAX_WORDS], count: usize) -> usize {
        let count = if count <= V2_MESSAGE_MAX_WORDS { count } else { 0 };
        let r = unsafe { toit_v2_allocate_exception(self.process, value, kind, words.as_ptr(), count) };
        *stack = self.stack();
        r
    }

    /// MAY GC. A double with the given bits, or 0.
    #[verifier::external_body]
    pub fn allocate_double(&self, stack: &mut StackMem, bits: u64) -> usize {
        let r = unsafe { toit_v2_allocate_double(self.process, bits) };
        *stack = self.stack();
        r
    }

    /// MAY GC. An array of `length` elements, all `filler`, or 0.
    #[verifier::external_body]
    pub fn allocate_array(&self, stack: &mut StackMem, length: usize, filler: usize) -> usize {
        let r = unsafe { toit_v2_allocate_array(self.process, length, filler) };
        *stack = self.stack();
        r
    }

    /// MAY GC. Replaces the stack by a larger one with at least `needed`
    /// free words.
    #[verifier::external_body]
    pub fn grow_stack(&self, stack: &mut StackMem, needed: usize) -> usize {
        let r = unsafe { toit_v2_grow_stack(self.process, needed) };
        *stack = self.stack();
        r
    }

    #[verifier::external_body]
    pub fn lookup_primitive(&self, module: usize, index: usize) -> (r: Option<(PrimitiveRef, usize)>) {
        let mut entry: *const c_void = core::ptr::null();
        let mut arity: usize = 0;
        let mut rust: usize = 0;
        let found = unsafe { toit_v2_lookup_primitive(self.process, module, index, &mut entry, &mut arity, &mut rust) };
        if found == V2_PRIMITIVE_FOUND { Some((PrimitiveRef { entry, rust: rust != 0 }, arity)) } else { None }
    }

    /// The allocator of the Rust primitives (allocation without GC).
    #[verifier::external_body]
    pub fn allocator(&self) -> Allocator {
        Allocator { process: self.process }
    }

    /// MAY GC. The collection a primitive asks for when an allocation
    /// failed (`attempt` 1..3, as the C++ primitive path); attempt 3 only
    /// reports. The stack view is replaced.
    #[verifier::external_body]
    pub fn primitive_gc(&self, stack: &mut StackMem, attempt: usize) {
        unsafe { toit_v2_primitive_gc(self.process, attempt) };
        *stack = self.stack();
    }

    /// Installs a heap limit a GC during a primitive deferred
    /// (`ObjectHeap::leave_primitive`).
    #[verifier::external_body]
    pub fn leave_primitive(&self) {
        unsafe { toit_v2_leave_primitive(self.process) }
    }

    /// MAY GC, may switch the current task. Calls the primitive with its
    /// arguments at object-stack positions `first..first+arity`.
    #[verifier::external_body]
    pub fn call_primitive(&self, stack: &mut StackMem, primitive: &PrimitiveRef, arity: usize, first: usize) -> (usize, usize) {
        let mut result: usize = 0;
        let status = unsafe { toit_v2_call_primitive(self.process, primitive.entry, arity, first, &mut result) };
        *stack = self.stack();
        (status, result)
    }

    #[verifier::external_body]
    pub fn report(&self, kind: usize, bci: usize, detail: usize) {
        unsafe { toit_v2_report(self.process, kind, bci, detail) }
    }
}

/// Allocation for the Rust primitives (src/prims). Never collects garbage:
/// when the heap is full (or the process is over its limit, or malloc
/// fails for external bytes) the result is 0 and the heap is unchanged; the
/// primitive then reports `PrimOutcome::NeedsGc` and the caller collects
/// and retries the whole primitive (the C++ `ALLOCATION_FAILED` protocol).
/// TRUSTED: each allocation appends exactly one object of the program's
/// builtin class (`p.ap@.builtin[k]`) at a fresh address outside the
/// program heap (`view::appended`), with the stated body; the memory of
/// every other object is untouched.
#[verifier::external_body]
pub struct Allocator {
    process: *mut c_void,
}

impl Allocator {
    /// `Primitive::allocate_large_integer` without the error marking.
    #[verifier::external_body]
    pub fn large_integer(&self, heap: &mut Heap, p: &crate::exec::Program, v: i64) -> (r: usize)
        ensures
            r == 0 ==> *final(heap) == *old(heap),
            r != 0 ==> appended(old(heap), final(heap), r, p.ro_start, p.ro_size)
                && final(heap).objs().last() == (HeapObj {
                    class_id: p.ap@.builtin[BUILTIN_LARGE_INTEGER as int], ro: false, body: Body::LargeInt(v) }),
    {
        unsafe { toit_v2_try_allocate_large_integer(self.process, v) }
    }

    /// A double with the given bits.
    #[verifier::external_body]
    pub fn double(&self, heap: &mut Heap, p: &crate::exec::Program, bits: u64) -> (r: usize)
        ensures
            r == 0 ==> *final(heap) == *old(heap),
            r != 0 ==> appended(old(heap), final(heap), r, p.ro_start, p.ro_size)
                && final(heap).objs().last() == (HeapObj {
                    class_id: p.ap@.builtin[BUILTIN_DOUBLE as int], ro: false, body: Body::Double(bits) }),
    {
        unsafe { toit_v2_try_allocate_double(self.process, bits) }
    }

    /// An array of `length` elements (at most `ARRAYLET_SIZE`), each the
    /// value `fv` encoded by `filler`.
    #[verifier::external_body]
    pub fn array(&self, heap: &mut Heap, p: &crate::exec::Program, length: usize, filler: usize,
                 Ghost(fv): Ghost<Value>) -> (r: usize)
        requires
            length <= ARRAYLET_SIZE,
            filler == crate::abs::enc(old(heap).addrs(), fv),
        ensures
            r == 0 ==> *final(heap) == *old(heap),
            r != 0 ==> appended(old(heap), final(heap), r, p.ro_start, p.ro_size)
                && final(heap).objs().last() == (HeapObj {
                    class_id: p.ap@.builtin[BUILTIN_ARRAY as int], ro: false,
                    body: Body::Array(Seq::new(length as nat, |i: int| fv)) }),
    {
        unsafe { toit_v2_try_allocate_array(self.process, length, filler) }
    }

    /// A string of `length` bytes (`Process::allocate_string`: inline, or
    /// external malloced memory for long strings); its bytes are
    /// uninitialized: the primitive writes all of them before returning.
    #[verifier::external_body]
    pub fn string(&self, heap: &mut Heap, p: &crate::exec::Program, length: usize) -> (r: usize)
        ensures
            r == 0 ==> *final(heap) == *old(heap),
            r != 0 ==> appended(old(heap), final(heap), r, p.ro_start, p.ro_size)
                && final(heap).objs().last().class_id == p.ap@.builtin[BUILTIN_STRING as int]
                && final(heap).objs().last().body is Str
                && content(final(heap).objs().last()).len() == length,
    {
        unsafe { toit_v2_try_allocate_string(self.process, length) }
    }

    /// A byte array of `length` zero bytes (`Process::allocate_byte_array`:
    /// inline, or external raw bytes for long arrays).
    #[verifier::external_body]
    pub fn byte_array(&self, heap: &mut Heap, p: &crate::exec::Program, length: usize) -> (r: usize)
        ensures
            r == 0 ==> *final(heap) == *old(heap),
            r != 0 ==> appended(old(heap), final(heap), r, p.ro_start, p.ro_size)
                && final(heap).objs().last() == (HeapObj {
                    class_id: p.ap@.builtin[BUILTIN_BYTE_ARRAY as int], ro: false,
                    body: Body::Bytes(Seq::new(length as nat, |i: int| 0u8)) }),
    {
        unsafe { toit_v2_try_allocate_byte_array(self.process, length) }
    }
}

} // verus!

impl Runtime {
    pub fn new(process: *mut c_void, array_word: usize) -> Self {
        Runtime { process, array_word }
    }
}

/// Runs the current format-2 process until it is preempted, yields,
/// terminates, or halts the device; see Interpreter::run.
///
/// # Safety
/// `context` must be filled by `Interpreter::run_v2` (src/interpreter_v2.cc)
/// for the process that is about to run, on the thread that runs it.
#[no_mangle]
pub unsafe extern "C" fn toit_v2_run(context: *mut Context) -> usize {
    let c = &mut *context;
    let p = &c.program;
    let builtin = |k: usize| -> i64 { (*p.builtin_class_ids.add(k) as i64) >> 1 };
    if p.roots_length < ROOT_COUNT || p.literals_length < FAILURE_LITERALS || p.methods_length == 0
        || p.methods_length >= MAX_TABLE || p.bytecodes_length >= MAX_TABLE {
        c.result_state = RESULT_TERMINATED;
        c.result_value = 1;
        return RESULT_TERMINATED;
    }
    let program = crate::exec::Program {
        code: Table::from_raw(p.bytecodes, p.bytecodes_length),
        methods: Table::from_raw(p.methods, p.methods_length),
        dispatch: Table::from_raw(p.dispatch, p.dispatch_length),
        class_bits: Table::from_raw(p.class_bits, p.class_bits_length),
        class_check_ids: Table::from_raw(p.class_check_ids, p.class_check_ids_length),
        interface_check_offsets: Table::from_raw(p.interface_check_offsets, p.interface_check_offsets_length),
        invoke_offsets: Table::from_raw(p.invoke_offsets, INVOKE_OFFSET_COUNT),
        entry_points: Table::from_raw(p.entry_points, ENTRY_POINT_COUNT),
        builtin: Table::from_raw(p.builtin_class_ids, BUILTIN_COUNT),
        roots: Table::from_raw(p.roots, ROOT_COUNT),
        literals: Table::from_raw(p.literals, p.literals_length),
        ro_start: p.program_heap_start,
        ro_size: p.program_heap_size,
        max_height: p.global_max_height,
        preempt_a_lot: c.preempt_a_lot != 0,
        null: *p.roots.add(ROOT_NULL),
        true_: *p.roots.add(ROOT_TRUE),
        false_: *p.roots.add(ROOT_FALSE),
        smi_class_id: builtin(BUILTIN_SMI),
        list_class_id: builtin(BUILTIN_LIST),
        byte_array_slice_class_id: builtin(BUILTIN_BYTE_ARRAY_SLICE),
        byte_array_cow_class_id: builtin(BUILTIN_BYTE_ARRAY_COW),
        large_array_class_id: builtin(BUILTIN_LARGE_ARRAY),
        lazy_initializer_class_id: builtin(BUILTIN_LAZY_INITIALIZER),
        // The abstract program, certificate and mode of the verifier's
        // acceptance: the loader's contract (theorem.rs, `run_requires`).
        ap: Ghost::assume_new(),
        cert: Ghost::assume_new(),
        trusted: Ghost::assume_new(),
    };
    let runtime = Runtime::new(c.process, p.stack_array_word);
    let globals = Globals::from_raw(p.globals, p.globals_length);
    let heap = Heap::new(p.remembered_set_bias);
    let preemption = Preemption::from_raw(c.watermark);
    // The verified run loop needs an `Accepted` token, which exists only
    // here and only for a context whose table the launch-time verifier
    // accepted (TOIT_V2_ACCEPTED, set by Interpreter::run_v2 from
    // V2MethodTable::verified, which only V2Verifier::verify's accept path
    // sets).
    let accepted = if c.accepted == V2_ACCEPTED { Some(Accepted { _private: () }) } else { None };
    let (state, value) = crate::machine::run(&program, runtime, globals, heap, preemption, accepted);
    c.result_state = state;
    c.result_value = value;
    state
}

/// Instruction length of a format-2 opcode (for the layout check).
#[no_mangle]
pub extern "C" fn toit_vcore_opcode_length(opcode: usize) -> usize {
    if opcode < 101 { crate::machine::opcode_length(opcode as u8) } else { 0 }
}

macro_rules! layout_table {
    ($($name:ident),* $(,)?) => {
        const LAYOUT: &[(&[u8], usize)] = &[
            $((concat!(stringify!($name), "\0").as_bytes(), $name as usize),)*
        ];
    };
}

layout_table!(
    WORD_SIZE, SMI_TAG_SIZE, SMI_TAG_MASK, SMI_TAG, NON_SMI_TAG_MASK, HEAP_TAG, ERROR_TAG,
    MIN_SMI, MAX_SMI,
    HEADER_WORD, CLASS_TAG_OFFSET, CLASS_TAG_MASK, CLASS_ID_OFFSET, INSTANCE_SIZE_MASK,
    ARRAY_TAG, STRING_TAG, INSTANCE_TAG, ODDBALL_TAG, DOUBLE_TAG, BYTE_ARRAY_TAG,
    LARGE_INTEGER_TAG, STACK_TAG, TASK_TAG,
    INSTANCE_FIELDS_WORD, ARRAY_LENGTH_WORD, ARRAY_ELEMENTS_WORD, DOUBLE_VALUE_WORD,
    LARGE_INTEGER_VALUE_WORD, BYTE_ARRAY_LENGTH_WORD, BYTE_ARRAY_CONTENT_BYTE,
    BYTE_ARRAY_EXTERNAL_ADDRESS_WORD, BYTE_ARRAY_EXTERNAL_TAG_WORD, RAW_BYTE_TAG, MAPPED_FILE_TAG,
    STRING_INTERNAL_LENGTH_BYTE, STRING_CONTENT_BYTE, STRING_SENTINEL, STRING_HASH_CODE_BYTE,
    STRING_NO_HASH_CODE,
    STRING_EXTERNAL_LENGTH_WORD, STRING_EXTERNAL_ADDRESS_WORD,
    CARD_SIZE_LOG_2, NEW_SPACE_POINTERS,
    STACK_LENGTH_WORD, STACK_TOP_WORD, STACK_RECORD_TOP_WORD, STACK_BCI_WORD, STACK_FIN_COUNT_SHIFT,
    FRAME_WORDS, FRAME_METHOD, FRAME_RET, FRAME_BASE, FRAME_HANDLER, STACK_RESERVE,
    FIN_WORDS, FIN_FRAME, FIN_HEIGHT, FIN_RESUME, FIN_TARGET,
    ROOT_NULL, ROOT_TRUE, ROOT_FALSE, ROOT_OUT_OF_MEMORY_ERROR, ROOT_ERROR, ROOT_STACK_OVERFLOW,
    ROOT_EMPTY_ARRAY, ROOT_ALLOCATION_FAILED, ROOT_DIVISION_BY_ZERO, ROOT_ILLEGAL_UTF_8,
    ROOT_INVALID_ARGUMENT, ROOT_NEGATIVE_ARGUMENT, ROOT_OUT_OF_BOUNDS, ROOT_OUT_OF_RANGE,
    ROOT_PERMISSION_DENIED, ROOT_WRONG_OBJECT_TYPE, ROOT_WRONG_BYTES_TYPE,
    ROOT_COUNT, BUILTIN_COUNT, ENTRY_POINT_COUNT, INVOKE_OFFSET_COUNT,
    BUILTIN_STRING, BUILTIN_BYTE_ARRAY, BUILTIN_STRING_SLICE, BUILTIN_STRING_BYTE_SLICE,
    BUILTIN_DOUBLE, BUILTIN_LARGE_INTEGER,
    BUILTIN_ARRAY, BUILTIN_BYTE_ARRAY_COW, BUILTIN_BYTE_ARRAY_SLICE, BUILTIN_LIST, BUILTIN_OBJECT,
    BUILTIN_SMI, BUILTIN_TASK, BUILTIN_LARGE_ARRAY, BUILTIN_LAZY_INITIALIZER, BUILTIN_EXCEPTION,
    ENTRY_MAIN, ENTRY_SPAWN, ENTRY_TASK, ENTRY_RUN_GLOBAL_INITIALIZER, ARRAYLET_SIZE,
    RESULT_PREEMPTED, RESULT_YIELDED, RESULT_TERMINATED, RESULT_RESET, RESULT_DEEP_SLEEP,
    PREEMPTION_MARKER,
    V2_OK, V2_STACK_OVERFLOW, V2_OUT_OF_MEMORY, V2_PRIMITIVE_SUCCESS, V2_PRIMITIVE_FAILURE,
    V2_PRIMITIVE_THROW, V2_PRIMITIVE_MISSING, V2_PRIMITIVE_FOUND, V2_ACCEPTED, V2_REPORT_STUCK,
    V2_REPORT_UNCAUGHT, V2_REPORT_TASK_RETURNED,
    V2_MESSAGE_NONE, V2_MESSAGE_WORD, V2_MESSAGE_ARRAY, V2_MESSAGE_PRIMITIVE, V2_MESSAGE_MAX_WORDS,
    KIND_METHOD, KIND_FIELD_ACCESSOR, KIND_LAMBDA, KIND_BLOCK, NO_VALUE, BLOCK_SLOT_BITS,
    FAILURE_LITERALS, MAX_INSTRUCTION_LENGTH, MAX_TABLE, TASK_STACK_FIELD, TASK_ID_FIELD,
);

/// The C ABI of the FFI structs.
const STRUCT_LAYOUT: &[(&[u8], usize)] = &[
    (b"V2METHOD_SIZE\0", core::mem::size_of::<V2Method>()),
    (b"V2METHOD_entry\0", core::mem::offset_of!(V2Method, entry)),
    (b"V2METHOD_end\0", core::mem::offset_of!(V2Method, end)),
    (b"V2METHOD_selector\0", core::mem::offset_of!(V2Method, selector)),
    (b"V2METHOD_aux\0", core::mem::offset_of!(V2Method, aux)),
    (b"V2METHOD_recv_start\0", core::mem::offset_of!(V2Method, recv_start)),
    (b"V2METHOD_recv_end\0", core::mem::offset_of!(V2Method, recv_end)),
    (b"V2METHOD_arity\0", core::mem::offset_of!(V2Method, arity)),
    (b"V2METHOD_kind\0", core::mem::offset_of!(V2Method, kind)),
    (b"PROGRAM_SIZE\0", core::mem::size_of::<ProgramTables>()),
    (b"PROGRAM_bytecodes\0", core::mem::offset_of!(ProgramTables, bytecodes)),
    (b"PROGRAM_methods\0", core::mem::offset_of!(ProgramTables, methods)),
    (b"PROGRAM_dispatch\0", core::mem::offset_of!(ProgramTables, dispatch)),
    (b"PROGRAM_class_bits\0", core::mem::offset_of!(ProgramTables, class_bits)),
    (b"PROGRAM_class_check_ids\0", core::mem::offset_of!(ProgramTables, class_check_ids)),
    (b"PROGRAM_interface_check_offsets\0", core::mem::offset_of!(ProgramTables, interface_check_offsets)),
    (b"PROGRAM_invoke_offsets\0", core::mem::offset_of!(ProgramTables, invoke_offsets)),
    (b"PROGRAM_entry_points\0", core::mem::offset_of!(ProgramTables, entry_points)),
    (b"PROGRAM_builtin_class_ids\0", core::mem::offset_of!(ProgramTables, builtin_class_ids)),
    (b"PROGRAM_roots\0", core::mem::offset_of!(ProgramTables, roots)),
    (b"PROGRAM_literals\0", core::mem::offset_of!(ProgramTables, literals)),
    (b"PROGRAM_globals\0", core::mem::offset_of!(ProgramTables, globals)),
    (b"PROGRAM_program_heap_start\0", core::mem::offset_of!(ProgramTables, program_heap_start)),
    (b"PROGRAM_remembered_set_bias\0", core::mem::offset_of!(ProgramTables, remembered_set_bias)),
    (b"PROGRAM_global_max_height\0", core::mem::offset_of!(ProgramTables, global_max_height)),
    (b"PROGRAM_stack_array_word\0", core::mem::offset_of!(ProgramTables, stack_array_word)),
    (b"CONTEXT_SIZE\0", core::mem::size_of::<Context>()),
    (b"CONTEXT_process\0", core::mem::offset_of!(Context, process)),
    (b"CONTEXT_program\0", core::mem::offset_of!(Context, program)),
    (b"CONTEXT_watermark\0", core::mem::offset_of!(Context, watermark)),
    (b"CONTEXT_preempt_a_lot\0", core::mem::offset_of!(Context, preempt_a_lot)),
    (b"CONTEXT_accepted\0", core::mem::offset_of!(Context, accepted)),
    (b"CONTEXT_result_state\0", core::mem::offset_of!(Context, result_state)),
    (b"CONTEXT_result_value\0", core::mem::offset_of!(Context, result_value)),
];

/// The opcode numbers the core uses (compared with src/bytecodes.h and the
/// format-2 renames of src/compiler/bytecode_format.h).
const OPCODES: &[(&[u8], usize)] = {
    use crate::machine::op::*;
    macro_rules! ops {
        ($($name:ident),* $(,)?) => {
            &[$((concat!("OP_", stringify!($name), "\0").as_bytes(), $name as usize),)*]
        };
    }
    ops!(
        LOAD_LOCAL, LOAD_LOCAL_WIDE, POP_LOAD_LOCAL, STORE_LOCAL, STORE_LOCAL_POP, LOAD_OUTER,
        STORE_OUTER, LOAD_FIELD, LOAD_FIELD_WIDE, LOAD_FIELD_LOCAL, POP_LOAD_FIELD_LOCAL,
        STORE_FIELD, STORE_FIELD_WIDE, STORE_FIELD_POP, LOAD_LOCAL_0, LOAD_LOCAL_5, LOAD_LITERAL,
        LOAD_LITERAL_WIDE, LOAD_NULL, LOAD_SMI_0, LOAD_SMIS_0, LOAD_SMI_1, LOAD_SMI_U8,
        LOAD_SMI_U16, LOAD_SMI_U32, LOAD_METHOD, LOAD_GLOBAL_VAR, LOAD_GLOBAL_VAR_WIDE,
        LOAD_GLOBAL_VAR_LAZY, LOAD_GLOBAL_VAR_LAZY_WIDE, LOAD_GLOBAL_VAR_DYNAMIC,
        STORE_GLOBAL_VAR, STORE_GLOBAL_VAR_WIDE, STORE_GLOBAL_VAR_DYNAMIC, LOAD_BLOCK,
        LOAD_OUTER_BLOCK, POP, POP_1, ALLOCATE, ALLOCATE_WIDE, IS_CLASS, IS_CLASS_WIDE,
        IS_INTERFACE, IS_INTERFACE_WIDE, AS_CLASS, AS_CLASS_WIDE, AS_INTERFACE,
        AS_INTERFACE_WIDE, AS_LOCAL, INVOKE_STATIC, INVOKE_STATIC_TAIL, INVOKE_BLOCK,
        INVOKE_LAMBDA_TAIL, INVOKE_INITIALIZER_TAIL, INVOKE_VIRTUAL, INVOKE_VIRTUAL_WIDE,
        INVOKE_VIRTUAL_GET, INVOKE_VIRTUAL_SET, INVOKE_EQ, INVOKE_LT, INVOKE_GT, INVOKE_LTE,
        INVOKE_GTE, INVOKE_BIT_OR, INVOKE_BIT_XOR, INVOKE_BIT_AND, INVOKE_BIT_SHL,
        INVOKE_BIT_SHR, INVOKE_BIT_USHR, INVOKE_ADD, INVOKE_SUB, INVOKE_MUL, INVOKE_DIV,
        INVOKE_MOD, INVOKE_AT, INVOKE_AT_PUT, INVOKE_SIZE, BRANCH, BRANCH_IF_TRUE,
        BRANCH_IF_FALSE, BRANCH_IF_NOT_NULL, BRANCH_BACK, BRANCH_BACK_IF_TRUE,
        BRANCH_BACK_IF_FALSE, BRANCH_BACK_IF_NOT_NULL, PRIMITIVE, THROW, RETURN, RETURN_NULL,
        NON_LOCAL_RETURN, STORE_FIELD_THIS, NON_LOCAL_BRANCH, IDENTICAL, TRY, LOAD_FIELD_THIS,
        UNWIND, HALT,
    )
};

/// Number of layout entries.
#[no_mangle]
pub extern "C" fn toit_vcore_layout_count() -> usize {
    LAYOUT.len() + STRUCT_LAYOUT.len() + OPCODES.len()
}

/// Layout entry `i`: writes its NUL-terminated name and value. Returns false
/// if `i` is out of range.
///
/// # Safety
/// `name` and `value` must be valid for writes.
#[no_mangle]
pub unsafe extern "C" fn toit_vcore_layout_entry(i: usize, name: *mut *const u8, value: *mut usize) -> bool {
    let entry = if i < LAYOUT.len() {
        LAYOUT.get(i)
    } else if i < LAYOUT.len() + STRUCT_LAYOUT.len() {
        STRUCT_LAYOUT.get(i - LAYOUT.len())
    } else {
        OPCODES.get(i - LAYOUT.len() - STRUCT_LAYOUT.len())
    };
    match entry {
        None => false,
        Some((n, v)) => {
            *name = n.as_ptr();
            *value = *v;
            true
        }
    }
}

/// Number of entries of the core module's primitive table the Rust
/// primitives use (src/prims/index.rs), for the layout check.
#[no_mangle]
pub extern "C" fn toit_vcore_prim_count() -> usize {
    crate::prims::index::TABLE.len()
}

/// Primitive table entry `i`: its NUL-terminated name, index and arity.
///
/// # Safety
/// `name`, `index` and `arity` must be valid for writes.
#[no_mangle]
pub unsafe extern "C" fn toit_vcore_prim_entry(i: usize, name: *mut *const u8, index: *mut usize, arity: *mut usize) -> bool {
    match crate::prims::index::TABLE.get(i) {
        None => false,
        Some((n, x, a)) => {
            *name = n.as_ptr();
            *index = *x;
            *arity = *a;
            true
        }
    }
}
