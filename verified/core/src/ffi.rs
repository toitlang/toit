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
use vstd::raw_ptr::*;
use core::ffi::c_void;
use core::sync::atomic::AtomicUsize;
use crate::layout::*;
use crate::view::*;
use toit_spec::types::{HeapObj, Body, Value};

/// A decoded method (`toit::V2Method`): the spec's `VMethod`. The method
/// table is a 4-byte record per method plus the method headers in the
/// bytecodes (format note 21; `exec::Program::method` decodes).
pub use toit_spec::v2::vprog::VMethod as V2Method;

/// `toit_v2_program`.
#[repr(C)]
pub struct ProgramTables {
    pub bytecodes: *const u8,
    pub bytecodes_length: usize,
    pub methods: *const u32,      // The method records (format note 21).
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
    pub policy_arities: *const u8,
    pub policy_arities_length: usize,
    pub policy_counts: *const u32,
    pub policy_starts: *const u32,
    pub policy_modules: usize,
    pub epoch: *const usize,
    pub unchecked: usize,
    pub new_space_top: *mut usize,
    pub new_space_limit: *const usize,
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
    fn toit_v2_try_allocate_large_integer(process: *mut c_void, value: i64) -> usize;
    fn toit_v2_try_allocate_double(process: *mut c_void, bits: u64) -> usize;
    fn toit_v2_try_allocate_array(process: *mut c_void, length: usize, filler: *mut c_void) -> usize;
    fn toit_v2_try_allocate_string(process: *mut c_void, length: usize) -> usize;
    fn toit_v2_try_allocate_byte_array(process: *mut c_void, length: usize) -> usize;
    fn toit_v2_primitive(process: *mut c_void, module: usize, index: usize, arity: usize,
                         first_argument: usize, result: *mut usize) -> usize;
    fn toit_v2_report(process: *mut c_void, kind: usize, bci: usize, detail: usize);
    fn toit_v2_tracing(process: *mut c_void) -> usize;
}

verus! {

/// Evidence that the launch-time verifier (verified/vmverify, the proven
/// `cert::verify_shipped` and `x_loaded_ok`) accepted the program on the tables
/// the core runs: the verified run loop (`step::run_loop`) takes it. Its
/// field is private to this module, so the only way to get one is
/// `toit_v2_run` seeing `TOIT_V2_ACCEPTED`, which `Interpreter::run_v2`
/// writes only for a `V2MethodTable` that `V2Verifier::verify`'s accept
/// path marked. It is the runtime fact behind the `Ghost::assume_new` of
/// the abstract program, certificate and mode there (TRUSTED.md, Loader).
pub struct Accepted {
    _private: (),
}

impl Accepted {
    /// TRUSTED (verified/core/EXPERIMENT-trusted.md, TRUSTED.md section 6,
    /// Loader): the token for a trusted program (the system process,
    /// first-party code) that the launch did not verify:
    /// `Interpreter::run_v2` writes `TOIT_V2_TRUSTED` only for a process
    /// whose policy is not untrusted. The loader's `assume_new` of the
    /// abstract program, certificate and mode (`trusted == true`) then
    /// rests on the compiler: we trust it for first-party code, so its
    /// output would be accepted by the verifier under the trusted rules
    /// (which debug builds and -Xverify check at launch). A wrong program
    /// can crash the VM, it cannot reach an untrusted process: untrusted
    /// processes never get this token.
    #[verifier::external_body]
    pub fn trusted_program() -> (r: Accepted) {
        Accepted { _private: () }
    }
}

/// The C++ functions the core calls (src/interpreter_v2.h). Each that may
/// GC takes the (only) stack view by mutable reference and replaces it by a
/// fresh one derived from the process after the call: the old view, whose
/// pointers may be stale, is unreachable afterwards. The caller must have
/// stored its state into the stack object before the call.
pub struct Runtime {
    process: *mut u8,
    array_word: usize,
    epoch: *const usize,
    ns_top: *mut usize,
    ns_limit: *const usize,
}

impl Runtime {
    /// A view of the current task's stack.
    #[verifier::external_body]
    pub fn stack(&self) -> StackMem {
        unsafe { StackMem::from_stack(toit_v2_current_stack(self.process.cast()), self.array_word) }
    }

    /// MAY GC. An instance of the class with null fields, or 0; whether the
    /// heap's epoch changed (a GC: the stack view is replaced; otherwise it
    /// stays, TRUSTED.md "Epoch").
    #[verifier::external_body]
    #[inline(always)]
    pub fn allocate_instance(&self, stack: &mut StackMem, class_id: usize) -> (usize, bool) {
        // SAFETY: as `call_primitive`.
        let before = unsafe { *self.epoch };
        let r = unsafe { toit_v2_allocate_instance(self.process.cast(), class_id) };
        let moved = unsafe { *self.epoch } != before;
        if moved { *stack = self.stack(); }
        (r, moved)
    }

    /// MAY GC. An `Exception_` with the given value (a program-heap object)
    /// and the encoded stack trace of the current task, or 0. The message
    /// words (object references among them) are only read by C++ before
    /// its first GC point.
    #[verifier::external_body]
    pub fn allocate_exception(&self, stack: &mut StackMem, value: usize, kind: usize,
                              words: &[usize; V2_MESSAGE_MAX_WORDS], count: usize) -> usize {
        let count = if count <= V2_MESSAGE_MAX_WORDS { count } else { 0 };
        let r = unsafe { toit_v2_allocate_exception(self.process.cast(), value, kind, words.as_ptr(), count) };
        *stack = self.stack();
        r
    }

    /// MAY GC. A double with the given bits, or 0; whether the heap's epoch
    /// changed (as `allocate_instance`).
    #[verifier::external_body]
    #[inline(always)]
    pub fn allocate_double(&self, stack: &mut StackMem, bits: u64) -> (usize, bool) {
        // SAFETY: as `call_primitive`.
        let before = unsafe { *self.epoch };
        let r = unsafe { toit_v2_allocate_double(self.process.cast(), bits) };
        let moved = unsafe { *self.epoch } != before;
        if moved { *stack = self.stack(); }
        (r, moved)
    }

    /// MAY GC. An array of `length` elements, all `filler`, or 0.
    #[verifier::external_body]
    pub fn allocate_array(&self, stack: &mut StackMem, length: usize, filler: usize) -> usize {
        let r = unsafe { toit_v2_allocate_array(self.process.cast(), length, filler) };
        *stack = self.stack();
        r
    }

    /// MAY GC. Replaces the stack by a larger one with at least `needed`
    /// free words.
    #[verifier::external_body]
    pub fn grow_stack(&self, stack: &mut StackMem, needed: usize) -> usize {
        let r = unsafe { toit_v2_grow_stack(self.process.cast(), needed) };
        *stack = self.stack();
        r
    }

    /// The allocator of the Rust primitives (allocation without GC).
    #[verifier::external_body]
    pub fn allocator(&self) -> Allocator {
        Allocator { process: self.process.cast() }
    }

    /// MAY GC, may switch the current task. Calls the C++ primitive
    /// `(module, index)` of the process' policy with its arguments at
    /// object-stack positions `first..first+arity` (`toit_v2_primitive`):
    /// status (`V2_PRIMITIVE_ABSENT` if the policy has no such primitive of
    /// that arity: nothing ran), result word, and whether the heap's epoch
    /// changed (a GC or a task switch: then the stack view is replaced by a
    /// fresh one; otherwise it stays, TRUSTED.md "Epoch").
    #[verifier::external_body]
    #[inline(always)]
    pub fn call_primitive(&self, stack: &mut StackMem, module: usize, index: usize, arity: usize, first: usize) -> (usize, usize, bool) {
        let mut result: usize = 0;
        // SAFETY: `epoch` is `ObjectHeap::v2_epoch_address` of the running
        // process (toit_v2_context::epoch), read on the thread that owns it.
        let before = unsafe { *self.epoch };
        let status = unsafe { toit_v2_primitive(self.process.cast(), module, index, arity, first, &mut result) };
        let moved = unsafe { *self.epoch } != before;
        if moved { *stack = self.stack(); }
        (status, result, moved)
    }

    #[verifier::external_body]
    pub fn report(&self, kind: usize, bci: usize, detail: usize) {
        unsafe { toit_v2_report(self.process.cast(), kind, bci, detail) }
    }

    /// Whether the VM traces every instruction (`-Xtrace`, debug builds); the
    /// checked loop then reports each one (`V2_REPORT_TRACE`). Read once per
    /// run; the verified loop does not trace.
    #[verifier::external_body]
    pub fn tracing(&self) -> bool {
        unsafe { toit_v2_tracing(self.process.cast()) != 0 }
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
            filler == crate::abs::enc(old(heap).addrs(), fv)
                && toit_spec::v2::sound::good(old(heap).objs(), fv)
                && crate::abs::encodable(old(heap).addrs(), fv),
        ensures
            r == 0 ==> *final(heap) == *old(heap),
            r != 0 ==> appended(old(heap), final(heap), r, p.ro_start, p.ro_size)
                && final(heap).objs().last() == (HeapObj {
                    class_id: p.ap@.builtin[BUILTIN_ARRAY as int], ro: false,
                    body: Body::Array(Seq::new(length as nat, |i: int| fv)) }),
    {
        // The VM exposes heap addresses as tagged words. Pass the filler with
        // exposed provenance, just like a tagged Object* from a C++ caller.
        unsafe { toit_v2_try_allocate_array(self.process, length, core::ptr::with_exposed_provenance_mut(filler)) }
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

/// Permissions supplied by the owning process for one inline allocation.
tracked struct NewSpaceWindow {
    tracked top: PointsTo<usize>,
    tracked limit: PointsTo<usize>,
    tracked exposed: IsExposed,
    tracked slots: Map<usize, PointsTo<usize>>,
}

impl NewSpaceWindow {
    spec fn owns_word(self, addr: usize) -> bool {
        &&& self.slots.contains_key(addr)
        &&& self.slots[addr].ptr() == ptr_mut_from_data::<usize>(PtrData::<usize> {
            addr, provenance: self.exposed@, metadata: (),
        })
    }

    spec fn contains_value(self, base: usize, index: usize, value: usize) -> bool {
        let a = (base + index * WORD_SIZE) as usize;
        self.slots.contains_key(a) && self.slots[a].is_init() && self.slots[a].value() == value
    }

    spec fn valid(self, top: *mut usize, limit: *mut usize) -> bool {
        &&& self.top.ptr() == top && self.top.is_init()
        &&& self.limit.ptr() == limit && self.limit.is_init()
        &&& self.top.value() <= self.limit.value()
        &&& self.top.value() == 0 ==> self.limit.value() == 0
        &&& self.top.value() % WORD_SIZE == 0 && self.limit.value() % WORD_SIZE == 0
        &&& forall|a: usize| self.top.value() <= a < self.limit.value() && a % WORD_SIZE == 0
            ==> #[trigger] self.owns_word(a)
    }
}

/// Reserve the requested bytes and write the chunk-end sentinel after them.
#[inline(always)]
fn reserve_new_space(top_slot: *mut usize, limit_slot: *mut usize, size: usize,
                     Tracked(window): Tracked<NewSpaceWindow>) -> (r: (usize, Tracked<NewSpaceWindow>))
    requires window.valid(top_slot, limit_slot), size % WORD_SIZE == 0,
    ensures
        r.1@.valid(top_slot, limit_slot),
        r.0 == 0 <==> window.limit.value() - window.top.value() <= size,
        r.0 == 0 ==> r.1@ == window,
        r.0 != 0 ==> {
            let after = r.1@;
            let end = after.top.value();
            &&& r.0 == window.top.value()
            &&& end == r.0 + size
            &&& end + WORD_SIZE <= window.limit.value()
            &&& after.limit == window.limit
            &&& forall|a: usize| window.owns_word(a) ==> #[trigger] after.owns_word(a)
            &&& after.slots.dom() == window.slots.dom()
            &&& after.slots[end].is_init() && after.slots[end].value() == CHUNK_END_SENTINEL
            &&& forall|a: usize| a != end && window.slots.contains_key(a) ==>
                #[trigger] after.slots[a] == window.slots[a]
        },
    no_unwind
{
    let ghost before = window;
    let tracked mut window = window;
    let top = *ptr_ref(top_slot, Tracked(&window.top));
    let limit = *ptr_ref(limit_slot, Tracked(&window.limit));
    if limit - top <= size { return (0, Tracked(window)); }
    let end = top + size;
    proof { assert(window.owns_word(end)); }
    let p = with_exposed_provenance(end, Tracked(window.exposed));
    ptr_mut_write(top_slot, Tracked(&mut window.top), end);
    ptr_mut_write(p, Tracked(window.slots.tracked_borrow_mut(end)), CHUNK_END_SENTINEL);
    proof {
        assert forall|a: usize| before.owns_word(a) implies #[trigger] window.owns_word(a) by {}
        assert forall|a: usize| end <= a < limit && a % WORD_SIZE == 0
            implies #[trigger] window.owns_word(a) by {
            assert(before.owns_word(a));
        }
    }
    (top, Tracked(window))
}

/// Layout of an object created by the inline allocator.
enum InlineObject {
    Instance { class_bits: u16, null: usize },
    Double { bits: u64 },
}

impl InlineObject {
    spec fn tag(&self) -> usize {
        match self {
            InlineObject::Instance { .. } => INSTANCE_TAG,
            InlineObject::Double { .. } => DOUBLE_TAG,
        }
    }

    spec fn header_bits(&self, cid: usize) -> usize {
        ((cid << CLASS_ID_OFFSET) | self.tag()) << SMI_TAG_SIZE
    }

    #[inline(always)]
    fn header(&self, cid: usize) -> (h: usize)
        ensures h == self.header_bits(cid),
            cid <= 0xffff ==> hdr_class_id(h) == cid && hdr_class_tag(h) == self.tag(),
        no_unwind
    {
        let tag = match self {
            InlineObject::Instance { .. } => INSTANCE_TAG,
            InlineObject::Double { .. } => DOUBLE_TAG,
        };
        let h = ((cid << CLASS_ID_OFFSET) | tag) << SMI_TAG_SIZE;
        proof {
            if cid <= 0xffff {
                assert(((((h as isize) >> 1usize) as usize) >> 5usize) == cid
                    && ((((h as isize) >> 1usize) as usize) & 15usize) == tag) by (bit_vector)
                    requires cid <= 0xffff, tag == 2 || tag == 4,
                        h == ((cid << 5usize) | tag) << 1usize;
            }
        }
        h
    }

    #[inline(always)]
    fn words(&self) -> (n: usize)
        ensures n == self.word_count(), n <= 0xffff,
        no_unwind
    {
        match self {
            InlineObject::Instance { class_bits, .. } => ((*class_bits >> CLASS_ID_OFFSET) & INSTANCE_SIZE_MASK) as usize,
            InlineObject::Double { .. } => 1 + 8 / WORD_SIZE,
        }
    }

    spec fn word_count(&self) -> usize {
        match self {
            InlineObject::Instance { class_bits, .. } => ((*class_bits >> CLASS_ID_OFFSET) & INSTANCE_SIZE_MASK) as usize,
            InlineObject::Double { .. } => (1 + 8usize / WORD_SIZE) as usize,
        }
    }

    spec fn word(&self, header: usize, i: usize) -> usize {
        if i == 0 { header } else { self.payload(i) }
    }

    spec fn payload(&self, i: usize) -> usize {
        match self {
            InlineObject::Instance { null, .. } => *null,
            InlineObject::Double { bits } => value_word(*bits, i - 1),
        }
    }

    #[inline(always)]
    fn payload_word(&self, i: usize) -> (w: usize)
        requires 1 <= i < self.word_count(),
        ensures w == self.payload(i),
        no_unwind
    {
        match self {
            InlineObject::Instance { null, .. } => *null,
            InlineObject::Double { bits } => {
                #[cfg(target_pointer_width = "64")]
                { *bits as usize }
                #[cfg(target_pointer_width = "32")]
                {
                    #[cfg(target_endian = "little")]
                    let low = i == 1;
                    #[cfg(target_endian = "big")]
                    let low = i == 2;
                    if low { (*bits & 0xffff_ffff) as usize } else { (*bits >> 32) as usize }
                }
            },
        }
    }
}

/// Physical reservation and initialization for the heap model proof below.
#[inline(always)]
fn allocate_new_space(top_slot: *mut usize, limit_slot: *mut usize, cid: usize,
                      object: InlineObject, Tracked(window): Tracked<NewSpaceWindow>) -> (r: (usize, Tracked<NewSpaceWindow>))
    requires window.valid(top_slot, limit_slot),
    ensures
        r.1@.valid(top_slot, limit_slot),
        r.0 == 0 <==> object.word_count() == 0 ||
            window.limit.value() - window.top.value() <= object.word_count() * WORD_SIZE,
        r.0 == 0 ==> r.1@ == window,
        r.0 != 0 ==> {
            let after = r.1@;
            let end = after.top.value();
            &&& r.0 == window.top.value()
            &&& cid <= 0xffff ==> hdr_class_id(after.slots[r.0].value()) == cid
                && hdr_class_tag(after.slots[r.0].value()) == object.tag()
            &&& end == r.0 + object.word_count() * WORD_SIZE
            &&& end + WORD_SIZE <= window.limit.value()
            &&& after.limit == window.limit
            &&& after.slots.dom() == window.slots.dom()
            &&& after.slots[end].is_init() && after.slots[end].value() == CHUNK_END_SENTINEL
            &&& forall|a: usize| window.owns_word(a) ==> #[trigger] after.owns_word(a)
            &&& forall|j: usize| j < object.word_count() ==> #[trigger] after.contains_value(
                r.0, j, object.word(object.header_bits(cid), j))
            &&& forall|a: usize| !(r.0 <= a <= end) && window.slots.contains_key(a) ==>
                #[trigger] after.slots[a] == window.slots[a]
        },
    no_unwind
{
    let header = object.header(cid);
    let n = object.words();
    if n == 0 { return (0, Tracked(window)); }
    let size = n * WORD_SIZE;
    let (top, Tracked(reserved)) = reserve_new_space(top_slot, limit_slot, size, Tracked(window));
    if top == 0 { return (0, Tracked(reserved)); }
    let tracked mut w = reserved;
    let mut i = 0usize;
    while i < n
        invariant
            window.valid(top_slot, limit_slot),
            0 < n == object.word_count(), i <= n,
            top == window.top.value(), top > 0, top % WORD_SIZE == 0,
            size == n * WORD_SIZE, top + size < window.limit.value(),
            w.top == reserved.top, w.limit == reserved.limit, w.exposed == reserved.exposed,
            w.slots.dom() == reserved.slots.dom(),
            forall|a: usize| window.owns_word(a) ==> #[trigger] w.owns_word(a),
            forall|a: usize| !(top <= a < top + i * WORD_SIZE) && reserved.slots.contains_key(a) ==>
                #[trigger] w.slots[a] == reserved.slots[a],
            forall|j: usize| j < i ==> #[trigger] w.contains_value(
                top, j, object.word(header, j)),
        decreases n - i,
    {
        let a = top + i * WORD_SIZE;
        proof { assert(window.owns_word(a)); assert(w.owns_word(a)); }
        let value = if i == 0 { header } else { object.payload_word(i) };
        let p = with_exposed_provenance(a, Tracked(w.exposed));
        let ghost before = w;
        ptr_mut_write(p, Tracked(w.slots.tracked_borrow_mut(a)), value);
        proof {
            assert forall|k: usize| window.owns_word(k) implies #[trigger] w.owns_word(k) by {
                assert(before.owns_word(k));
            }
            assert forall|j: usize| j <= i implies #[trigger] w.contains_value(
                top, j, object.word(header, j)) by {
                if j < i { assert(before.contains_value(top, j, object.word(header, j))); }
            }
        }
        i += 1;
    }
    proof {
        let end = reserved.top.value();
        assert(w.contains_value(top, 0, object.word(header, 0)));
        assert forall|a: usize| end <= a < window.limit.value() && a % WORD_SIZE == 0
            implies #[trigger] w.owns_word(a) by { assert(window.owns_word(a)); }
        assert(window.owns_word(end));
        assert(reserved.owns_word(end));
        assert(w.slots[end] == reserved.slots[end]);
        assert forall|a: usize| !(top <= a <= end) && window.slots.contains_key(a)
            implies #[trigger] w.slots[a] == window.slots[a] by {
            assert(w.slots[a] == reserved.slots[a]);
        }
    }
    (top, Tracked(w))
}

/// Inputs of the interpreter's no-GC allocation instructions.
pub(crate) enum InlineRequest {
    Instance(usize),
    Double(u64),
}

impl InlineRequest {
    pub(crate) open spec fn model(&self, p: toit_spec::v2::types::Program2, g: toit_spec::v2::types::State2) -> HeapObj {
        match self {
            InlineRequest::Instance(cid) => crate::alloc::new_instance(p, *cid as int),
            InlineRequest::Double(bits) => toit_spec::spec_common::new_double(
                toit_spec::v2::types::as1(g), toit_spec::v2::types::p1(p), *bits),
        }
    }

    pub(crate) open spec fn tables_ready(&self, p: &crate::exec::Program) -> bool {
        match self {
            InlineRequest::Instance(c) => *c < p.class_bits@.len() && (p.class_bits@[*c as int] & 0xf) == INSTANCE_TAG,
            InlineRequest::Double(_) => BUILTIN_DOUBLE < p.builtin@.len(),
        }
    }
}

impl NewSpaceWindow {
    spec fn model_word(self, top: usize, k: int, o: HeapObj, cb: Seq<u16>, addr: Seq<usize>) -> bool {
        let a = (top + k * WORD_SIZE) as usize;
        &&& self.owns_word(a)
        &&& self.slots[a].is_init()
        &&& word_val(o, cb, addr, k, self.slots[a].value())
    }
}

/// Selects the layout from the running program and relates every initialized
/// word to the same object the bytecode specification appends.
#[inline(always)]
fn allocate_modeled(top_slot: *mut usize, limit_slot: *mut usize,
                    p: &crate::exec::Program, req: InlineRequest,
                    Ghost(g): Ghost<toit_spec::v2::types::State2>, Ghost(addr): Ghost<Seq<usize>>,
                    Tracked(window): Tracked<NewSpaceWindow>) -> (r: (usize, Tracked<NewSpaceWindow>))
    requires
        window.valid(top_slot, limit_slot), req.tables_ready(p), crate::exec::ro_ok(p),
        crate::abs::prog_rel(p, g.heap, addr),
    ensures
        r.1@.valid(top_slot, limit_slot),
        r.0 == 0 ==> r.1@ == window,
        r.0 != 0 ==> {
            let o = req.model(p.ap@, g);
            let end = r.1@.top.value();
            &&& (o.class_id as int) < p.ap@.class_bits.len()
            &&& (p.ap@.class_bits[o.class_id as int] & 0xf) == (if o.body is Instance { INSTANCE_TAG } else { DOUBLE_TAG })
            &&& o.body is Instance ==> o.body->Instance_0.len() == crate::abs::ifc_bits(p.ap@.class_bits, o.class_id as int)
            &&& r.0 == window.top.value()
            &&& p.ro_size == 0 || end + WORD_SIZE <= p.ro_start || p.ro_start + p.ro_size <= r.0
            &&& end == r.0 + obj_words(o) * WORD_SIZE
            &&& r.1@.slots[end].is_init() && r.1@.slots[end].value() == CHUNK_END_SENTINEL
            &&& forall|k: int| is_word(o, k) ==>
                #[trigger] r.1@.model_word(r.0, k, o, p.ap@.class_bits, addr)
        },
    no_unwind
{
    // Check the entire remaining window, including the chunk-end sentinel,
    // before any object or allocator metadata is modified.
    let top = *ptr_ref(top_slot, Tracked(&window.top));
    let limit = *ptr_ref(limit_slot, Tracked(&window.limit));
    if p.ro_size != 0 && top < p.ro_start + p.ro_size && p.ro_start < limit {
        return (0, Tracked(window));
    }
    let (cid, layout) = match &req {
        InlineRequest::Instance(c) => {
            if *c > 0xffff { return (0, Tracked(window)); }
            let bits = p.class_bits.at(*c);
            (*c, InlineObject::Instance { class_bits: bits, null: p.null })
        },
        InlineRequest::Double(bits) => {
            let w = p.builtin.at(BUILTIN_DOUBLE);
            let cid = w >> SMI_TAG_SIZE;
            proof {
                let c = p.ap@.builtin[BUILTIN_DOUBLE as int];
                assert(p.builtin@[BUILTIN_DOUBLE as int] == crate::abs::smi_word(c as i64));
                assert(w == ((c as usize) + (c as usize)) as usize);
                assert(cid == c as usize) by (bit_vector)
                    requires w == (c as usize).wrapping_add(c as usize), cid == w >> 1usize;
            }
            if cid >= p.class_bits.len() || (p.class_bits.at(cid) & 0xf) != DOUBLE_TAG as u16 {
                return (0, Tracked(window));
            }
            (cid, InlineObject::Double { bits: *bits })
        },
    };
    let ghost header = layout.header_bits(cid);
    let ghost o = req.model(p.ap@, g);
    let (top, Tracked(after)) = allocate_new_space(top_slot, limit_slot, cid, layout, Tracked(window));
    if top != 0 {
        proof {
            assert(p.roots@[0] == crate::abs::enc(addr, p.ap@.roots[0]));
            assert(layout.word_count() == obj_words(o));
            assert forall|k: int| is_word(o, k) implies #[trigger]
                after.model_word(top, k, o, p.ap@.class_bits, addr) by {
                let j = k as usize;
                assert(0 <= k < layout.word_count());
                assert(after.contains_value(top, j, layout.word(header, j)));
            }
        }
    }
    (top, Tracked(after))
}

proof fn take_inline_words(tracked window: NewSpaceWindow, top: usize, id: int, o: HeapObj,
                           cb: Seq<u16>, addr: Seq<usize>) -> (tracked words: Map<(int, int), PointsTo<usize>>)
    requires
        o.body is Instance || o.body is Double,
        top + obj_words(o) * WORD_SIZE <= usize::MAX,
        forall|k: int| is_word(o, k) ==> #[trigger] window.model_word(top, k, o, cb, addr),
    ensures
        words.dom() == inline_keys(id, o),
        forall|key: (int, int)| words.contains_key(key) ==> (#[trigger] words[key]).ptr()@.provenance == window.exposed@,
        forall|k: int| is_word(o, k) ==> #[trigger] inline_word(words, id, k, top, o, cb, addr),
{
    let indices = Seq::new(obj_words(o) as nat, |k: int| (id, k));
    assert forall|key: (int, int)| #[trigger] indices.to_set().contains(key) <==>
        key.0 == id && 0 <= key.1 < obj_words(o) by {
        if indices.contains(key) {
            let k = choose|k: int| 0 <= k < indices.len() && indices[k] == key;
        } else if key.0 == id && 0 <= key.1 < obj_words(o) {
            assert(indices[key.1] == key);
        }
    }
    let keys = Map::new(inline_keys(id, o), |key: (int, int)| (top + key.1 * WORD_SIZE) as usize);
    assert forall|key: (int, int)| keys.contains_key(key) implies window.slots.contains_key(keys[key]) by {
        assert(window.model_word(top, key.1, o, cb, addr));
    }
    assert forall|x: (int, int), y: (int, int)| x != y && keys.contains_key(x) && keys.contains_key(y)
        implies keys[x] != keys[y] by {
        assert(keys[x] == top + x.1 * WORD_SIZE);
        assert(keys[y] == top + y.1 * WORD_SIZE);
    }
    let tracked words = Map::tracked_map_keys(window.slots, keys);
    assert forall|key: (int, int)| words.contains_key(key) implies
        (#[trigger] words[key]).ptr()@.provenance == window.exposed@ by {
        assert(window.model_word(top, key.1, o, cb, addr));
        assert(words[key] == window.slots[keys[key]]);
    }
    assert forall|k: int| is_word(o, k) implies #[trigger] inline_word(words, id, k, top, o, cb, addr) by {
        assert(keys.contains_key((id, k)));
        assert(window.model_word(top, k, o, cb, addr));
        assert(words[(id, k)] == window.slots[keys[(id, k)]]);
    }
    words
}

impl Runtime {
    /// Each fast-path allocation acquires the currently owned window after
    /// the last possible GC, and consumes its permissions before returning.
    #[verifier::external_body]
    #[inline(always)]
    fn allocation_window(&self) -> (w: Tracked<NewSpaceWindow>)
        ensures w@.valid(self.ns_top, self.ns_limit as *mut usize),
    {
        Tracked::assume_new()
    }

    #[inline(always)]
    pub(crate) fn bump(&self, m: &mut crate::exec::Machine, p: &crate::exec::Program,
                       req: InlineRequest, Ghost(r): Ghost<crate::regs::Regs>) -> (tagged: usize)
        requires old(m).with(r).inv(p), req.tables_ready(p), crate::exec::ro_ok(p),
        ensures
            tagged == 0 ==> *final(m) == *old(m),
            tagged != 0 ==> *final(m) == (crate::exec::Machine { heap: final(m).heap, ..*old(m) })
                && (crate::exec::Machine {
                    g: Ghost(toit_spec::v2::spec::alloc2(old(m).g@, req.model(p.ap@, old(m).g@))), ..*final(m)
                }).with(r).refines(p)
                && tagged == crate::abs::enc(final(m).addr(), toit_spec::v2::spec::new_ref2(old(m).g@)),
    {
        let Tracked(window) = self.allocation_window();
        let ghost g = m.g@;
        let ghost o = req.model(p.ap@, g);
        let (top, Tracked(after)) = allocate_modeled(self.ns_top, self.ns_limit as *mut usize, p, req, Ghost(g), Ghost(m.addr()), Tracked(window));
        if top == 0 { return 0; }
        let ghost before = *m;
        let tagged = top | HEAP_TAG;
        proof {
            assert(tagged & 3 == HEAP_TAG && tagged != 0) by (bit_vector)
                requires tagged == top | 1usize, top % 4usize == 0, HEAP_TAG == 1usize;
        }
        let ghost initialized = after;
        let tracked mut after = after;
        proof {
            assert(after.model_word(top, 0, o, p.ap@.class_bits, m.addr()));
            assert(top == tagged - HEAP_TAG) by (bit_vector)
                requires tagged == top | 1usize, top % 4usize == 0, HEAP_TAG == 1usize;
        }
        m.heap.prove_fresh_header(Ghost(tagged), Tracked(after.slots.tracked_borrow_mut(top)));
        proof {
            assert(after.slots =~= initialized.slots);
            let null = toit_spec::v2::spec::null2(p.ap@);
            assert(crate::abs::const_ok(g.heap, null));
            if o.body is Instance {
                assert forall|i: int| 0 <= i < o.body->Instance_0.len()
                    implies #[trigger] crate::abs::encodable(m.addr(), o.body->Instance_0[i]) by {
                    assert(o.body->Instance_0[i] == null);
                }
            }
        }
        let tracked token = after.exposed;
        let tracked words = take_inline_words(after, top, m.heap.objs().len() as int, o, p.ap@.class_bits, m.addr());
        m.heap.register_inline(p, Ghost(top), Ghost(tagged), Ghost(o), Tracked(token), Tracked(words));
        proof {
            let h0 = &before.heap;
            let h1 = &m.heap;
            let n = h0.objs().len() as int;
            crate::primitive::lemma_heap_inv(p, before.with(r));
            assert(h1.objs().last() == o);
            if o.body is Instance {
                let null = toit_spec::v2::spec::null2(p.ap@);
                assert(crate::abs::const_ok(h0.objs(), null));
                assert forall|i: int| 0 <= i < o.body->Instance_0.len()
                    implies toit_spec::v2::sound::good(h1.objs(), #[trigger] o.body->Instance_0[i])
                        && crate::abs::encodable(h1.addrs(), o.body->Instance_0[i]) by {
                    assert(o.body->Instance_0[i] == null);
                }
            }
            crate::prims::lemma_post_append(p, h0, h1, tagged);
            let next = crate::exec::Machine { g: Ghost(toit_spec::v2::spec::alloc2(g, o)), ..*m };
            crate::primitive::lemma_refines_heap(p, before.with(r), next.with(r));
            assert(h1.addrs()[n] == tagged);
        }
        tagged
    }
}

} // verus!

impl Runtime {
    pub fn new(process: *mut c_void, array_word: usize, epoch: *const usize,
               ns_top: *mut usize, ns_limit: *const usize) -> Self {
        Runtime { process: process.cast(), array_word, epoch, ns_top, ns_limit }
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
    let builtin = |k: usize| -> usize { *p.builtin_class_ids.add(k) >> 1 };
    // The bytecodes are 2-byte aligned (`prog_rel`: the header fields are
    // read with aligned 16-bit loads; V2MethodTable::compute checks it too).
    if p.roots_length < ROOT_COUNT || p.literals_length < FAILURE_LITERALS || p.methods_length == 0
        || p.methods_length >= MAX_TABLE || p.bytecodes_length >= MAX_TABLE
        || (p.bytecodes as usize) & 1 != 0 {
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
        // The verifier table of the process' policy
        // (PrimitivePolicy::verifier_arities), the one the verdict was
        // computed with: a primitive runs only if it allows it.
        policy: Table::from_raw(c.policy_arities, if c.policy_arities.is_null() { 0 } else { c.policy_arities_length }),
        policy_counts: Table::from_raw(c.policy_counts, if c.policy_counts.is_null() { 0 } else { c.policy_modules }),
        policy_starts: Table::from_raw(c.policy_starts, if c.policy_starts.is_null() { 0 } else { c.policy_modules }),
        ro_start: p.program_heap_start,
        ro_size: p.program_heap_size,
        max_height: p.global_max_height,
        preempt_a_lot: c.preempt_a_lot != 0,
        unchecked: c.unchecked != 0,
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
    let runtime = Runtime::new(c.process, p.stack_array_word, c.epoch,
        c.new_space_top, c.new_space_limit);
    let globals = Globals::from_raw(p.globals, p.globals_length);
    let heap = Heap::new(p.remembered_set_bias);
    let preemption = Preemption::from_raw(c.watermark);
    // The verified run loop needs an `Accepted` token, which exists only
    // here and only for a context whose table the launch-time verifier
    // accepted (TOIT_V2_ACCEPTED, set by Interpreter::run_v2 from
    // V2MethodTable::verified, which only V2Verifier::verify's accept path
    // sets).
    // A trusted program the launch did not verify (TOIT_V2_TRUSTED) gets
    // the token on trust (`Accepted::trusted_program`).
    let accepted = if c.accepted == V2_ACCEPTED {
        Some(Accepted { _private: () })
    } else if c.accepted == V2_TRUSTED {
        Some(Accepted::trusted_program())
    } else {
        None
    };
    let (state, value) = crate::machine::run(program, runtime, globals, heap, preemption, accepted);
    c.result_state = state;
    c.result_value = value;
    state
}

/// Instruction length of a format-2 opcode (for the layout check).
#[cfg(feature = "layout-tables")]
#[no_mangle]
pub extern "C" fn toit_vcore_opcode_length(opcode: usize) -> usize {
    if opcode < crate::machine::OPCODE_LENGTHS.len() { crate::machine::opcode_length(opcode as u8) } else { 0 }
}

macro_rules! layout_table {
    ($($name:ident),* $(,)?) => {
        const LAYOUT: &[(&[u8], usize)] = &[
            $((concat!(stringify!($name), "\0").as_bytes(), $name as usize),)*
        ];
    };
}

layout_table!(
    WORD_SIZE, CHUNK_END_SENTINEL, SMI_TAG_SIZE, SMI_TAG_MASK, SMI_TAG, NON_SMI_TAG_MASK, HEAP_TAG, ERROR_TAG,
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
    STACK_LENGTH_WORD, STACK_TOP_WORD, STACK_RECORD_TOP_WORD, STACK_BCI_WORD, STACK_FRAME_TOP_SHIFT,
    MAX_STACK_LENGTH, WORD_BITS,
    FRAME_WORDS, FRAME_METHOD, FRAME_RET, FRAME_BASE, FRAME_HANDLER, FRAME_HANDLER_BCI, STACK_RESERVE,
    FIN_WORDS, FIN_FRAME, FIN_HEIGHT, FIN_RESUME, FIN_TARGET, FIN_TARGET_HEIGHT,
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
    V2_PRIMITIVE_THROW, V2_PRIMITIVE_MISSING, V2_PRIMITIVE_FOUND, V2_PRIMITIVE_ABSENT, V2_ACCEPTED, V2_TRUSTED, V2_REPORT_STUCK,
    V2_REPORT_UNCAUGHT, V2_REPORT_TASK_RETURNED, V2_REPORT_TRACE,
    V2_MESSAGE_NONE, V2_MESSAGE_WORD, V2_MESSAGE_ARRAY, V2_MESSAGE_PRIMITIVE, V2_MESSAGE_MAX_WORDS,
    KIND_METHOD, KIND_FIELD_ACCESSOR, KIND_LAMBDA, KIND_BLOCK, NO_VALUE, BLOCK_SLOT_BITS,
    FAILURE_LITERALS, MAX_INSTRUCTION_LENGTH, MAX_TABLE, TASK_STACK_FIELD, TASK_ID_FIELD,
    RECORD_ENTRY_SHIFT, RECORD_ARITY_MASK, KIND_MASK, KIND_SINGLE, SELECTOR_BACK, RECV_START_BACK,
    RECV_END_BACK, ACCESSOR_AUX_BACK, LAMBDA_AUX_BACK, MAX_BYTECODES,
);

/// The C ABI of the FFI structs.
const STRUCT_LAYOUT: &[(&[u8], usize)] = &[
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
    (b"PROGRAM_program_heap_size\0", core::mem::offset_of!(ProgramTables, program_heap_size)),
    (b"PROGRAM_remembered_set_bias\0", core::mem::offset_of!(ProgramTables, remembered_set_bias)),
    (b"PROGRAM_global_max_height\0", core::mem::offset_of!(ProgramTables, global_max_height)),
    (b"PROGRAM_stack_array_word\0", core::mem::offset_of!(ProgramTables, stack_array_word)),
    (b"CONTEXT_SIZE\0", core::mem::size_of::<Context>()),
    (b"CONTEXT_process\0", core::mem::offset_of!(Context, process)),
    (b"CONTEXT_program\0", core::mem::offset_of!(Context, program)),
    (b"CONTEXT_watermark\0", core::mem::offset_of!(Context, watermark)),
    (b"CONTEXT_preempt_a_lot\0", core::mem::offset_of!(Context, preempt_a_lot)),
    (b"CONTEXT_accepted\0", core::mem::offset_of!(Context, accepted)),
    (b"CONTEXT_policy_arities\0", core::mem::offset_of!(Context, policy_arities)),
    (b"CONTEXT_policy_arities_length\0", core::mem::offset_of!(Context, policy_arities_length)),
    (b"CONTEXT_policy_counts\0", core::mem::offset_of!(Context, policy_counts)),
    (b"CONTEXT_policy_starts\0", core::mem::offset_of!(Context, policy_starts)),
    (b"CONTEXT_policy_modules\0", core::mem::offset_of!(Context, policy_modules)),
    (b"CONTEXT_epoch\0", core::mem::offset_of!(Context, epoch)),
    (b"CONTEXT_unchecked\0", core::mem::offset_of!(Context, unchecked)),
    (b"CONTEXT_new_space_top\0", core::mem::offset_of!(Context, new_space_top)),
    (b"CONTEXT_new_space_limit\0", core::mem::offset_of!(Context, new_space_limit)),
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
        UNWIND, HALT, BRANCH_S, BRANCH_IF_NOT_NULL_S, BRANCH_BACK_S,
    )
};

/// Number of layout entries.
#[cfg(feature = "layout-tables")]
#[no_mangle]
pub extern "C" fn toit_vcore_layout_count() -> usize {
    LAYOUT.len() + STRUCT_LAYOUT.len() + OPCODES.len()
}

/// Layout entry `i`: writes its NUL-terminated name and value. Returns false
/// if `i` is out of range.
///
/// # Safety
/// `name` and `value` must be valid for writes.
#[cfg(feature = "layout-tables")]
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
#[cfg(feature = "layout-tables")]
#[no_mangle]
pub extern "C" fn toit_vcore_prim_count() -> usize {
    crate::prims::index::TABLE.len()
}

/// Primitive table entry `i`: its NUL-terminated name, index and arity.
///
/// # Safety
/// `name`, `index` and `arity` must be valid for writes.
#[cfg(feature = "layout-tables")]
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
