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

//! The machine state, its abstraction (`Machine::refines`) and the
//! verified opcode handlers of the families that only touch the top frame
//! (locals, constants, globals, pops, branches). Every handler is proven
//! to refine the spec function of the same name: when it continues, the
//! new ghost state is exactly the spec's next state. The run-time checks
//! the spec's stuck conditions would need are gone: the caller passes the
//! fact that the spec step is not stuck (from the soundness theorem of
//! the verifier, `step.rs`).

use vstd::prelude::*;
use crate::layout::*;
use crate::ffi::{V2Method, Runtime};
use crate::view::*;
use crate::abs::*;
use toit_spec::types::{Value, Frame, Handler, HeapObj};
use toit_spec::v2::types::{State2, Program2, Outcome2};
use toit_spec::v2::verifier::Cert;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, small};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::accepts;

verus! {

/// The program tables (read only) and values derived from them at entry.
/// `ap`, `cert` and `trusted` are ghost: the abstract program the tables
/// represent (`prog_rel`), the verifier's certificate and the verifier's
/// mode it was accepted in.
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
    pub ap: Ghost<Program2>,
    pub cert: Ghost<Cert>,
    pub trusted: Ghost<bool>,
}

/// The state of the running task. The object stack is `mem[top..len]`
/// (spec index `i` at array index `len - 1 - i`), the frame records are
/// `mem[0..ftop]`, the finally records `mem[ftop..rtop]` (`FIN_WORDS`
/// each). `base`, `lim` and `method` cache the top frame: its
/// base, `len - base` (slot `n` exists iff `top + n < lim`) and its
/// method. `g` is the abstract state the machine represents
/// (`refines`).
pub struct Machine {
    pub mem: StackMem,
    pub globals: Globals,
    pub heap: Heap,
    pub len: usize,
    pub top: usize,
    pub ftop: usize,
    pub rtop: usize,
    pub bci: usize,
    pub base: usize,
    pub lim: usize,
    pub method: usize,
    /// The run loop's gate for finally records (`regs::gate_ok`, set by
    /// `Machine::enter`): `fw` is the number of finally-record words while
    /// the registers run (the registers hold the frame top only); a call's
    /// fast path needs `need` free words (all ones while there are finally
    /// records, so that it fails), a return's fast path a frame top above
    /// `bot` (the end of the array while there are finally records).
    pub fw: usize,
    pub need: usize,
    pub bot: Slot,
    pub g: Ghost<State2>,
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

/// Reasons for a stuck state (`types::Stuck`), reported to stderr.
pub mod stuck {
    pub const BAD_INSTRUCTION: usize = 0;
    pub const STACK_RANGE: usize = 1;
    pub const BAD_FRAME: usize = 3;
    pub const NOT_OBJECT: usize = 6;
    pub const NOT_INSTANCE: usize = 8;
    pub const NOT_BLOCK: usize = 9;
    pub const TABLE_RANGE: usize = 12;
    pub const NOT_METHOD: usize = 13;
    pub const BAD_BRANCH: usize = 14;
    pub const NOT_INSTANTIABLE: usize = 16;
    pub const FATAL: usize = 17;
    pub const SMI_RANGE: usize = 18;
    pub const OUT_OF_FUEL: usize = 19;
    pub const BAD_ARITY: usize = 20;
    pub const NOT_UNWIND: usize = 21;
    /// Not a spec state: the implementation ran out of a resource it checks
    /// (room on the object stack, a smi or table encoding limit). The
    /// spec's memory bound `small` makes this the defined out-of-memory
    /// outcome (verified/spec/SOUNDNESS.md, hypothesis 3).
    pub const LIMIT: usize = 100;
}

pub open spec fn is_limit(r: Ctl) -> bool {
    r == Ctl::Stuck(stuck::LIMIT)
}

/// The environment of one run. It owns the program (not a reference): the
/// run loop takes `&Env`, which the compiler treats as not aliased by the
/// stack's raw pointers, so the table pointers stay in registers or stack
/// slots instead of being reloaded through `env.p` after every store.
pub struct Env {
    pub p: Program,
    pub rt: Runtime,
    pub pre: Preemption,
    /// The core primitives the process' policy resolves to the VM's own: entry
    /// `i` is the arity of core primitive `i` plus one, else 0
    /// (`PrimitivePolicy::core_arities`). The core runs the Rust port
    /// (`prims::call`) of such a primitive.
    pub core_arities: Table<u8>,
}

/// `Smi::from(v)`.
#[inline(always)]
pub fn smi_of(v: i64) -> (r: usize)
    requires smi_range(v as int),
    ensures r == smi_word(v),
{
    (v + v) as usize
}

/// `a` lies in the program heap.
pub open spec fn in_ro(p: &Program, a: usize) -> bool {
    p.ro_start <= a && a < p.ro_start + p.ro_size
}

impl Program {
    /// The abstract program.
    pub open spec fn ap(&self) -> Program2 {
        self.ap@
    }
}

impl Machine {
    /// The words of the object stack, bottom first.
    pub open spec fn words(&self) -> Seq<usize> {
        Seq::new((self.len - self.top) as nat, |i: int| self.mem@[self.len - 1 - i])
    }

    /// Height of the object stack.
    pub open spec fn height(&self) -> int {
        self.len - self.top
    }

    pub open spec fn stack_ok(&self) -> bool {
        &&& self.len == self.mem@.len()
        &&& self.ftop <= self.rtop <= self.top <= self.len
        &&& self.base <= self.len
        &&& self.lim == self.len - self.base
        // The top frame's slots exist (its base is at or below the top).
        &&& self.top <= self.lim
        // Block references encode slots in BLOCK_SLOT_BITS, and the Stack
        // header packs the record and frame tops (reload checks).
        &&& self.len < MAX_STACK_LENGTH
    }

    pub open spec fn addr(&self) -> Seq<usize> {
        self.heap.addrs()
    }

    /// The machine represents its ghost state `g` for program `p`.
    pub open spec fn refines(&self, p: &Program) -> bool {
        let g = self.g@;
        let addr = self.heap.addrs();
        &&& self.stack_ok()
        &&& heap_model_ok(self.heap.objs(), addr, self.heap.class_bits())
        &&& self.heap.class_bits() == p.class_bits@
        // The program heap (read only) is exactly the objects in the
        // program-heap address range.
        &&& forall|i: int| 0 <= i < g.heap.len() ==> #[trigger] g.heap[i].ro == in_ro(p, addr[i])
        &&& g.heap == self.heap.objs()
        &&& prog_rel(p, g.heap, addr)
        &&& self.words() == enc_seq(addr, g.stack)
        &&& forall|i: int| 0 <= i < g.stack.len() ==> #[trigger] encodable(addr, g.stack[i])
        &&& g.frames.len() > 0
        &&& self.ftop == FRAME_WORDS * g.frames.len()
        &&& frames_rel(self.mem@, g.frames, g.tries)
        // The finally records (format note 17) follow the frame records.
        &&& self.rtop == self.ftop + FIN_WORDS * g.fins.len()
        &&& fins_rel(self.mem@, self.ftop as int, g.fins)
        &&& self.bci == g.bci
        &&& self.globals@ == enc_seq(addr, g.globals)
        &&& forall|i: int| 0 <= i < g.globals.len() ==> #[trigger] encodable(addr, g.globals[i])
        &&& self.base == g.frames.last().base
        &&& self.method == g.frames.last().method
        &&& self.method < p.methods@.len()
    }

    /// The part of `refines` about the heap model, the globals and the
    /// program (no register field): what the helpers that look at values
    /// (class ids, fields, numbers) need. The machine `m.with(r)` of the
    /// run loop has it iff `m` has.
    pub open spec fn hrefines(&self, p: &Program) -> bool {
        let g = self.g@;
        let addr = self.heap.addrs();
        &&& heap_model_ok(self.heap.objs(), addr, self.heap.class_bits())
        &&& self.heap.class_bits() == p.class_bits@
        &&& forall|i: int| 0 <= i < g.heap.len() ==> #[trigger] g.heap[i].ro == in_ro(p, addr[i])
        &&& g.heap == self.heap.objs()
        &&& prog_rel(p, g.heap, addr)
        &&& self.globals@ == enc_seq(addr, g.globals)
        &&& forall|i: int| 0 <= i < g.globals.len() ==> #[trigger] encodable(addr, g.globals[i])
    }

    /// The invariant of the run loop: the machine refines a well-formed
    /// state of an accepted program (`wf`, the invariant of the verifier's
    /// soundness proof).
    pub open spec fn inv(&self, p: &Program) -> bool {
        &&& self.refines(p)
        &&& accepts(p.ap@, p.cert@, p.trusted@)
        &&& wf(p.ap@, p.cert@, self.g@)
    }

    /// `m` differs from `self` only in the object stack, the bci and the
    /// globals (words and ghost), and the ghost state only in the stack,
    /// the bci and the globals: a step inside the top frame.
    pub open spec fn local_step(&self, p: &Program, m: &Machine) -> bool {
        let g0 = self.g@;
        let g1 = m.g@;
        let addr = self.heap.addrs();
        &&& m.stack_ok()
        &&& m.len == self.len
        &&& m.ftop == self.ftop
        &&& m.rtop == self.rtop
        &&& m.base == self.base
        &&& m.lim == self.lim
        &&& m.method == self.method
        &&& m.heap.addrs() == addr
        &&& m.heap.objs() == self.heap.objs()
        &&& m.heap.class_bits() == self.heap.class_bits()
        &&& forall|i: int| 0 <= i < self.rtop ==> #[trigger] m.mem@[i] == self.mem@[i]
        &&& g1.heap == g0.heap
        &&& g1.frames == g0.frames
        &&& g1.tries == g0.tries
        &&& g1.fins == g0.fins
        &&& m.words() == enc_seq(addr, g1.stack)
        &&& forall|i: int| 0 <= i < g1.stack.len() ==> #[trigger] encodable(addr, g1.stack[i])
        &&& m.bci == g1.bci
        &&& m.globals@ == enc_seq(addr, g1.globals)
        &&& forall|i: int| 0 <= i < g1.globals.len() ==> #[trigger] encodable(addr, g1.globals[i])
    }

    pub proof fn lemma_local_step(&self, p: &Program, m: &Machine)
        requires self.refines(p), self.local_step(p, m),
        ensures m.refines(p),
    {
        let g0 = self.g@;
        let g1 = m.g@;
        lemma_frames_rel_same(self.mem@, m.mem@, g0.frames, g0.tries);
        lemma_fins_rel_same(self.mem@, m.mem@, self.ftop as int, g0.fins);
    }

    /// Root `i` is a constant and its word is the table's.
    pub proof fn lemma_root(&self, p: &Program, i: int)
        requires self.refines(p), 0 <= i < p.ap@.roots.len(),
        ensures
            p.roots@[i] == enc(self.addr(), p.ap@.roots[i]),
            const_ok(self.g@.heap, p.ap@.roots[i]),
            encodable(self.addr(), p.ap@.roots[i]),
    {
        assert(p.roots@[i] == enc(self.addr(), p.ap@.roots[i]) && const_ok(self.g@.heap, p.ap@.roots[i]));
    }

    /// The top frame's height is `lim - top`.
    pub proof fn lemma_frame(&self, p: &Program)
        requires self.refines(p),
        ensures
            self.g@.stack.len() == self.height(),
            sp::frame_height(self.g@) == self.lim - self.top,
            sp::base(self.g@) == self.base,
    {
        assert(self.words().len() == enc_seq(self.addr(), self.g@.stack).len());
    }

    /// Slot `n` (from the top) of the top frame, as a word: the encoding of
    /// the abstract slot.
    pub proof fn lemma_at(&self, p: &Program, n: int)
        requires self.refines(p), sp::has_slot(self.g@, n),
        ensures
            self.top + n < self.lim,
            self.top + n < self.len,
            self.mem@[self.top + n] == enc(self.addr(), sp::at(self.g@, n)),
            encodable(self.addr(), sp::at(self.g@, n)),
    {
        let g = self.g@;
        assert(self.words().len() == enc_seq(self.addr(), g.stack).len());
        assert(g.stack.len() == self.height());
        assert(self.top + n < self.lim);
        let j = self.height() - 1 - n;
        assert(self.words()[j] == self.mem@[self.len - 1 - j]);
        assert(enc_seq(self.addr(), g.stack)[j] == enc(self.addr(), g.stack[j]));
    }

    // --- Stack helpers --------------------------------------------------------

    /// `STACK_AT(n)`.
    #[inline(always)]
    pub fn at(&self, n: usize) -> (r: usize)
        requires self.stack_ok(), self.top + n < self.lim,
        ensures
            r == self.mem@[self.top + n],
            r == self.words()[self.height() - 1 - n],
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
            final(self).bci == old(self).bci,
            final(self).same(old(self)),
            final(self).words() == old(self).words().update(old(self).height() - 1 - n, v),
    {
        let i = self.top + n;
        self.mem.write(i, v);
        assert(self.words() =~= old(self).words().update(old(self).height() - 1 - n, v));
    }

    /// Everything but the stack memory, top and bci is unchanged.
    pub open spec fn same(&self, other: &Machine) -> bool {
        &&& self.len == other.len
        &&& self.ftop == other.ftop
        &&& self.rtop == other.rtop
        &&& self.base == other.base
        &&& self.lim == other.lim
        &&& self.method == other.method
        &&& self.globals@ == other.globals@
        &&& self.heap.addrs() == other.heap.addrs()
        &&& self.heap.objs() == other.heap.objs()
        &&& self.heap.class_bits() == other.heap.class_bits()
        &&& self.g == other.g
        &&& self.mem@.len() == other.mem@.len()
        // The frame and finally records (below rtop) are unchanged.
        &&& forall|i: int| 0 <= i < self.rtop ==> #[trigger] self.mem@[i] == other.mem@[i]
    }

    /// Pushes `v`; false (and no change) if the object stack would run into
    /// the frame and finally records.
    #[inline(always)]
    pub fn push(&mut self, v: usize) -> (r: bool)
        requires old(self).stack_ok(),
        ensures
            final(self).stack_ok(),
            r == (old(self).top > old(self).rtop),
            r ==> final(self).top == old(self).top - 1
                && final(self).mem@ == old(self).mem@.update(old(self).top - 1, v),
            !r ==> final(self).mem@ == old(self).mem@ && final(self).top == old(self).top,
            final(self).bci == old(self).bci,
            final(self).same(old(self)),
            r ==> final(self).words() == old(self).words().push(v),
            !r ==> final(self).words() == old(self).words(),
    {
        if self.top <= self.rtop {
            return false;
        }
        self.top = self.top - 1;
        let t = self.top;
        self.mem.write(t, v);
        assert(self.words() =~= old(self).words().push(v));
        true
    }

    #[inline(always)]
    pub fn drop(&mut self, n: usize)
        requires old(self).stack_ok(), old(self).top + n <= old(self).lim,
        ensures
            final(self).stack_ok(),
            final(self).top == old(self).top + n,
            final(self).mem@ == old(self).mem@,
            final(self).bci == old(self).bci,
            final(self).same(old(self)),
            final(self).words() == old(self).words().subrange(0, old(self).height() - n),
    {
        self.top = self.top + n;
        assert(self.words() =~= old(self).words().subrange(0, old(self).height() - n));
    }

    // --- Refinement of the simple handlers -------------------------------------

    /// Pushes the encoding of `v` (`spec::push`); false (and no change) for
    /// lack of room.
    #[inline(always)]
    pub fn push_val(&mut self, p: &Program, w: usize, Ghost(v): Ghost<Value>) -> (r: bool)
        requires
            old(self).refines(p),
            w == enc(old(self).addr(), v),
            encodable(old(self).addr(), v),
        ensures
            r ==> final(self).refines(p) && final(self).g@ == sp::push(old(self).g@, v),
            r ==> final(self).top == old(self).top - 1 && final(self).addr() == old(self).addr(),
            !r ==> *final(self) == *old(self),
            final(self).bci == old(self).bci,
            final(self).ftop == old(self).ftop,
            final(self).rtop == old(self).rtop,
            final(self).base == old(self).base,
            final(self).method == old(self).method,
    {
        let ghost m0 = *self;
        if self.top <= self.rtop {
            return false;
        }
        self.push(w);
        let ghost g1 = sp::push(m0.g@, v);
        self.g = Ghost(g1);
        proof {
            assert(self.words() =~= enc_seq(m0.addr(), g1.stack));
            assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
                if i < m0.g@.stack.len() { assert(g1.stack[i] == m0.g@.stack[i]); }
            }
            m0.lemma_local_step(p, self);
        }
        true
    }

    /// Pushes the encoding of `v` and continues at `bci + len`: refines
    /// `next(push(g, v), len)`. Fails only for lack of room.
    #[inline(always)]
    pub fn push_next(&mut self, p: &Program, w: usize, len: usize, Ghost(v): Ghost<Value>) -> (r: Ctl)
        requires
            old(self).refines(p),
            w == enc(old(self).addr(), v),
            encodable(old(self).addr(), v),
            old(self).bci + len < 0x1000_0000,
        ensures
            r == Ctl::Next || is_limit(r),
            r == Ctl::Next ==> final(self).refines(p)
                && final(self).g@ == sp::goto(sp::push(old(self).g@, v), old(self).bci + len),
    {
        let ghost m0 = *self;
        if !self.push(w) {
            return Ctl::Stuck(stuck::LIMIT);
        }
        self.bci = self.bci + len;
        let ghost g1 = sp::goto(sp::push(m0.g@, v), m0.bci + len);
        self.g = Ghost(g1);
        proof {
            assert(self.words() =~= enc_seq(m0.addr(), g1.stack));
            assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
                if i < m0.g@.stack.len() { assert(g1.stack[i] == m0.g@.stack[i]); }
            }
            m0.lemma_local_step(p, self);
        }
        Ctl::Next
    }

    /// LOAD_LOCAL, LOAD_LOCAL_WIDE, LOAD_LOCAL_0..5.
    #[inline(always)]
    pub fn op_load_local(&mut self, p: &Program, n: usize, len: usize) -> (r: Ctl)
        requires
            old(self).refines(p),
            !(sp::op_load_local(old(self).g@, n as int, len as int) is Stuck),
            old(self).bci + len < 0x1000_0000,
        ensures
            r == Ctl::Next || is_limit(r),
            r == Ctl::Next ==> final(self).refines(p)
                && sp::op_load_local(old(self).g@, n as int, len as int) == Outcome2::Next(final(self).g@),
    {
        proof { self.lemma_at(p, n as int); }
        let v = self.at(n);
        self.push_next(p, v, len, Ghost(sp::at(self.g@, n as int)))
    }

    /// POP_LOAD_LOCAL n.
    #[inline(always)]
    pub fn op_pop_load_local(&mut self, p: &Program, n: usize) -> (r: Ctl)
        requires
            old(self).refines(p),
            !(sp::op_pop_load_local(old(self).g@, n as int) is Stuck),
            old(self).bci + 2 < 0x1000_0000,
            n < 256,
        ensures
            r == Ctl::Next,
            final(self).refines(p),
            sp::op_pop_load_local(old(self).g@, n as int) == Outcome2::Next(final(self).g@),
    {
        let ghost m0 = *self;
        let ghost g0 = self.g@;
        proof { self.lemma_at(p, n + 1); self.lemma_at(p, 0); }
        let v = self.at(n + 1);
        self.put(0, v);
        self.bci = self.bci + 2;
        let ghost g1 = sp::goto(sp::put(g0, 0, sp::at(g0, n + 1)), g0.bci + 2);
        self.g = Ghost(g1);
        proof {
            assert(self.words() =~= enc_seq(m0.addr(), g1.stack));
            assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
                if i != g0.stack.len() - 1 { assert(g1.stack[i] == g0.stack[i]); }
            }
            m0.lemma_local_step(p, self);
        }
        Ctl::Next
    }

    /// STORE_LOCAL n.
    #[inline(always)]
    pub fn op_store_local(&mut self, p: &Program, n: usize) -> (r: Ctl)
        requires
            old(self).refines(p),
            !(sp::op_store_local(old(self).g@, n as int) is Stuck),
            old(self).bci + 2 < 0x1000_0000,
        ensures
            r == Ctl::Next,
            final(self).refines(p),
            sp::op_store_local(old(self).g@, n as int) == Outcome2::Next(final(self).g@),
    {
        let ghost m0 = *self;
        let ghost g0 = self.g@;
        proof { self.lemma_at(p, n as int); self.lemma_at(p, 0); }
        let v = self.at(0);
        self.put(n, v);
        self.bci = self.bci + 2;
        let ghost g1 = sp::goto(sp::put(g0, n as int, sp::at(g0, 0)), g0.bci + 2);
        self.g = Ghost(g1);
        proof {
            assert(self.words() =~= enc_seq(m0.addr(), g1.stack));
            assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
                if i != g0.stack.len() - 1 - n { assert(g1.stack[i] == g0.stack[i]); }
            }
            m0.lemma_local_step(p, self);
        }
        Ctl::Next
    }

    /// STORE_LOCAL_POP n.
    #[inline(always)]
    pub fn op_store_local_pop(&mut self, p: &Program, n: usize) -> (r: Ctl)
        requires
            old(self).refines(p),
            !(sp::op_store_local_pop(old(self).g@, n as int) is Stuck),
            old(self).bci + 2 < 0x1000_0000,
        ensures
            r == Ctl::Next,
            final(self).refines(p),
            sp::op_store_local_pop(old(self).g@, n as int) == Outcome2::Next(final(self).g@),
    {
        let ghost m0 = *self;
        let ghost g0 = self.g@;
        proof { self.lemma_at(p, n as int); self.lemma_at(p, 0); }
        let v = self.at(0);
        self.drop(1);
        let ghost w1 = self.words();
        self.put(n - 1, v);
        self.bci = self.bci + 2;
        let ghost g1 = sp::goto(sp::put(sp::drop(g0, 1), n - 1, sp::at(g0, 0)), g0.bci + 2);
        self.g = Ghost(g1);
        proof {
            let h = g0.stack.len();
            assert(w1 == m0.words().subrange(0, h - 1));
            assert(self.words() == w1.update(h - 1 - n, v));
            assert(g1.stack == g0.stack.subrange(0, h - 1).update(h - 1 - n, sp::at(g0, 0)));
            assert forall|i: int| 0 <= i < h - 1 implies #[trigger] self.words()[i] == enc(m0.addr(), g1.stack[i]) by {
                if i != h - 1 - n {
                    assert(self.words()[i] == m0.words()[i]);
                    assert(m0.words()[i] == enc_seq(m0.addr(), g0.stack)[i]);
                }
            }
            assert(self.words() =~= enc_seq(m0.addr(), g1.stack));
            assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
                if i != g0.stack.len() - 1 - n { assert(g1.stack[i] == g0.stack[i]); }
            }
            m0.lemma_local_step(p, self);
        }
        Ctl::Next
    }

    /// POP n, POP_1.
    #[inline(always)]
    pub fn op_pop(&mut self, p: &Program, n: usize, len: usize) -> (r: Ctl)
        requires
            old(self).refines(p),
            !(sp::op_pop(old(self).g@, n as int, len as int) is Stuck),
            old(self).bci + len < 0x1000_0000,
        ensures
            r == Ctl::Next,
            final(self).refines(p),
            sp::op_pop(old(self).g@, n as int, len as int) == Outcome2::Next(final(self).g@),
    {
        let ghost m0 = *self;
        let ghost g0 = self.g@;
        proof { self.lemma_frame(p); }
        self.drop(n);
        self.bci = self.bci + len;
        let ghost g1 = sp::goto(sp::drop(g0, n as int), g0.bci + len);
        self.g = Ghost(g1);
        proof {
            assert(self.words() =~= enc_seq(m0.addr(), g1.stack));
            assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
                assert(g1.stack[i] == g0.stack[i]);
            }
            m0.lemma_local_step(p, self);
        }
        Ctl::Next
    }

    /// LOAD_SMIS_0 n: pushes n zeros.
    #[inline(always)]
    pub fn op_load_smis_0(&mut self, p: &Program, n: usize) -> (r: Ctl)
        requires
            old(self).refines(p),
            old(self).bci + 2 < 0x1000_0000,
        ensures
            r == Ctl::Next || is_limit(r),
            r == Ctl::Next ==> final(self).refines(p)
                && sp::op_load_smis_0(old(self).g@, n as int) == Outcome2::Next(final(self).g@),
    {
        let ghost m0 = *self;
        let ghost g0 = self.g@;
        if self.top - self.rtop < n {
            return Ctl::Stuck(stuck::LIMIT);
        }
        proof { lemma_smi_word_nat(0); }
        let mut i: usize = 0;
        while i < n
            invariant
                self.stack_ok(),
                i <= n,
                self.top >= self.rtop + (n - i),
                self.top == m0.top - i,
                self.bci == m0.bci,
                self.same(&m0),
                self.words() == m0.words() + Seq::new(i as nat, |j: int| 0usize),
            decreases n - i,
        {
            let ok = self.push(0);
            i = i + 1;
            assert(self.words() =~= m0.words() + Seq::new(i as nat, |j: int| 0usize));
        }
        self.bci = self.bci + 2;
        let ghost g1 = sp::goto(State2 { stack: g0.stack + Seq::new(n as nat, |j: int| Value::Smi(0)), ..g0 }, g0.bci + 2);
        self.g = Ghost(g1);
        proof {
            assert(self.words() =~= enc_seq(m0.addr(), g1.stack));
            assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
                if i < g0.stack.len() { assert(g1.stack[i] == g0.stack[i]); }
            }
            assert(sp::op_load_smis_0(g0, n as int) == Outcome2::Next(g1)) by {
                assert(g1 == sp::goto(State2 { stack: g0.stack + Seq::new(n as nat, |j: int| Value::Smi(0)), ..g0 }, g0.bci + 2));
            }
            m0.lemma_local_step(p, self);
        }
        Ctl::Next
    }

    /// Stores top, record and frame tops and bci into the Stack object, so
    /// that the GC and C++ see the task's state.
    #[inline(always)]
    pub fn save(&mut self)
        ensures
            crate::alloc::saved(*final(self)),
            final(self).mem@ == old(self).mem@,
            final(self).mem@.len() == old(self).mem@.len(),
            final(self).top == old(self).top,
            final(self).bci == old(self).bci,
            final(self).same(old(self)),
    {
        let (top, rtop, ftop, bci) = (self.top, self.rtop, self.ftop, self.bci);
        self.mem.set_header(STACK_TOP_WORD, top);
        self.mem.set_header(STACK_RECORD_TOP_WORD, rtop | (ftop << STACK_FRAME_TOP_SHIFT));
        self.mem.set_header(STACK_BCI_WORD, bci);
    }

    /// LOAD_LITERAL(_WIDE) i.
    #[inline(always)]
    pub fn op_load_literal(&mut self, p: &Program, i: usize, len: usize) -> (r: Ctl)
        requires
            old(self).refines(p),
            !(sp::op_load_literal(p.ap@, old(self).g@, i as int, len as int) is Stuck),
            old(self).bci + len < 0x1000_0000,
        ensures
            r == Ctl::Next || is_limit(r),
            r == Ctl::Next ==> final(self).refines(p)
                && sp::op_load_literal(p.ap@, old(self).g@, i as int, len as int) == Outcome2::Next(final(self).g@),
    {
        let ghost v = p.ap@.literals[i as int];
        proof { assert(p.literals@[i as int] == enc(self.addr(), v) && const_ok(self.g@.heap, v)); }
        let w = p.literals.at(i);
        self.push_next(p, w, len, Ghost(v))
    }

    /// LOAD_NULL.
    #[inline(always)]
    pub fn op_load_null(&mut self, p: &Program, len: usize) -> (r: Ctl)
        requires old(self).refines(p), old(self).bci + len < 0x1000_0000,
        ensures
            r == Ctl::Next || is_limit(r),
            r == Ctl::Next ==> final(self).refines(p)
                && sp::next(sp::push(old(self).g@, sp::null2(p.ap@)), len as int) == Outcome2::Next(final(self).g@),
    {
        let ghost v = p.ap@.roots[0];
        proof { assert(const_ok(self.g@.heap, v)); }
        let w = p.null;
        self.push_next(p, w, len, Ghost(v))
    }

    /// LOAD_SMI_0, LOAD_SMI_1, LOAD_SMI_U8, LOAD_SMI_U16, LOAD_SMI_U32 and
    /// LOAD_METHOD: push the smi `v`.
    #[inline(always)]
    pub fn op_load_smi(&mut self, p: &Program, v: usize, len: usize) -> (r: Ctl)
        requires old(self).refines(p), old(self).bci + len < 0x1000_0000, v as int <= MAX_SMI,
        ensures
            r == Ctl::Next || is_limit(r),
            r == Ctl::Next ==> final(self).refines(p)
                && sp::next(sp::push(old(self).g@, Value::Smi(v as i64)), len as int) == Outcome2::Next(final(self).g@),
    {
        let w = smi_of(v as i64);
        self.push_next(p, w, len, Ghost(Value::Smi(v as i64)))
    }

    /// LOAD_GLOBAL_VAR(_WIDE) g.
    #[inline(always)]
    pub fn op_load_global(&mut self, p: &Program, gi: usize, len: usize) -> (r: Ctl)
        requires
            old(self).refines(p),
            !(sp::op_load_global(old(self).g@, gi as int, len as int) is Stuck),
            old(self).bci + len < 0x1000_0000,
        ensures
            r == Ctl::Next || is_limit(r),
            r == Ctl::Next ==> final(self).refines(p)
                && sp::op_load_global(old(self).g@, gi as int, len as int) == Outcome2::Next(final(self).g@),
    {
        let ghost g0 = self.g@;
        proof {
            assert(enc_seq(self.addr(), g0.globals)[gi as int] == enc(self.addr(), g0.globals[gi as int]));
        }
        let v = self.globals.at(gi);
        self.push_next(p, v, len, Ghost(g0.globals[gi as int]))
    }

    /// STORE_GLOBAL_VAR(_WIDE) g.
    #[inline(always)]
    pub fn op_store_global(&mut self, p: &Program, gi: usize, len: usize) -> (r: Ctl)
        requires
            old(self).refines(p),
            !(sp::op_store_global(old(self).g@, gi as int, len as int) is Stuck),
            old(self).bci + len < 0x1000_0000,
        ensures
            r == Ctl::Next,
            final(self).refines(p),
            sp::op_store_global(old(self).g@, gi as int, len as int) == Outcome2::Next(final(self).g@),
    {
        let ghost m0 = *self;
        let ghost g0 = self.g@;
        proof { self.lemma_at(p, 0); }
        let v = self.at(0);
        self.globals.set(gi, v);
        self.bci = self.bci + len;
        let ghost g1 = sp::goto(State2 { globals: g0.globals.update(gi as int, sp::at(g0, 0)), ..g0 }, g0.bci + len);
        self.g = Ghost(g1);
        proof {
            assert(enc_seq(m0.addr(), g1.globals) =~= enc_seq(m0.addr(), g0.globals).update(gi as int, v));
            assert(self.words() =~= enc_seq(m0.addr(), g1.stack));
            assert forall|i: int| 0 <= i < g1.globals.len() implies #[trigger] encodable(m0.addr(), g1.globals[i]) by {
                if i != gi { assert(g1.globals[i] == g0.globals[i]); }
            }
            m0.lemma_local_step(p, self);
        }
        Ctl::Next
    }

    /// The branch condition of `kind` on a word (`spec::branch_taken`):
    /// 1 if true, 2 if false, 3 if not null.
    #[inline(always)]
    pub fn taken(p: &Program, kind: usize, w: usize) -> (r: bool)
        requires 1 <= kind <= 3,
        ensures r == (if kind == 1 { w != p.false_ && w != p.null }
            else if kind == 2 { !(w != p.false_ && w != p.null) } else { w != p.null }),
    {
        if kind == 1 {
            w != p.false_ && w != p.null
        } else if kind == 2 {
            !(w != p.false_ && w != p.null)
        } else {
            w != p.null
        }
    }

    /// BRANCH*, BRANCH_BACK*: `kind` 0 always, 1 if true, 2 if false, 3 if
    /// not null. The target is inside the method (from the spec).
    #[inline(always)]
    pub fn op_branch(&mut self, p: &Program, kind: usize, target: usize, len: usize) -> (r: Ctl)
        requires
            old(self).refines(p),
            kind <= 3,
            !(sp::op_branch(p.ap@, old(self).g@, kind as int, target as int, len as int) is Stuck),
            kind != 0 ==> !(sp::at(old(self).g@, 0) is BlockRef),
            old(self).bci + len < 0x1000_0000,
        ensures
            r == Ctl::Next,
            final(self).refines(p),
            sp::op_branch(p.ap@, old(self).g@, kind as int, target as int, len as int) == Outcome2::Next(final(self).g@),
    {
        let ghost m0 = *self;
        let ghost g0 = self.g@;
        let ghost ap = p.ap@;
        if kind != 0 {
            proof { self.lemma_at(p, 0); }
            let v = self.at(0);
            self.drop(1);
            proof {
                let a = sp::at(g0, 0);
                let addr = m0.addr();
                assert(ap.roots[0] == sp::null2(ap) && ap.roots[2] == sp::false2(ap));
                assert(encodable(addr, ap.roots[0])) by { assert(const_ok(g0.heap, ap.roots[0])); }
                assert(encodable(addr, ap.roots[2])) by { assert(const_ok(g0.heap, ap.roots[2])); }
                lemma_enc_inj(g0.heap, addr, a, sp::null2(ap));
                lemma_enc_inj(g0.heap, addr, a, sp::false2(ap));
                assert((v == p.null) == (a == sp::null2(ap)));
                assert((v == p.false_) == (a == sp::false2(ap)));
            }
            let taken = Self::taken(p, kind, v);
            if !taken {
                self.bci = self.bci + len;
                let ghost g1 = sp::goto(sp::drop(g0, 1), g0.bci + len);
                self.g = Ghost(g1);
                proof {
                    assert(self.words() =~= enc_seq(m0.addr(), g1.stack));
                    assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
                        assert(g1.stack[i] == g0.stack[i]);
                    }
                    m0.lemma_local_step(p, self);
                }
                return Ctl::Next;
            }
            self.bci = target;
            let ghost g1 = sp::goto(sp::drop(g0, 1), target as int);
            self.g = Ghost(g1);
            proof {
                assert(self.words() =~= enc_seq(m0.addr(), g1.stack));
                assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
                    assert(g1.stack[i] == g0.stack[i]);
                }
                m0.lemma_local_step(p, self);
            }
            Ctl::Next
        } else {
            self.bci = target;
            let ghost g1 = sp::goto(g0, target as int);
            self.g = Ghost(g1);
            proof {
                assert(self.words() =~= enc_seq(m0.addr(), g1.stack));
                m0.lemma_local_step(p, self);
            }
            Ctl::Next
        }
    }
}

} // verus!
