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

//! A growable sequence in chunks of `CHUNK` elements, for the per-method
//! maps of the structural verifier (`v2::check::XMaps`): a fragmented
//! device heap often has no contiguous block for a vector of the method's
//! size (4 bytes per bytecode byte for the map index, 16 per kind node),
//! and growing a vector copies it into a block twice as large while the
//! old one is still allocated. A `CVec` never asks for more than one chunk
//! at a time and never copies its elements; it is built with a `CBuild`
//! (whole chunks plus a block that is a plain vector, so that a push is a
//! vector push) and then only read. Verified on top of the trusted
//! accessors of `xvec` (no new trusted code).

use vstd::prelude::*;
use alloc::vec::Vec;
use crate::xvec::{ix_ref, vix, try_push, try_with_capacity, Oom};

verus! {

/// Elements per chunk: 1 KB of kind nodes, 256 bytes of map indices.
pub const CHUNK: usize = 64;

/// The elements of full chunks `full` followed by `tail`.
pub open spec fn flat<T>(full: Seq<Vec<T>>, tail: Seq<T>) -> Seq<T> {
    Seq::new((CHUNK * full.len() + tail.len()) as nat, |i: int|
        if i < CHUNK * full.len() { full[i / (CHUNK as int)]@[i % (CHUNK as int)] }
        else { tail[i - CHUNK * full.len()] })
}

/// Every chunk of `full` is full.
pub open spec fn chunks_full<T>(full: Seq<Vec<T>>) -> bool {
    forall|j: int| 0 <= j < full.len() ==> #[trigger] full[j]@.len() == CHUNK
}

/// Moving a full tail to the full chunks keeps the elements.
proof fn lemma_flat_move<T>(full: Seq<Vec<T>>, t: Vec<T>, empty: Seq<T>)
    requires chunks_full(full), t@.len() == CHUNK, empty.len() == 0,
    ensures chunks_full(full.push(t)), flat(full.push(t), empty) == flat(full, t@),
{
    let f1 = full.push(t);
    assert forall|j: int| 0 <= j < f1.len() implies #[trigger] f1[j]@.len() == CHUNK by {
        if j < full.len() { assert(f1[j] == full[j]); }
    }
    let a = flat(f1, empty);
    let b = flat(full, t@);
    assert(a.len() == b.len());
    assert forall|i: int| 0 <= i < a.len() implies #[trigger] a[i] == b[i] by {
        if i >= CHUNK * full.len() {
            assert(i / (CHUNK as int) == full.len());
            assert(i % (CHUNK as int) == i - CHUNK * full.len());
        } else {
            assert(i / (CHUNK as int) < full.len());
            assert(f1[i / (CHUNK as int)] == full[i / (CHUNK as int)]);
        }
    }
    assert(a =~= b);
}

/// The full chunks (`CHUNK` elements each) and the last, partial one.
pub struct CVec<T> {
    full: Vec<Vec<T>>,
    tail: Vec<T>,
    len: usize,
}

impl<T> CVec<T> {
    #[verifier::type_invariant]
    spec fn inv(&self) -> bool {
        &&& chunks_full(self.full@)
        &&& self.tail@.len() <= CHUNK
        &&& self.len == CHUNK * self.full@.len() + self.tail@.len()
    }

    pub closed spec fn spec_view(&self) -> Seq<T> {
        flat(self.full@, self.tail@)
    }

    /// An empty sequence (no allocation).
    pub fn new() -> (r: CVec<T>)
        ensures r@ == Seq::<T>::empty(),
    {
        let r = CVec { full: Vec::new(), tail: Vec::new(), len: 0 };
        proof { assert(r.spec_view() =~= Seq::<T>::empty()); }
        r
    }


    #[inline(always)]
    pub fn len(&self) -> (r: usize)
        ensures r == self@.len(),
    {
        proof { use_type_invariant(self); }
        self.len
    }

    /// Element `i`.
    #[inline(always)]
    pub fn at(&self, i: usize) -> (r: T)
        where T: Copy
        requires i < self@.len(),
        ensures r == self@[i as int],
    {
        proof { use_type_invariant(self); }
        // Most methods' maps fit one chunk.
        if self.full.len() == 0 {
            return vix(&self.tail, i);
        }
        let j = i / CHUNK;
        let k = i % CHUNK;
        if j < self.full.len() {
            proof {
                assert(i < CHUNK * self.full@.len());
                assert(self.full@[j as int]@.len() == CHUNK);
            }
            vix(ix_ref(self.full.as_slice(), j), k)
        } else {
            proof {
                assert(i >= CHUNK * self.full@.len());
                assert(k == i - CHUNK * self.full@.len());
            }
            vix(&self.tail, k)
        }
    }
}

impl<T: Copy> CVec<T> {
    /// `v` followed by the elements of `c` (at most a chunk), for a `v`
    /// whose length is a multiple of `CHUNK`: `c` becomes the tail, no
    /// copy. `Err(Oom)`: contents unspecified, the length a multiple of
    /// `CHUNK` and not more than the two together.
    #[allow(non_shorthand_field_patterns)]
    pub fn append_block(v: CVec<T>, c: Vec<T>) -> (r: (CVec<T>, Result<(), Oom>))
        requires (v@.len() as int) % (CHUNK as int) == 0, c@.len() <= CHUNK,
        ensures
            r.1 is Ok ==> r.0@ == v@ + c@,
            r.1 is Err ==> (r.0@.len() as int) % (CHUNK as int) == 0 && r.0@.len() <= v@.len() + c@.len(),
    {
        proof { use_type_invariant(&v); }
        let ghost v0 = v@;
        let CVec { mut full, mut tail, len } = v;
        proof {
            vstd::arithmetic::div_mod::lemma_mod_multiples_vanish(full@.len() as int, tail@.len() as int, CHUNK as int);
            assert(tail@.len() == 0 || tail@.len() == CHUNK);
        }
        if len > usize::MAX - c.len() {
            proof { assert(flat(full@, tail@).len() == len); }
            return (CVec { full, tail, len }, Err(Oom));
        }
        if tail.len() == CHUNK {
            let ghost f0 = full@;
            let ghost t0 = tail;
            let mut t: Vec<T> = Vec::new();
            core::mem::swap(&mut t, &mut tail);
            match try_push(&mut full, t) {
                Ok(()) => {},
                Err(e) => {
                    let n = CHUNK * full.len();
                    proof {
                        assert(flat(full@, tail@).len() == n);
                        vstd::arithmetic::div_mod::lemma_mod_multiples_vanish(full@.len() as int, 0, CHUNK as int);
                    }
                    return (CVec { full, tail, len: n }, Err(e));
                },
            }
            proof { lemma_flat_move(f0, t0, tail@); }
        }
        let cl = c.len();
        let ghost f1 = full@;
        let ghost cv = c@;
        let r = CVec { full, tail: c, len: len + cl };
        proof { lemma_flat_tail(f1, cv); }
        (r, Ok(()))
    }
}

/// The elements of the full chunks `full` and then of `t` are those of the
/// full chunks followed by `t`.
proof fn lemma_flat_tail<T>(full: Seq<Vec<T>>, t: Seq<T>)
    ensures flat(full, t) == flat(full, Seq::<T>::empty()) + t,
{
    let a = flat(full, t);
    let b = flat(full, Seq::<T>::empty()) + t;
    assert forall|i: int| 0 <= i < a.len() implies #[trigger] a[i] == b[i] by {}
    assert(a =~= b);
}

/// A sequence being built by pushes (the decoder's maps): the whole chunks
/// so far and a block of at most a chunk, a plain vector, so that a push is
/// a vector push (`CVec::try_push` takes the sequence out of `&mut` first).
pub struct CBuild<T> {
    pub done: CVec<T>,
    pub blk: Vec<T>,
}

impl<T: Copy> CBuild<T> {
    pub open spec fn ok(&self) -> bool {
        &&& (self.done@.len() as int) % (CHUNK as int) == 0
        &&& self.blk@.len() <= CHUNK
        &&& self.done@.len() + self.blk@.len() < usize::MAX
    }

    /// The elements so far.
    pub open spec fn items(&self) -> Seq<T> {
        self.done@ + self.blk@
    }

    /// An empty sequence whose first block has room for `n` elements (at
    /// most a chunk), or `Err(Oom)`.
    pub fn try_new(n: usize) -> (r: Result<CBuild<T>, Oom>)
        ensures r matches Ok(b) ==> b.ok() && b.items() == Seq::<T>::empty(),
    {
        let n = if n < CHUNK { n } else { CHUNK };
        let blk: Vec<T> = try_with_capacity(n)?;
        let b = CBuild { done: CVec::new(), blk };
        proof { assert(b.items() =~= Seq::<T>::empty()); }
        Ok(b)
    }

    #[inline(always)]
    pub fn len(&self) -> (r: usize)
        requires self.ok(),
        ensures r == self.items().len(),
    {
        self.done.len() + self.blk.len()
    }

    /// Appends `x`, or `Err(Oom)` (contents unspecified).
    #[inline(always)]
    pub fn try_push(&mut self, x: T) -> (r: Result<(), Oom>)
        requires old(self).ok(),
        ensures final(self).ok(), r is Ok ==> final(self).items() == old(self).items().push(x),
    {
        if self.blk.len() == CHUNK {
            self.flush()?;
        }
        if self.done.len() + self.blk.len() >= usize::MAX - 1 { return Err(Oom); }
        let ghost s1 = self.items();
        let ghost b1 = self.blk@;
        try_push(&mut self.blk, x)?;
        proof { assert(self.items() =~= s1.push(x)); }
        Ok(())
    }

    /// Moves the full block to the chunks.
    fn flush(&mut self) -> (r: Result<(), Oom>)
        requires old(self).ok(), old(self).blk@.len() == CHUNK,
        ensures
            final(self).ok(),
            r is Ok ==> final(self).items() == old(self).items() && final(self).blk@.len() == 0,
    {
        let mut b: Vec<T> = try_with_capacity(CHUNK)?;
        core::mem::swap(&mut b, &mut self.blk);
        let mut d = CVec::new();
        core::mem::swap(&mut d, &mut self.done);
        let (d2, r) = CVec::append_block(d, b);
        self.done = d2;
        proof {
            if r is Ok {
                assert(self.done@.len() == old(self).done@.len() + CHUNK);
                vstd::arithmetic::div_mod::lemma_mod_multiples_vanish(1, old(self).done@.len() as int, CHUNK as int);
                assert(self.items() =~= old(self).items());
            }
        }
        r
    }

    /// Appends copies of `x` until there are `n` elements, or `Err(Oom)`.
    pub fn try_fill_to(&mut self, x: T, n: usize) -> (r: Result<(), Oom>)
        requires old(self).ok(), old(self).items().len() <= n,
        ensures
            final(self).ok(),
            r is Ok ==> final(self).items() == old(self).items() + Seq::new((n - old(self).items().len()) as nat, |i: int| x),
    {
        let ghost s0 = self.items();
        proof { assert(s0 =~= s0 + Seq::new(0, |i: int| x)); }
        while self.len() < n
            invariant
                self.ok(), s0.len() <= self.items().len() <= n,
                self.items() == s0 + Seq::new((self.items().len() - s0.len()) as nat, |i: int| x),
            decreases n - self.items().len(),
        {
            self.try_push(x)?;
            proof { assert(self.items() =~= s0 + Seq::new((self.items().len() - s0.len()) as nat, |i: int| x)); }
        }
        Ok(())
    }

    /// The sequence built, or `Err(Oom)`.
    #[allow(non_shorthand_field_patterns)]
    pub fn try_finish(self) -> (r: Result<CVec<T>, Oom>)
        requires self.ok(),
        ensures r matches Ok(v) ==> v@ == self.items(),
    {
        let ghost s = self.items();
        let CBuild { done, blk } = self;
        let (v, r) = CVec::append_block(done, blk);
        r?;
        Ok(v)
    }
}

impl<T> View for CVec<T> {
    type V = Seq<T>;

    open spec fn view(&self) -> Seq<T> {
        self.spec_view()
    }
}

} // verus!
