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

//! Abstract state of the format-2 machine.
//!
//! Values, heap objects, frames and unwindings are shared with
//! format 1 (`crate::types`). The differences: the program has a method
//! table instead of a method-start bitmap, and the state has a frame stack
//! next to the object stack. The object stack holds only values (smis,
//! references, block references, unwinding tokens).
//!
//! The exec layer is the same `ExecProgram`/`ExecState` as for format 1
//! (with the `methods` and `frames` fields filled in); `view2` and
//! `pview2` are their format-2 views.

use vstd::prelude::*;
use crate::types::*;

verus! {

pub struct Program2 {
    pub word_bits: u8,
    pub bytecodes: Seq<u8>,
    /// The method table: method id `m` is `methods[m]`.
    pub methods: Seq<MethodInfo>,
    /// Method ids (or -1), indexed by class id + selector offset; static
    /// methods occupy single entries (INVOKE_STATIC's operand).
    pub dispatch: Seq<i32>,
    pub class_bits: Seq<u16>,
    pub class_check_ids: Seq<u16>,
    pub interface_check_offsets: Seq<u16>,
    pub invoke_offsets: Seq<i32>,
    pub entry_points: Seq<i32>,
    pub builtin: Seq<u16>,
    pub roots: Seq<Value>,
    /// `literals[0..2]` are true and false, `literals[2..7]` the values of
    /// the exceptions the machine raises (see `RaiseKind`).
    pub literals: Seq<Value>,
    /// The unchecked mode of trusted programs (`spec::unchecked_fail`): field
    /// accesses are not checked at run time. Only trusted programs may use
    /// it (`verifier::accepts`); the executable views have it off.
    pub unchecked: bool,
}

pub struct State2 {
    pub heap: Seq<HeapObj>,
    pub globals: Seq<Value>,
    /// Object stack of the running task, bottom first.
    pub stack: Seq<Value>,
    /// Frame stack, bottom first. The top frame is the running method.
    pub frames: Seq<Frame>,
    /// Absolute bci of the next instruction, inside the top frame's method.
    pub bci: usize,
    pub task: usize,
    pub next_task_id: i64,
}

pub enum Halt2 {
    /// HALT 0: yield; resumes at `bci` with 91 pushed.
    Yield,
    /// HALT 1.
    Exit(i64),
    /// HALT 2.
    DeepSleep,
    /// HALT 3.
    Reset,
    /// An exception unwound past the bottom frame. The entry methods of
    /// the core library catch everything, so this ends the task.
    Uncaught(Value),
    /// The bottom frame returned. Ends the task.
    TaskReturned,
}

pub enum Outcome2 {
    Next(State2),
    Stuck(Stuck),
    /// A PRIMITIVE (module, index): completed by `v2::prim`.
    Primitive(State2, u8, u16),
    Halt(State2, Halt2),
    /// The machine raises an exception with value `v` in state `s`: it
    /// allocates an `Exception_` holding `v` and a trace of its choosing (a
    /// GC point that may run out of memory) and unwinds. Completed by
    /// `v2::prim::raised`; `v2::spec::throw_exception` is one completion.
    Raise(State2, Value),
}

pub open spec fn pview2(p: &ExecProgram) -> Program2 {
    Program2 {
        word_bits: p.word_bits,
        bytecodes: p.bytecodes@,
        methods: p.methods@,
        dispatch: p.dispatch@,
        class_bits: p.class_bits@,
        class_check_ids: p.class_check_ids@,
        interface_check_offsets: p.interface_check_offsets@,
        invoke_offsets: p.invoke_offsets@,
        entry_points: p.entry_points@,
        builtin: p.builtin@,
        roots: p.roots@,
        literals: p.literals@,
        unchecked: false,
    }
}

pub open spec fn view2(s: &ExecState) -> State2 {
    State2 {
        heap: s.heap@.map_values(|o: ExecObj| o@),
        globals: s.globals@,
        stack: s.stack@,
        frames: s.frames@,
        bci: s.bci,
        task: s.task,
        next_task_id: s.next_task_id,
    }
}

// ---------------------------------------------------------------------------
// Adapters to the format-1 vocabulary for the parts of the state the two
// formats share (heap, globals, program tables). The format-1 helpers that
// only look at those (typechecks, number comparison, fast_at, ...) are
// reused through them.

pub open spec fn as1(s: State2) -> State {
    State {
        heap: s.heap,
        globals: s.globals,
        stack: s.stack,
        try_h: 0,
        bci: s.bci,
        task: s.task,
        next_task_id: s.next_task_id,
    }
}

pub open spec fn p1(p: Program2) -> Program {
    Program {
        word_bits: p.word_bits,
        bytecodes: p.bytecodes,
        method_start: Seq::new(p.bytecodes.len(), |i: int| false),
        dispatch: p.dispatch,
        class_bits: p.class_bits,
        class_check_ids: p.class_check_ids,
        interface_check_offsets: p.interface_check_offsets,
        invoke_offsets: p.invoke_offsets,
        entry_points: p.entry_points,
        builtin: p.builtin,
        roots: p.roots,
        literals: p.literals,
    }
}

} // verus!
