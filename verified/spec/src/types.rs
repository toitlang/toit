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

//! Abstract state of the Toit bytecode machine.
//!
//! Two layers share the `Value` type:
//! * spec layer (`HeapObj`, `Program`, `State`): mathematical sequences,
//!   used by `spec_step`.
//! * exec layer (`ExecObj`, `ExecProgram`, `ExecState`): vectors, used by
//!   the reference interpreter. Each exec type has a `view` into the spec
//!   layer; the agreement theorems in `exec_step` are stated over views.

use vstd::prelude::*;
use alloc::vec::Vec;

verus! {

/// A word on the task stack, in a global variable, or in an object field.
///
/// In the C++ VM every one of these is a machine word. Smis, block
/// references, and try-chain links are all tagged as smis there; return
/// addresses are raw bytecode pointers and the frame marker is a tagged
/// pointer to the bytecodes. The spec keeps the provenance, so that using a
/// word as something it was not created as is a stuck state.
#[derive(PartialEq, Eq, Clone, Copy)]
pub enum Value {
    /// A small integer. Always in `smi_min(p)..=smi_max(p)` of the program's
    /// word size.
    Smi(i64),
    /// A reference to `State.heap[id]`.
    Obj(usize),
    /// A return address: the absolute bytecode index to continue at.
    RetAddr(usize),
    /// The frame marker pushed with every return address.
    FrameMarker,
    /// A block reference. The payload is the stack height `h` such that the
    /// referenced slot is `stack[h - 1]` (the C++ VM stores
    /// `base - pointer + BLOCK_SALT`; height 0 is `base` itself).
    Block(usize),
    /// A try/finally chain link: the previous `try_h`.
    Link(usize),
    /// Format 2: a block reference `(frame, slot)`: the block's method id is
    /// in `stack[slot]`, a slot of the frame `frames[frame]` that created the
    /// block. Only LOAD_BLOCK, LOAD_OUTER_BLOCK and TRY create them.
    BlockRef(usize, usize),
    /// Format 3 (format note 23): a word of the unwinding token of a
    /// finally code, `Token(second, pending, frame, height)`: the first
    /// (`second == false`) or the second word, the unwinding the finally
    /// code resumes at its UNWIND, the frame running the finally code and
    /// the height of its value slot (the token words are the slots at
    /// `height + 1` and `height + 2`). Only entering a finally code
    /// creates them; the machine's words are smis (`Pending`'s encoding).
    Token(bool, Pending, usize, usize),
}

/// Format 2: an activation on the frame stack. The object stack holds only
/// values; the frame stack holds the return addresses.
#[derive(PartialEq, Eq, Clone, Copy)]
pub struct Frame {
    /// Index of the method in the program's method table.
    pub method: usize,
    /// Absolute bci in the caller to continue at after the return.
    pub ret: usize,
    /// Object-stack index of the first parameter. The frame owns
    /// `stack[base..]` up to the next frame's base.
    pub base: usize,
    /// Format 3 (format note 23): the frame is a try block called by TRY.
    /// Returning from it, or unwinding past it, enters the finally code of
    /// the frame below at `ret` with the object stack cut to `base`.
    pub handler: bool,
}

/// Format 2: an unwinding in progress.
#[derive(PartialEq, Eq, Clone, Copy)]
pub enum Unwind {
    /// An exception: unwind to the next handler; uncaught at the bottom.
    Throw(Value),
    /// A non-local return of `value` from frame `frame`.
    Return(usize, Value),
    /// A non-local branch into frame `frame`: continue at absolute bci `bci`
    /// with object-stack height `height`.
    Branch(usize, usize, usize),
}

/// Format 3 (format note 23): what a finally code does at its UNWIND, held
/// by its token: continue after a normal completion, or resume an
/// unwinding. The exception or return value is not part of it: it is the
/// finally code's value slot.
#[derive(PartialEq, Eq, Clone, Copy)]
pub enum Pending {
    Normal,
    Throw,
    /// A non-local return from frame `frame`.
    Return(usize),
    /// A non-local branch into frame `frame` to absolute bci `bci` with
    /// object-stack height `height`.
    Branch(usize, usize, usize),
}

/// Format 2: an entry of the method table, decoded from the method headers
/// by the (trusted) loader.
#[derive(PartialEq, Eq, Clone, Copy)]
pub struct MethodInfo {
    pub arity: u8,
    /// 0 method, 1 field accessor, 2 lambda, 3 block.
    pub kind: u8,
    pub max_height: u16,
    /// Selector offset, 0xffff for none.
    pub selector: u16,
    /// Captured count (lambda), field index (field accessor).
    pub aux: u16,
    /// Declared receiver class-id range `[recv_start, recv_end)`;
    /// `recv_start == 0xffff` for none.
    pub recv_start: u16,
    pub recv_end: u16,
    /// Absolute bci of the first instruction.
    pub entry: usize,
    /// Absolute bci after the last instruction.
    pub end: usize,
}

/// Payload of a heap object.
pub enum Body {
    Instance(Seq<Value>),
    Array(Seq<Value>),
    Bytes(Seq<u8>),
    Str(Seq<u8>),
    /// IEEE-754 bit pattern.
    Double(u64),
    LargeInt(i64),
    /// null, true, false.
    Oddball,
    /// A suspended task stack: words (bottom first) and try height.
    Stack(Seq<Value>, usize),
    /// Format 2: a suspended task: object stack, frame stack and the bci it
    /// is suspended at. A task that never ran has no frames and the code to
    /// run as its only stack slot.
    Stack2(Seq<Value>, Seq<Frame>, usize),
}

pub struct HeapObj {
    pub class_id: u16,
    /// Object lives in the read-only program heap.
    pub ro: bool,
    pub body: Body,
}

/// Immutable program tables. See `src/program.h`.
pub struct Program {
    /// 32 or 64.
    pub word_bits: u8,
    pub bytecodes: Seq<u8>,
    /// `method_start[i]` iff a method header starts at absolute offset `i`.
    /// Same length as `bytecodes`. Taken from the snapshot's method table.
    pub method_start: Seq<bool>,
    pub dispatch: Seq<i32>,
    pub class_bits: Seq<u16>,
    pub class_check_ids: Seq<u16>,
    pub interface_check_offsets: Seq<u16>,
    /// Selector offsets for INVOKE_EQ..INVOKE_SIZE (19 entries).
    pub invoke_offsets: Seq<i32>,
    /// Dispatch-table indexes of the 9 entry points (entry_points.h).
    pub entry_points: Seq<i32>,
    /// The 23 builtin class ids (BUILTIN_CLASS_IDS in program.h).
    pub builtin: Seq<u16>,
    /// PROGRAM_ROOTS followed by ERROR_STRINGS (35 entries).
    pub roots: Seq<Value>,
    pub literals: Seq<Value>,
}

/// State of one process: heap, globals, and the running task.
/// Suspended tasks keep their stacks in `Body::Stack` heap objects.
pub struct State {
    pub heap: Seq<HeapObj>,
    pub globals: Seq<Value>,
    /// Running task's stack, bottom first. `stack[len - 1]` is the C++ `*sp`.
    pub stack: Seq<Value>,
    /// Height of `try_sp_` (0 means `try_sp_ == base_`, no handler).
    pub try_h: usize,
    /// Absolute bytecode index of the next instruction.
    pub bci: usize,
    /// Object id of the running Task.
    pub task: usize,
    /// Next task id handed out by `task_new`.
    pub next_task_id: i64,
}

/// Why the machine cannot take a step. Each corresponds to an operation that
/// the C++ VM performs without a check and that would read or write memory
/// with an undefined meaning.
#[derive(PartialEq, Eq, Clone, Copy)]
pub enum Stuck {
    /// bci outside the bytecodes, opcode >= 105, or instruction truncated.
    BadInstruction,
    /// Stack slot outside the stack.
    StackRange,
    /// Expected a value word (Smi/Obj/Block/Link), found a frame word.
    FrameWord,
    /// Expected a frame marker / return address and found something else.
    BadFrame,
    NotSmi,
    NotObject,
    NotInstance,
    NotArray,
    NotBlock,
    NotLink,
    /// Object field index out of range.
    FieldRange,
    /// Program table index out of range (literals, globals, dispatch,
    /// class bits, class checks, interface checks).
    TableRange,
    /// Call/jump target is not the start of a method.
    NotMethod,
    /// Branch target outside the bytecodes.
    BadBranch,
    /// Write into the read-only program heap.
    ReadOnly,
    /// ALLOCATE of a class whose tag is not INSTANCE_TAG.
    NotInstantiable,
    /// The C++ VM calls FATAL.
    Fatal,
    /// A smi result outside the smi range in a place where the C++ VM
    /// would silently wrap and the spec chooses not to.
    SmiRange,
    /// Iteration bound of a fuel-limited helper exceeded (the C++ VM may
    /// loop forever on corrupted collections).
    OutOfFuel,
    /// Format 2: a call whose target's arity differs from the call site's.
    BadArity,
    /// Format 2: UNWIND without the two words of one unwinding token of the
    /// frame, made for the UNWIND's height, in its token slots.
    NotUnwind,
}

pub enum HaltKind {
    /// HALT 0: yield to the scheduler; resumes at `bci` with 91 pushed.
    Yield,
    /// HALT 1: process exit with the given value.
    Exit(i64),
    /// HALT 2: deep sleep.
    DeepSleep,
    /// HALT 3 (and anything larger): reset.
    Reset,
}

/// Result of one step.
pub enum Outcome {
    Next(State),
    Stuck(Stuck),
    /// A PRIMITIVE bytecode (module, index): the state is unchanged (bci
    /// still points at the PRIMITIVE). The step is completed by the
    /// primitive oracle via `prim_success`, `prim_failure` or
    /// `prim_missing`, or for the machine-level task primitives by
    /// `task_new_step`/`task_transfer_step` (see spec_prim.rs).
    Primitive(State, u8, u16),
    Halt(State, HaltKind),
}

// ---------------------------------------------------------------------------
// Exec mirror.

pub enum ExecBody {
    Instance(Vec<Value>),
    Array(Vec<Value>),
    Bytes(Vec<u8>),
    Str(Vec<u8>),
    Double(u64),
    LargeInt(i64),
    Oddball,
    Stack(Vec<Value>, usize),
    Stack2(Vec<Value>, Vec<Frame>, usize),
}

pub struct ExecObj {
    pub class_id: u16,
    pub ro: bool,
    pub body: ExecBody,
}

impl View for ExecBody {
    type V = Body;
    open spec fn view(&self) -> Body {
        match self {
            ExecBody::Instance(v) => Body::Instance(v@),
            ExecBody::Array(v) => Body::Array(v@),
            ExecBody::Bytes(v) => Body::Bytes(v@),
            ExecBody::Str(v) => Body::Str(v@),
            ExecBody::Double(b) => Body::Double(*b),
            ExecBody::LargeInt(i) => Body::LargeInt(*i),
            ExecBody::Oddball => Body::Oddball,
            ExecBody::Stack(v, h) => Body::Stack(v@, *h),
            ExecBody::Stack2(v, f, b) => Body::Stack2(v@, f@, *b),
        }
    }
}

impl View for ExecObj {
    type V = HeapObj;
    open spec fn view(&self) -> HeapObj {
        HeapObj { class_id: self.class_id, ro: self.ro, body: self.body@ }
    }
}

pub struct ExecProgram {
    pub word_bits: u8,
    pub bytecodes: Vec<u8>,
    pub method_start: Vec<bool>,
    pub dispatch: Vec<i32>,
    pub class_bits: Vec<u16>,
    pub class_check_ids: Vec<u16>,
    pub interface_check_offsets: Vec<u16>,
    pub invoke_offsets: Vec<i32>,
    pub entry_points: Vec<i32>,
    pub builtin: Vec<u16>,
    pub roots: Vec<Value>,
    pub literals: Vec<Value>,
    /// Format 2: the method table (empty for format 1). Not part of the
    /// format-1 view.
    pub methods: Vec<MethodInfo>,
    /// Format 2: the method records (format note 21), which `methods`
    /// decodes with the headers in `bytecodes` (empty for format 1).
    pub recs: Vec<u32>,
}

impl View for ExecProgram {
    type V = Program;
    open spec fn view(&self) -> Program {
        Program {
            word_bits: self.word_bits,
            bytecodes: self.bytecodes@,
            method_start: self.method_start@,
            dispatch: self.dispatch@,
            class_bits: self.class_bits@,
            class_check_ids: self.class_check_ids@,
            interface_check_offsets: self.interface_check_offsets@,
            invoke_offsets: self.invoke_offsets@,
            entry_points: self.entry_points@,
            builtin: self.builtin@,
            roots: self.roots@,
            literals: self.literals@,
        }
    }
}

pub struct ExecState {
    pub heap: Vec<ExecObj>,
    pub globals: Vec<Value>,
    pub stack: Vec<Value>,
    pub try_h: usize,
    pub bci: usize,
    pub task: usize,
    pub next_task_id: i64,
    /// Format 2: the frame stack (empty for format 1). Not part of the
    /// format-1 view.
    pub frames: Vec<Frame>,
}

impl View for ExecState {
    type V = State;
    open spec fn view(&self) -> State {
        State {
            heap: self.heap@.map_values(|o: ExecObj| o@),
            globals: self.globals@,
            stack: self.stack@,
            try_h: self.try_h,
            bci: self.bci,
            task: self.task,
            next_task_id: self.next_task_id,
        }
    }
}

} // verus!
