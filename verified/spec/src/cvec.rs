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
//! at a time and never copies its elements. Verified on top of the trusted
//! accessors of `xvec` (no new trusted code): push and read only.

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

/// Appending to the tail appends to the elements.
proof fn lemma_flat_push<T>(full: Seq<Vec<T>>, tail: Seq<T>, x: T)
    ensures flat(full, tail.push(x)) == flat(full, tail).push(x),
{
    let a = flat(full, tail.push(x));
    let b = flat(full, tail).push(x);
    assert forall|i: int| 0 <= i < a.len() implies #[trigger] a[i] == b[i] by {
        if i >= CHUNK * full.len() && i < CHUNK * full.len() + tail.len() {
            assert(tail.push(x)[i - CHUNK * full.len()] == tail[i - CHUNK * full.len()]);
        }
    }
    assert(a =~= b);
}

/// Makes room for one more element in `tail`: a full tail moves to the full
/// chunks (a new tail with room for a chunk takes its place); a tail with
/// no room left (`room` is what was asked for when it was allocated) moves
/// to a larger one (twice the room, at most a chunk), so that no tail is
/// ever more than a chunk. On `Err(Oom)` the elements are unspecified, the
/// shape is kept.
fn make_room<T: Copy>(full: &mut Vec<Vec<T>>, tail: &mut Vec<T>, room: &mut usize) -> (r: Result<(), Oom>)
    requires chunks_full(old(full)@), old(tail)@.len() <= *old(room) <= CHUNK,
    ensures
        chunks_full(final(full)@), final(tail)@.len() <= *final(room) <= CHUNK,
        CHUNK * final(full)@.len() + final(tail)@.len() <= CHUNK * old(full)@.len() + old(tail)@.len(),
        r is Ok ==> final(tail)@.len() < *final(room)
            && flat(final(full)@, final(tail)@) == flat(old(full)@, old(tail)@),
{
    if tail.len() < *room { return Ok(()); }
    if tail.len() == CHUNK {
        let ghost f0 = full@;
        let ghost t0 = *tail;
        let mut t: Vec<T> = try_with_capacity(CHUNK)?;
        core::mem::swap(&mut t, tail);
        *room = CHUNK;
        match try_push(full, t) {
            Ok(()) => {},
            Err(e) => return Err(e),
        }
        proof { lemma_flat_move(f0, t0, tail@); }
        return Ok(());
    }
    // A partial tail without room: copy it into a larger one.
    let r2 = if *room < 2 { 4 } else if *room < CHUNK / 2 { 2 * *room } else { CHUNK };
    let mut t: Vec<T> = try_with_capacity(r2)?;
    let mut i: usize = 0;
    while i < tail.len()
        invariant i <= tail@.len() < r2 <= CHUNK, t@ == tail@.subrange(0, i as int),
            tail@.len() <= *room <= CHUNK, chunks_full(full@), full@ == old(full)@, tail@ == old(tail)@,
        decreases tail@.len() - i,
    {
        try_push(&mut t, vix(tail, i))?;
        proof { assert(tail@.subrange(0, i + 1) =~= tail@.subrange(0, i as int).push(tail@[i as int])); }
        i += 1;
    }
    proof { assert(tail@.subrange(0, tail@.len() as int) =~= tail@); }
    core::mem::swap(&mut t, tail);
    *room = r2;
    Ok(())
}

/// The full chunks (`CHUNK` elements each) and the last, partial one, which
/// was allocated with room for `room` elements.
pub struct CVec<T> {
    full: Vec<Vec<T>>,
    tail: Vec<T>,
    room: usize,
    len: usize,
}

impl<T> CVec<T> {
    #[verifier::type_invariant]
    spec fn inv(&self) -> bool {
        &&& chunks_full(self.full@)
        &&& self.tail@.len() <= self.room <= CHUNK
        &&& self.len == CHUNK * self.full@.len() + self.tail@.len()
    }

    pub closed spec fn spec_view(&self) -> Seq<T> {
        flat(self.full@, self.tail@)
    }

    /// An empty sequence (no allocation).
    pub fn new() -> (r: CVec<T>)
        ensures r@ == Seq::<T>::empty(),
    {
        let r = CVec { full: Vec::new(), tail: Vec::new(), room: 0, len: 0 };
        proof { assert(r.spec_view() =~= Seq::<T>::empty()); }
        r
    }

    /// An empty sequence whose first chunk has room for `n` elements (at
    /// most a chunk), or `Err(Oom)`.
    pub fn try_with_room(n: usize) -> (r: Result<CVec<T>, Oom>)
        ensures r matches Ok(v) ==> v@ == Seq::<T>::empty(),
    {
        let n = if n < CHUNK { n } else { CHUNK };
        let tail: Vec<T> = try_with_capacity(n)?;
        let r = CVec { full: Vec::new(), tail, room: n, len: 0 };
        proof { assert(r.spec_view() =~= Seq::<T>::empty()); }
        Ok(r)
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
    /// Appends `x`, or `Err(Oom)` if an allocation failed (then the
    /// sequence's contents are unspecified: callers give up on `Oom`).
    pub fn try_push(&mut self, x: T) -> (r: Result<(), Oom>)
        ensures r is Ok ==> final(self)@ == old(self)@.push(x),
    {
        let ghost s0 = self@;
        let r = self.try_fill_to(x, 1, true);
        proof { if r is Ok { assert(self@ =~= s0.push(x)); } }
        r
    }

    /// Appends copies of `x` until there are `n` elements (`n` more if
    /// `more`), or `Err(Oom)` (contents unspecified).
    pub fn try_fill_to(&mut self, x: T, n: usize, more: bool) -> (r: Result<(), Oom>)
        requires more || old(self)@.len() <= n,
        ensures
            r is Ok ==> final(self)@ == old(self)@ + Seq::new(
                (if more { n as int } else { n - old(self)@.len() }) as nat, |i: int| x),
    {
        // Taken out of `self` (its fields are borrowed below), put back.
        let mut me = CVec::new();
        core::mem::swap(&mut me, self);
        let (v, r) = Self::filled(me, x, n, more);
        *self = v;
        r
    }

    #[allow(non_shorthand_field_patterns)]
    fn filled(v: CVec<T>, x: T, n: usize, more: bool) -> (r: (CVec<T>, Result<(), Oom>))
        requires more || v@.len() <= n,
        ensures
            r.1 is Ok ==> r.0@ == v@ + Seq::new(
                (if more { n as int } else { n - v@.len() }) as nat, |i: int| x),
    {
        proof { use_type_invariant(&v); }
        let ghost s0 = v@;
        let CVec { mut full, mut tail, mut room, mut len } = v;
        let target = if more {
            if len > usize::MAX - n { return (CVec { full, tail, room, len }, Err(Oom)); }
            len + n
        } else { n };
        proof { assert(s0 =~= s0 + Seq::new(0, |i: int| x)); }
        while len < target
            invariant
                chunks_full(full@), tail@.len() <= room <= CHUNK, len == CHUNK * full@.len() + tail@.len(),
                s0.len() <= len <= target,
                flat(full@, tail@) == s0 + Seq::new((len - s0.len()) as nat, |i: int| x),
            decreases target - len,
        {
            let ghost before = flat(full@, tail@);
            match make_room(&mut full, &mut tail, &mut room) {
                Ok(()) => {},
                Err(e) => {
                    let n2 = CHUNK * full.len() + tail.len();
                    return (CVec { full, tail, room, len: n2 }, Err(e));
                },
            }
            proof { assert(flat(full@, tail@).len() == before.len()); }
            let ghost f1 = full@;
            let ghost t1 = tail@;
            match try_push(&mut tail, x) {
                Ok(()) => {},
                Err(e) => return (CVec { full, tail, room, len }, Err(e)),
            }
            proof {
                lemma_flat_push(f1, t1, x);
                assert(flat(full@, tail@) =~= s0 + Seq::new((len + 1 - s0.len()) as nat, |i: int| x));
            }
            len = len + 1;
        }
        (CVec { full, tail, room, len }, Ok(()))
    }
}

impl<T> View for CVec<T> {
    type V = Seq<T>;

    open spec fn view(&self) -> Seq<T> {
        self.spec_view()
    }
}

} // verus!
