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
use toit_spec::v2::vprog::x_hdr_size;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::vprog::{vdecode, u16_at, table_ok, rec_ok, rec_entry, hdr_size, kind_byte};
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
    pub methods: Table<u32>,
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
    /// The unchecked mode of a trusted program (`Program2::unchecked`): field
    /// accesses are not checked (verified/core/EXPERIMENT-trusted.md).
    pub unchecked: bool,
    pub null: usize,
    pub true_: usize,
    pub false_: usize,
    pub smi_class_id: usize,
    pub list_class_id: usize,
    pub byte_array_slice_class_id: usize,
    pub byte_array_cow_class_id: usize,
    pub large_array_class_id: usize,
    pub lazy_initializer_class_id: usize,
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
    /// The slow path a register handler hands to the run loop with
    /// `Ctl::Slow`, and its word (not part of the abstraction).
    pub slow_k: crate::step::Slow,
    pub slow_w: usize,
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
    /// A register handler's slow path (`step::Slow`, with the instruction's
    /// word), which the run loop runs (`step::slow`): one call site instead
    /// of one per handler. Only register handlers return it (`rpost`); the
    /// slow path and its word are in `Machine::slow_k`, `slow_w`.
    Slow,
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

/// The program heap's address range does not wrap around (checked once per
/// run, `step::run_loop`), so that the program-heap test is one compare.
pub open spec fn ro_ok(p: &Program) -> bool {
    p.ro_start + p.ro_size <= usize::MAX
}

/// A kind byte whose kind is not a block's is not the block's kind byte.
pub proof fn lemma_not_block(b: u8)
    ensures (b & KIND_MASK) != 3 ==> b != 3,
{
    assert((b & 3u8) != 3 ==> b != 3) by (bit_vector);
}

impl Program {
    /// The abstract program.
    pub open spec fn ap(&self) -> Program2 {
        self.ap@
    }

    /// Method `i`, decoded from its record and header (format note 21).
    pub open spec fn minfo(&self, i: int) -> V2Method {
        vdecode(self.code@, self.methods@, i)
    }

    /// The method tables the loader checked (`table_ok`, `prog_rel`), and
    /// the bytecodes at an even address (checked at entry, `toit_v2_run`).
    pub open spec fn mt_ok(&self) -> bool {
        &&& table_ok(self.code@, self.methods@)
        &&& self.code@.len() < MAX_TABLE
        &&& self.code.even()
    }

    /// The record of method `i` and its entry, whose header lies inside
    /// the bytecodes before it; odd unless the method is a block.
    #[inline(always)]
    fn record(&self, i: usize) -> (r: (u32, usize))
        requires i < self.methods@.len(), self.mt_ok(),
        ensures
            r.0 == self.methods@[i as int],
            r.1 == rec_entry(r.0) as usize,
            1 <= r.1 <= self.code@.len(),
            hdr_size(kind_byte(self.code@, r.1 as int)) <= r.1,
            kind_byte(self.code@, r.1 as int) <= 4,
            kind_byte(self.code@, r.1 as int) == 3 || r.1 % 2 == 1,
    {
        let r = self.methods.at(i);
        proof {
            assert(r >> RECORD_ENTRY_SHIFT < 0x100_0000) by (bit_vector);
            assert(rec_ok(self.code@, self.methods@[i as int]));
        }
        (r, (r >> RECORD_ENTRY_SHIFT) as usize)
    }

    /// The little-endian u16 at `e - d` (a field of a header that ends at
    /// the odd `e`, inside the bytecodes, at the odd distance `d`): one
    /// aligned 16-bit load.
    #[inline(always)]
    fn u16_before(&self, e: usize, d: usize) -> (r: u16)
        requires 2 <= d <= e, e <= self.code@.len(), e % 2 == 1, d % 2 == 1, self.code.even(),
        ensures r == u16_at(self.code@, e - d),
    {
        self.code.u16_at_even(e - d)
    }

    /// The entry of method `i`.
    #[inline(always)]
    pub fn entry_of(&self, i: usize) -> (r: usize)
        requires i < self.methods@.len(), self.mt_ok(),
        ensures r == self.minfo(i as int).entry as usize,
    {
        self.record(i).1
    }

    /// The arity of method `i`.
    #[inline(always)]
    pub fn arity_of(&self, i: usize) -> (r: usize)
        requires i < self.methods@.len(), self.mt_ok(),
        ensures r == self.minfo(i as int).arity as usize,
    {
        let r = self.methods.at(i);
        proof { assert((r & RECORD_ARITY_MASK) as u8 as usize == (r & RECORD_ARITY_MASK) as usize) by (bit_vector); }
        (r & RECORD_ARITY_MASK) as usize
    }

    /// The kind byte of method `i` (its kind in the low two bits).
    #[inline(always)]
    pub fn kind_byte_of(&self, i: usize) -> (r: u8)
        requires i < self.methods@.len(), self.mt_ok(),
        ensures r & KIND_MASK == self.minfo(i as int).kind,
    {
        let (_, e) = self.record(i);
        self.code.at(e - 1)
    }

    /// Whether method `i` has kind `k` (accessor, lambda or block): one
    /// compare of the kind byte, which is canonical (`rec_ok`).
    #[inline(always)]
    pub fn is_kind(&self, i: usize, k: u8) -> (r: bool)
        requires i < self.methods@.len(), self.mt_ok(), 1 <= k <= 3,
        ensures r == (self.minfo(i as int).kind == k),
    {
        let (_, e) = self.record(i);
        let b = self.code.at(e - 1);
        proof {
            assert(b == kind_byte(self.code@, e as int));
            assert(1 <= k <= 3 && b <= 4 ==> ((b == k) == (b & KIND_MASK == k))) by (bit_vector);
        }
        b == k
    }

    /// The selector of method `i`, a method or an accessor (a dispatch
    /// target of an accepted program: no kind test).
    #[inline(always)]
    pub fn dispatch_selector(&self, i: usize) -> (r: u16)
        requires i < self.methods@.len(), self.mt_ok(), self.minfo(i as int).kind < 2,
        ensures r == self.minfo(i as int).selector,
    {
        let (_, e) = self.record(i);
        proof { assert(hdr_size(kind_byte(self.code@, e as int)) >= 5); lemma_not_block(kind_byte(self.code@, e as int)); }
        self.u16_before(e, SELECTOR_BACK)
    }

    /// The receiver range start of method `i`, a method or an accessor.
    #[inline(always)]
    pub fn dispatch_recv_start(&self, i: usize) -> (r: u16)
        requires i < self.methods@.len(), self.mt_ok(), self.minfo(i as int).kind < 2,
        ensures r == self.minfo(i as int).recv_start,
    {
        let (_, e) = self.record(i);
        proof { assert(hdr_size(kind_byte(self.code@, e as int)) >= 5); lemma_not_block(kind_byte(self.code@, e as int)); }
        self.u16_before(e, RECV_START_BACK)
    }

    /// Whether class `cid` is in the receiver range of method `i`, a method
    /// or an accessor whose range starts at `rs` (not none): `cid == rs`
    /// for one class.
    #[inline(always)]
    pub fn dispatch_recv_contains(&self, i: usize, rs: u16, cid: usize) -> (r: bool)
        requires
            i < self.methods@.len(), self.mt_ok(), self.minfo(i as int).kind < 2,
            rs == self.minfo(i as int).recv_start, rs != NO_VALUE,
        ensures r == ((rs as int) <= cid && cid < self.minfo(i as int).recv_end as int),
    {
        let (_, e) = self.record(i);
        let b = self.code.at(e - 1);
        if b & KIND_SINGLE != 0 {
            cid == rs as usize
        } else {
            proof { assert(hdr_size(b) >= 7); lemma_not_block(b); }
            (rs as usize) <= cid && cid < self.u16_before(e, RECV_END_BACK) as usize
        }
    }

    /// Method `i` (`minfo`): its record and header, read without bounds
    /// checks (the loader's `table_ok`). Inlined: only the fields a caller
    /// uses are read (the body end, which needs the next record, only on
    /// the paths that check branches).
    #[inline(always)]
    pub fn method(&self, i: usize) -> (r: V2Method)
        requires i < self.methods@.len(), self.mt_ok(),
        ensures r == self.minfo(i as int),
    {
        let (r, e) = self.record(i);
        let ghost code = self.code@;
        let b = self.code.at(e - 1);
        let k = b & KIND_MASK;
        let ghost hs = hdr_size(b);
        proof { lemma_not_block(b); }
        let mut selector = NO_VALUE;
        let mut aux: u16 = 0;
        let mut recv_start = NO_VALUE;
        let mut recv_end = NO_VALUE;
        if k < 2 {
            proof { assert(hs >= 5); }
            selector = self.u16_before(e, SELECTOR_BACK);
            recv_start = self.u16_before(e, RECV_START_BACK);
            if b & KIND_SINGLE == 0 {
                proof { assert(hs >= 7); }
                recv_end = self.u16_before(e, RECV_END_BACK);
            } else if recv_start < NO_VALUE {
                recv_end = recv_start + 1;
            }
            if k == 1 {
                proof { assert(hs == 9); }
                aux = self.u16_before(e, ACCESSOR_AUX_BACK);
            }
        } else if k == 2 {
            proof { assert(hs == 3); }
            aux = self.u16_before(e, LAMBDA_AUX_BACK);
        }
        let body_end: u32 = if i < self.methods.len() - 1 {
            let (_, e2) = self.record(i + 1);
            let b2 = self.code.at(e2 - 1);
            (e2 - x_hdr_size(b2)) as u32
        } else {
            self.code.len() as u32
        };
        V2Method {
            entry: r >> RECORD_ENTRY_SHIFT,
            body_end,
            selector,
            aux,
            recv_start,
            recv_end,
            arity: (r & RECORD_ARITY_MASK) as u8,
            kind: k,
        }
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
            final(self).len == old(self).len,
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
            final(self).len == old(self).len,
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
            final(self).mem.sid() == old(self).mem.sid(),
            final(self).globals == old(self).globals,
            final(self).heap == old(self).heap,
            final(self).fw == old(self).fw,
            final(self).need == old(self).need,
            final(self).bot == old(self).bot,
    {
        let (top, rtop, ftop, bci) = (self.top, self.rtop, self.ftop, self.bci);
        self.mem.set_header(STACK_TOP_WORD, top);
        self.mem.set_header(STACK_RECORD_TOP_WORD, rtop | (ftop << STACK_FRAME_TOP_SHIFT));
        self.mem.set_header(STACK_BCI_WORD, bci);
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

}

} // verus!
