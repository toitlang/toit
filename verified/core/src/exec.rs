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

//! The machine state and the verified opcode handlers.

use vstd::prelude::*;
use crate::layout::*;
use crate::ffi::V2Method;
use crate::view::*;

verus! {

/// The program tables (read only) and values derived from them at entry.
pub struct Program {
    pub code: Table<u8>,
    pub methods: Table<V2Method>,
    pub dispatch: Table<i32>,
    pub class_bits: Table<u16>,
    pub class_check_ids: Table<u16>,
    pub interface_check_offsets: Table<u16>,
    pub invoke_offsets: Table<i32>,
    pub entry_points: Table<i32>,
    pub builtin: Table<usize>,
    pub roots: Table<usize>,
    pub literals: Table<usize>,
    pub ro_start: usize,
    pub ro_size: usize,
    pub max_height: usize,
    pub preempt_a_lot: bool,
    pub null: usize,
    pub true_: usize,
    pub false_: usize,
    pub smi_class_id: i64,
    pub list_class_id: i64,
    pub byte_array_slice_class_id: i64,
    pub byte_array_cow_class_id: i64,
    pub large_array_class_id: i64,
    pub lazy_initializer_class_id: i64,
}

/// The state of the running task. The object stack is `mem[top..len]`
/// (spec index `i` at array index `len - 1 - i`), the frame records are
/// `mem[0..ftop]`. `base`, `lim`, `method` and `mend` cache the top frame:
/// its base, `len - base` (slot `n` exists iff `top + n < lim`), its method
/// and the end of its body.
pub struct Machine {
    pub mem: StackMem,
    pub globals: Globals,
    pub heap: Heap,
    pub len: usize,
    pub top: usize,
    pub ftop: usize,
    pub bci: usize,
    pub base: usize,
    pub lim: usize,
    pub method: usize,
    pub mend: usize,
    /// `mend - MAX_INSTRUCTION_LENGTH` (saturating): an instruction starting
    /// below it ends inside the method, whatever its opcode.
    pub mfast: usize,
}

/// How the run loop continues after a step.
pub enum Ctl {
    /// Next instruction (at `bci`).
    Next,
    /// Leave the run loop with an `Interpreter::Result` state and value.
    /// (The state is a u32 so that `Ctl` fits in two registers.)
    Exit(u32, i64),
    /// A stuck state of the spec (or an implementation limit): the process
    /// is terminated.
    Stuck(usize),
}

pub open spec fn smi_word(v: int) -> usize {
    (v * 2) as usize
}

impl Machine {
    /// The words of the object stack, bottom first.
    pub open spec fn words(&self) -> Seq<usize> {
        Seq::new((self.len - self.top) as nat, |i: int| self.mem@[self.len - 1 - i])
    }

    pub open spec fn stack_ok(&self) -> bool {
        &&& self.len == self.mem@.len()
        &&& self.ftop <= self.top <= self.len
        &&& self.base <= self.len
        &&& self.lim == self.len - self.base
    }

    #[inline(always)]
    pub fn has_slot(&self, n: usize) -> (r: bool)
        requires self.stack_ok(),
        ensures r == (self.top + n < self.lim),
    {
        n < self.lim - self.top
    }

    /// `STACK_AT(n)`.
    #[inline(always)]
    pub fn at(&self, n: usize) -> (r: usize)
        requires self.stack_ok(), self.top + n < self.lim,
        ensures r == self.mem@[self.top + n],
    {
        self.mem.read(self.top + n)
    }

    #[inline(always)]
    pub fn put(&mut self, n: usize, v: usize)
        requires old(self).stack_ok(), old(self).top + n < old(self).lim,
        ensures
            final(self).stack_ok(),
            final(self).mem@ == old(self).mem@.update(old(self).top + n, v),
            final(self).top == old(self).top,
            final(self).ftop == old(self).ftop,
            final(self).len == old(self).len,
            final(self).base == old(self).base,
            final(self).bci == old(self).bci,
    {
        let i = self.top + n;
        self.mem.write(i, v);
    }

    /// Pushes `v`; false (and no change) if the object stack would run into
    /// the frame records.
    #[inline(always)]
    pub fn push(&mut self, v: usize) -> (r: bool)
        requires old(self).stack_ok(),
        ensures
            final(self).stack_ok(),
            r == (old(self).top > old(self).ftop),
            r ==> final(self).top == old(self).top - 1
                && final(self).mem@ == old(self).mem@.update(old(self).top - 1, v),
            !r ==> final(self).mem@ == old(self).mem@ && final(self).top == old(self).top,
            final(self).ftop == old(self).ftop,
            final(self).len == old(self).len,
            final(self).base == old(self).base,
            final(self).bci == old(self).bci,
    {
        if self.top <= self.ftop {
            return false;
        }
        self.top = self.top - 1;
        let t = self.top;
        self.mem.write(t, v);
        true
    }

    #[inline(always)]
    pub fn drop(&mut self, n: usize)
        requires old(self).stack_ok(), old(self).top + n <= old(self).lim,
        ensures
            final(self).stack_ok(),
            final(self).top == old(self).top + n,
            final(self).mem@ == old(self).mem@,
            final(self).ftop == old(self).ftop,
            final(self).len == old(self).len,
            final(self).base == old(self).base,
            final(self).bci == old(self).bci,
    {
        self.top = self.top + n;
    }

    /// Pushes `v` and continues after an instruction of length `len`.
    #[inline(always)]
    pub fn push_next(&mut self, v: usize, len: usize) -> (r: Ctl)
        requires old(self).stack_ok(), old(self).bci + len < usize::MAX,
    {
        if !self.push(v) {
            return Ctl::Stuck(100);
        }
        self.bci = self.bci + len;
        Ctl::Next
    }

    /// Replaces the two operands by `v` (`binary_result`).
    #[inline(always)]
    pub fn binary_result(&mut self, v: usize) -> (r: Ctl)
        requires
            old(self).stack_ok(), old(self).top + 1 < old(self).lim,
            old(self).bci + 1 < usize::MAX,
    {
        self.put(1, v);
        self.drop(1);
        self.bci = self.bci + 1;
        Ctl::Next
    }

    // --- Locals ---------------------------------------------------------

    #[inline(always)]
    pub fn op_load_local(&mut self, n: usize, len: usize) -> (r: Ctl)
        requires old(self).stack_ok(), old(self).bci + len < usize::MAX,
    {
        if !self.has_slot(n) {
            return Ctl::Stuck(1);
        }
        let v = self.at(n);
        self.push_next(v, len)
    }

    #[inline(always)]
    pub fn op_pop_load_local(&mut self, n: usize) -> (r: Ctl)
        requires old(self).stack_ok(), old(self).bci + 2 < usize::MAX, n < 256,
    {
        if !self.has_slot(n + 1) {
            return Ctl::Stuck(1);
        }
        let v = self.at(n + 1);
        self.put(0, v);
        self.bci = self.bci + 2;
        Ctl::Next
    }

    #[inline(always)]
    pub fn op_store_local(&mut self, n: usize) -> (r: Ctl)
        requires old(self).stack_ok(), old(self).bci + 2 < usize::MAX,
    {
        if !self.has_slot(n) {
            return Ctl::Stuck(1);
        }
        let v = self.at(0);
        self.put(n, v);
        self.bci = self.bci + 2;
        Ctl::Next
    }

    #[inline(always)]
    pub fn op_store_local_pop(&mut self, n: usize) -> (r: Ctl)
        requires old(self).stack_ok(), old(self).bci + 2 < usize::MAX,
    {
        if n < 1 || !self.has_slot(n) {
            return Ctl::Stuck(1);
        }
        let v = self.at(0);
        self.drop(1);
        self.put(n - 1, v);
        self.bci = self.bci + 2;
        Ctl::Next
    }

    // --- Constants, globals, pops -------------------------------------------

    #[inline(always)]
    pub fn op_load_literal(&mut self, p: &Program, i: usize, len: usize) -> (r: Ctl)
        requires old(self).stack_ok(), old(self).bci + len < usize::MAX,
    {
        if i >= p.literals.len() {
            return Ctl::Stuck(12);
        }
        let v = p.literals.at(i);
        self.push_next(v, len)
    }

    #[inline(always)]
    pub fn op_load_smis_0(&mut self, n: usize) -> (r: Ctl)
        requires old(self).stack_ok(), old(self).bci + 2 < usize::MAX,
    {
        if self.top - self.ftop < n {
            return Ctl::Stuck(100);
        }
        let mut i: usize = 0;
        while i < n
            invariant
                self.stack_ok(),
                i <= n,
                self.top - self.ftop >= n - i,
            decreases n - i,
        {
            let ok = self.push(0);
            i = i + 1;
        }
        self.bci = self.bci + 2;
        Ctl::Next
    }

    #[inline(always)]
    pub fn op_load_global(&mut self, g: usize, len: usize) -> (r: Ctl)
        requires old(self).stack_ok(), old(self).bci + len < usize::MAX,
    {
        if g >= self.globals.len() {
            return Ctl::Stuck(12);
        }
        let v = self.globals.at(g);
        self.push_next(v, len)
    }

    #[inline(always)]
    pub fn op_store_global(&mut self, g: usize, len: usize) -> (r: Ctl)
        requires old(self).stack_ok(), old(self).bci + len < usize::MAX,
    {
        if g >= self.globals.len() {
            return Ctl::Stuck(12);
        }
        if !self.has_slot(0) {
            return Ctl::Stuck(1);
        }
        let v = self.at(0);
        self.globals.set(g, v);
        self.bci = self.bci + len;
        Ctl::Next
    }

    #[inline(always)]
    pub fn op_pop(&mut self, n: usize, len: usize) -> (r: Ctl)
        requires old(self).stack_ok(), old(self).bci + len < usize::MAX,
    {
        if n > self.lim - self.top {
            return Ctl::Stuck(1);
        }
        self.drop(n);
        self.bci = self.bci + len;
        Ctl::Next
    }

    // --- Branches -----------------------------------------------------------

    /// kind: 0 always, 1 if true, 2 if false, 3 if not null.
    #[inline(always)]
    pub fn op_branch(&mut self, p: &Program, kind: usize, target: usize, len: usize) -> (r: Ctl)
        requires old(self).stack_ok(), old(self).bci + len < usize::MAX,
    {
        if kind != 0 {
            if !self.has_slot(0) {
                return Ctl::Stuck(1);
            }
            let v = self.at(0);
            self.drop(1);
            let taken = if kind == 1 {
                v != p.false_ && v != p.null
            } else if kind == 2 {
                !(v != p.false_ && v != p.null)
            } else {
                v != p.null
            };
            if !taken {
                self.bci = self.bci + len;
                return Ctl::Next;
            }
        }
        if self.method >= p.methods.len() {
            return Ctl::Stuck(14);
        }
        let m = p.methods.at(self.method);
        if !((m.entry as usize) <= target && target < (m.end as usize)) {
            return Ctl::Stuck(14);
        }
        self.bci = target;
        Ctl::Next
    }

    // --- Blocks ---------------------------------------------------------------

    #[inline(always)]
    pub fn op_load_block(&mut self, k: usize) -> (r: Ctl)
        requires old(self).stack_ok(), old(self).bci + 2 < usize::MAX,
    {
        if !self.has_slot(k) || self.ftop < FRAME_WORDS {
            return Ctl::Stuck(1);
        }
        let height = self.len - self.top;
        let slot = height - 1 - k;
        let f = self.ftop / FRAME_WORDS - 1;
        if f >= (1usize << 40) {
            return Ctl::Stuck(100);
        }
        let v = smi_word_exec(((f << BLOCK_SLOT_BITS) | slot) as i64);
        self.push_next(v, 2)
    }

    // --- Fields -------------------------------------------------------------

    #[inline(always)]
    pub fn op_load_field_this(&mut self, p: &Program, f: usize) -> (r: Ctl)
        requires old(self).stack_ok(), old(self).bci + 2 < usize::MAX,
    {
        // The receiver range of the method guarantees the field (checked by
        // the loader); the run-time check below makes the access safe for
        // every program.
        if self.base >= self.len - self.top || self.method >= p.methods.len() {
            return Ctl::Stuck(8);
        }
        let this = self.mem.read(self.len - 1 - self.base);
        if !self.field_ok(p, this, f) {
            return Ctl::Stuck(8);
        }
        let v = self.field(this, f);
        self.push_next(v, 2)
    }
}

#[inline(always)]
pub fn smi_word_exec(v: i64) -> (r: usize)
{
    (v as usize) << 1
}

} // verus!

impl Machine {
    #[inline(always)]
    pub fn op_load_outer(&mut self, k: usize) -> Ctl {
        if !self.has_slot(0) { return Ctl::Stuck(1); }
        let (f, slot) = match self.block_ref(self.at(0)) {
            None => return Ctl::Stuck(9),
            Some(r) => r,
        };
        let fbase = self.mem.read(f * FRAME_WORDS + FRAME_BASE);
        if slot < k || slot - k < fbase { return Ctl::Stuck(1); }
        let v = self.slot(slot - k);
        self.put(0, v);
        self.bci += 2;
        Ctl::Next
    }

    #[inline(always)]
    pub fn op_store_outer(&mut self, k: usize) -> Ctl {
        if !self.has_slot(1) { return Ctl::Stuck(1); }
        let v = self.at(0);
        let (f, slot) = match self.block_ref(self.at(1)) {
            None => return Ctl::Stuck(9),
            Some(r) => r,
        };
        let fbase = self.mem.read(f * FRAME_WORDS + FRAME_BASE);
        if slot < k || slot - k < fbase { return Ctl::Stuck(1); }
        let i = slot - k;
        self.drop(2);
        if i >= self.len - self.top { return Ctl::Stuck(1); }
        let index = self.len - 1 - i;
        self.mem.write(index, v);
        if !self.push(v) { return Ctl::Stuck(100); }
        self.bci += 2;
        Ctl::Next
    }

    #[inline(always)]
    pub fn op_load_outer_block(&mut self, k: usize) -> Ctl {
        if !self.has_slot(0) { return Ctl::Stuck(1); }
        let (f, slot) = match self.block_ref(self.at(0)) {
            None => return Ctl::Stuck(9),
            Some(r) => r,
        };
        let fbase = self.mem.read(f * FRAME_WORDS + FRAME_BASE);
        if slot < k || slot - k < fbase { return Ctl::Stuck(1); }
        self.put(0, Machine::block_value(f, slot - k));
        self.bci += 2;
        Ctl::Next
    }

    #[inline(always)]
    pub fn op_load_field(&mut self, env: &crate::machine::Env, f: usize, len: usize) -> Ctl {
        if !self.has_slot(0) { return Ctl::Stuck(1); }
        let obj = self.at(0);
        if !self.field_ok(env.p, obj, f) {
            return self.raise(env, crate::machine::INVALID_PROGRAM);
        }
        let v = self.field(obj, f);
        self.put(0, v);
        self.bci += len;
        Ctl::Next
    }

    #[inline(always)]
    pub fn op_load_field_local(&mut self, env: &crate::machine::Env, enc: usize, pop: bool) -> Ctl {
        let local = enc % 16;
        let f = enc / 16;
        let slot = if pop { local + 1 } else { local };
        if !self.has_slot(slot) { return Ctl::Stuck(1); }
        let obj = self.at(slot);
        if !self.field_ok(env.p, obj, f) {
            return self.raise(env, crate::machine::INVALID_PROGRAM);
        }
        let v = self.field(obj, f);
        if pop {
            self.put(0, v);
            self.bci += 2;
            Ctl::Next
        } else {
            self.push_next(v, 2)
        }
    }

    #[inline(always)]
    pub fn op_store_field(&mut self, env: &crate::machine::Env, f: usize, len: usize, keep: bool) -> Ctl {
        if !self.has_slot(1) { return Ctl::Stuck(1); }
        let v = self.at(0);
        let obj = self.at(1);
        if !self.field_ok(env.p, obj, f) || self.is_ro(env.p, obj) {
            return self.raise(env, crate::machine::INVALID_PROGRAM);
        }
        self.drop(2);
        self.heap.set_word(obj, INSTANCE_FIELDS_WORD + f, v);
        if keep {
            self.push_next(v, len)
        } else {
            self.bci += len;
            Ctl::Next
        }
    }

    #[inline(always)]
    pub fn op_store_field_this(&mut self, env: &crate::machine::Env, f: usize) -> Ctl {
        let p = env.p;
        if !self.has_slot(0) { return Ctl::Stuck(1); }
        if self.base >= self.len - self.top { return Ctl::Stuck(8); }
        let this = self.mem.read(self.len - 1 - self.base);
        if !self.field_ok(p, this, f) { return Ctl::Stuck(8); }
        if self.is_ro(p, this) {
            return self.raise(env, crate::machine::INVALID_PROGRAM);
        }
        let v = self.at(0);
        self.heap.set_word(this, INSTANCE_FIELDS_WORD + f, v);
        self.bci += 2;
        Ctl::Next
    }
}

impl Program {
    /// `instance_field_count`: the instance size in words minus the header.
    #[inline(always)]
    pub fn instance_field_count(&self, cid: usize) -> i64 {
        (((self.class_bits.at(cid) >> CLASS_ID_OFFSET) & INSTANCE_SIZE_MASK) as i64) - 1
    }

    /// `dispatch_target`.
    #[inline(always)]
    pub fn dispatch_target(&self, d: usize) -> i64 {
        if d < self.dispatch.len() { self.dispatch.at(d) as i64 } else { -1 }
    }

    /// `entry_method`.
    #[inline(always)]
    pub fn entry_method(&self, k: usize) -> i64 {
        let d = self.entry_points.at(k);
        if d < 0 { return -1; }
        self.dispatch_target(d as usize)
    }

    #[inline(always)]
    pub fn boolean(&self, b: bool) -> usize {
        if b { self.true_ } else { self.false_ }
    }
}
