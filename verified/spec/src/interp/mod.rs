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

//! The reference interpreter: runs a loaded program on the abstract state.
//!
//! Not verified. The step for each opcode either calls the verified
//! `exec_step` (stack and arithmetic opcodes) or the unverified mirror of
//! the spec in `exec.rs`/`intrinsics.rs`. Primitives are implemented in
//! `prims.rs`; the system process is emulated in `system.rs`.

pub mod loader;
pub mod exec;
pub mod exec2;
pub mod intrinsics;
pub mod prims;
pub mod prims_impl;
pub mod floatfmt;
pub mod system;

use crate::types::*;
pub use exec::is_value;
pub use intrinsics::FastAt;

// Builtin class indexes (BUILTIN_CLASS_IDS in program.h).
pub const STRING_CLASS: usize = 0;
pub const ARRAY_CLASS: usize = 1;
pub const BYTE_ARRAY_CLASS: usize = 2;
pub const BYTE_ARRAY_COW_CLASS: usize = 3;
pub const BYTE_ARRAY_SLICE_CLASS: usize = 4;
pub const STRING_SLICE_CLASS: usize = 5;
pub const STRING_BYTE_SLICE_CLASS: usize = 6;
pub const LIST_CLASS: usize = 7;
pub const LIST_SLICE_CLASS: usize = 8;
pub const MAP_CLASS: usize = 9;
pub const TOMBSTONE_CLASS: usize = 10;
pub const STACK_CLASS: usize = 11;
pub const NULL_CLASS: usize = 12;
pub const TRUE_CLASS: usize = 13;
pub const FALSE_CLASS: usize = 14;
pub const OBJECT_CLASS: usize = 15;
pub const DOUBLE_CLASS: usize = 16;
pub const LARGE_INTEGER_CLASS: usize = 17;
pub const SMI_CLASS: usize = 18;
pub const TASK_CLASS: usize = 19;
pub const LARGE_ARRAY_CLASS: usize = 20;
pub const LAZY_INITIALIZER_CLASS: usize = 21;
pub const EXCEPTION_CLASS: usize = 22;

// Entry points (entry_points.h).
pub const ENTRY_MAIN: usize = 0;
pub const ENTRY_TASK: usize = 2;
pub const LOOKUP_FAILURE: usize = 3;
pub const AS_CHECK_FAILURE: usize = 4;
pub const PRIMITIVE_LOOKUP_FAILURE: usize = 5;
pub const CODE_FAILURE: usize = 6;
pub const PROGRAM_FAILURE: usize = 7;
pub const RUN_GLOBAL_INITIALIZER: usize = 8;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Halt {
    Yield,
    Exit(i64),
    DeepSleep,
    Reset,
    /// Format 2: an exception unwound past the bottom frame.
    Uncaught(Value),
    /// Format 2: the bottom frame returned.
    TaskReturned,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Step {
    Next,
    Primitive(u8, u16),
    Halt(Halt),
}

impl std::fmt::Debug for Value {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Value::Smi(v) => write!(f, "{}", v),
            Value::Obj(id) => write!(f, "@{}", id),
            Value::RetAddr(b) => write!(f, "ret:{}", b),
            Value::FrameMarker => write!(f, "FM"),
            Value::Block(h) => write!(f, "block:{}", h),
            Value::Link(h) => write!(f, "link:{}", h),
            Value::BlockRef(fr, slot) => write!(f, "block:{}/{}", fr, slot),
            Value::Token(second, d, fr, h) => {
                let d = match d {
                    Pending::Normal => "normal".to_string(),
                    Pending::Throw => "throw".to_string(),
                    Pending::Return(t) => format!("return:{}", t),
                    Pending::Branch(t, b, th) => format!("branch:{}/{}/{}", t, b, th),
                };
                write!(f, "token{}:{}@{}/{}", if *second { 2 } else { 1 }, d, fr, h)
            }
        }
    }
}

impl std::fmt::Debug for Stuck {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            Stuck::BadInstruction => "BadInstruction",
            Stuck::StackRange => "StackRange",
            Stuck::FrameWord => "FrameWord",
            Stuck::BadFrame => "BadFrame",
            Stuck::NotSmi => "NotSmi",
            Stuck::NotObject => "NotObject",
            Stuck::NotInstance => "NotInstance",
            Stuck::NotArray => "NotArray",
            Stuck::NotBlock => "NotBlock",
            Stuck::NotLink => "NotLink",
            Stuck::FieldRange => "FieldRange",
            Stuck::TableRange => "TableRange",
            Stuck::NotMethod => "NotMethod",
            Stuck::BadBranch => "BadBranch",
            Stuck::ReadOnly => "ReadOnly",
            Stuck::NotInstantiable => "NotInstantiable",
            Stuck::Fatal => "Fatal",
            Stuck::SmiRange => "SmiRange",
            Stuck::OutOfFuel => "OutOfFuel",
            Stuck::BadArity => "BadArity",
            Stuck::NotUnwind => "NotUnwind",
        };
        f.write_str(s)
    }
}

/// How a run ended.
#[derive(Debug)]
pub enum End {
    Exit(i64),
    DeepSleep,
    Reset,
    /// The machine reached a stuck state.
    Stuck(Stuck, String),
    /// A primitive the reference interpreter does not implement (the
    /// oracle has no answer).
    Unimplemented(String),
    /// All tasks are blocked and nothing can wake them.
    Deadlock,
    /// Format 2: an uncaught exception (the format-1 entry code catches all
    /// exceptions, so this means the program is broken).
    Uncaught(String),
    /// Format 2: a task's bottom frame returned.
    TaskReturned,
    StepLimit,
}

pub struct Machine {
    /// Bytecode format: 1 (the VM's) or 2 (the revised format, `v2`).
    pub format: u8,
    pub p: ExecProgram,
    pub s: ExecState,
    pub names: loader::Names,
    pub world: system::World,
    pub steps: u64,
    pub verified_steps: u64,
    pub trace: bool,
    /// Print every THROW with the thrown value and a backtrace.
    pub trace_throw: bool,
    /// Print the absolute bci of every step (for comparison with the debug
    /// VM's `-Xtrace` output).
    pub trace_bci: bool,
    /// Executions per opcode (for `--histogram`).
    pub histogram: Vec<u64>,
    /// Use the verified `exec_step` for the opcodes it covers.
    pub use_verified: bool,
}

impl Machine {
    /// Builds the initial state (`spec_prim::initial_state`).
    pub fn new(loaded: loader::Loaded, args: Vec<String>) -> Machine {
        if loaded.format == 2 {
            return Machine::new2(loaded, args);
        }
        let loader::Loaded { program, mut heap, globals, names, .. } = loaded;
        // `exec_step::wf_program`, the precondition of the verified step.
        assert!(program.word_bits == 32 || program.word_bits == 64);
        assert!(program.method_start.len() == program.bytecodes.len());
        assert!(program.bytecodes.len() < 0x1000_0000 && program.dispatch.len() < 0x1000_0000);
        assert!(program.roots.len() == 35 && program.invoke_offsets.len() == 19);
        assert!(program.builtin.len() == 23 && program.entry_points.len() == 9);
        let stack_id = heap.len();
        heap.push(ExecObj { class_id: program.builtin[STACK_CLASS], ro: false, body: ExecBody::Stack(Vec::new(), 0) });
        let task_class = program.builtin[TASK_CLASS] as usize;
        let field_count = ((program.class_bits[task_class] >> 5) & 0x7ff) as usize - 1;
        let null = program.roots[0];
        let mut fields = vec![null; field_count];
        fields[0] = Value::Obj(stack_id);
        fields[1] = Value::Smi(0);
        heap.push(ExecObj { class_id: task_class as u16, ro: false, body: ExecBody::Instance(fields) });
        let task = stack_id + 1;
        let mut m = Machine {
            p: program,
            s: ExecState { heap, globals, stack: Vec::new(), try_h: 0, bci: 0, task, next_task_id: 1,
                frames: Vec::new() },
            format: 1,
            names,
            world: system::World::new(args),
            steps: 0,
            verified_steps: 0,
            trace: false,
            trace_throw: false,
            trace_bci: false,
            histogram: vec![0; 256],
            use_verified: true,
        };
        let entry = m.entry_method(ENTRY_MAIN);
        assert!(m.valid_method(entry), "no entry point");
        let entry = entry as usize + 4;
        m.s.stack = vec![Value::Obj(task), Value::RetAddr(entry), Value::FrameMarker];
        m.s.bci = entry;
        m
    }

    /// One step of the running task.
    pub fn step(&mut self) -> Result<Step, Stuck> {
        if self.format == 2 {
            if self.use_verified {
                if let Some(mut r) = crate::v2::exec::step_verified(&self.p, &mut self.s) {
                    self.verified_steps += 1;
                    if let crate::v2::exec::ExecOutcome2::Raise(v) = r {
                        // The reference completion of a raise: no trace.
                        if self.trace_throw {
                            eprintln!("[spec] raise {} at\n  {}", self.describe(v), self.backtrace());
                        }
                        r = crate::v2::exec::x_throw_null(&self.p, &mut self.s, v);
                    }
                    return match r {
                        crate::v2::exec::ExecOutcome2::Next => Ok(Step::Next),
                        crate::v2::exec::ExecOutcome2::Stuck(s) => Err(s),
                        crate::v2::exec::ExecOutcome2::Uncaught(v) => Ok(Step::Halt(Halt::Uncaught(v))),
                        crate::v2::exec::ExecOutcome2::TaskReturned => Ok(Step::Halt(Halt::TaskReturned)),
                        crate::v2::exec::ExecOutcome2::Raise(_) => Err(Stuck::Fatal),
                    };
                }
            }
            return self.step2_unverified();
        }
        if self.use_verified {
            if let Some(r) = crate::exec_step::step_verified(&self.p, &mut self.s) {
                self.verified_steps += 1;
                return match r {
                    crate::exec_step::ExecOutcome::Next => Ok(Step::Next),
                    crate::exec_step::ExecOutcome::Stuck(s) => Err(s),
                };
            }
        }
        self.step_unverified()
    }

    pub fn location(&self, bci: usize) -> String {
        match self.names.method_at(bci) {
            Some((_, entry, name)) => format!("{}+{} (bci {})", name, bci as i64 - entry as i64, bci),
            None => format!("bci {}", bci),
        }
    }

    /// A rough stack trace from the return addresses on the stack.
    pub fn backtrace(&self) -> String {
        let mut out = vec![self.location(self.s.bci)];
        if self.format == 2 {
            for f in self.s.frames.iter().rev() {
                out.push(self.location(f.ret));
            }
            return out.join("\n  ");
        }
        for v in self.s.stack.iter().rev() {
            if let Value::RetAddr(r) = v {
                out.push(self.location(*r));
            }
        }
        out.join("\n  ")
    }

    /// A short description of a value for diagnostics.
    pub fn describe(&self, v: Value) -> String {
        match v {
            Value::Obj(id) if id < self.s.heap.len() => {
                let o = &self.s.heap[id];
                let class = self.names.class_name(o.class_id as usize);
                match &o.body {
                    ExecBody::Str(b) => format!("\"{}\"", String::from_utf8_lossy(b)),
                    ExecBody::Instance(f) => {
                        let fs: Vec<String> = f.iter().take(4).map(|x| match x {
                            Value::Obj(i) if *i < self.s.heap.len() => match &self.s.heap[*i].body {
                                ExecBody::Str(b) => format!("\"{}\"", String::from_utf8_lossy(b)),
                                _ => format!("{:?}", x),
                            },
                            _ => format!("{:?}", x),
                        }).collect();
                        format!("{}({})", class, fs.join(", "))
                    }
                    _ => format!("{}@{}", class, id),
                }
            }
            _ => format!("{:?}", v),
        }
    }

    pub fn run(&mut self, max_steps: u64) -> End {
        loop {
            if self.steps >= max_steps {
                return End::StepLimit;
            }
            self.steps += 1;
            if self.trace {
                let op = self.p.bytecodes.get(self.s.bci).copied().unwrap_or(255);
                let name = if self.format == 2 {
                    crate::v2::bytecodes::OPCODE_NAMES2.get(op as usize).copied().unwrap_or("?")
                } else {
                    crate::bytecodes::OPCODE_NAMES.get(op as usize).copied().unwrap_or("?")
                };
                eprintln!("[{}] {} {} sp={} top={:?}", self.steps, self.location(self.s.bci), name,
                    self.s.stack.len(), self.s.stack.last());
            }
            if let Some(&op) = self.p.bytecodes.get(self.s.bci) {
                self.histogram[op as usize] += 1;
            }
            if self.trace_bci {
                eprintln!("B {} {}", self.s.bci, self.p.bytecodes.get(self.s.bci).copied().unwrap_or(255));
            }
            if self.trace_throw && self.p.bytecodes.get(self.s.bci) == Some(&crate::bytecodes::THROW)
                    && (self.format == 1 || self.s.frames.last().map(|f| self.p.methods[f.method].end > self.s.bci).unwrap_or(false)) {
                let v = self.s.stack.last().copied();
                eprintln!("[spec] throw {} at\n  {}", v.map(|v| self.describe(v)).unwrap_or_default(), self.backtrace());
            }
            match self.step() {
                Ok(Step::Next) => {}
                Ok(Step::Primitive(module, index)) => {
                    if let Err(end) = prims::call(self, module, index) {
                        return end;
                    }
                }
                Ok(Step::Halt(Halt::Yield)) => {
                    if let Err(end) = system::on_yield(self) {
                        return end;
                    }
                }
                Ok(Step::Halt(Halt::Exit(v))) => return End::Exit(v),
                Ok(Step::Halt(Halt::DeepSleep)) => return End::DeepSleep,
                Ok(Step::Halt(Halt::Reset)) => return End::Reset,
                Ok(Step::Halt(Halt::Uncaught(v))) => return End::Uncaught(self.describe(v)),
                Ok(Step::Halt(Halt::TaskReturned)) => return End::TaskReturned,
                Err(stuck) => return End::Stuck(stuck, self.backtrace()),
            }
        }
    }
}
