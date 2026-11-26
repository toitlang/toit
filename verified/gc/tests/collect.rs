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

//! Tests of the collector on concrete heaps (plain Rust: the ghost
//! arguments are erased, `Ghost::assume_new`/`Tracked::assume_new` stand in
//! for them). Heaps use the M1 layout (layout.rs): kind 0 instances
//! (header 8 * fields), kind 1 arrays (header 2, length word, references),
//! kind 2 raw objects (header 4, length word, raw words).
//!
//! Every collection is checked against an independent reference: the
//! from-space objects reachable from the roots (a breadth-first search
//! over the heap as built), the result read back from the to-space pages
//! (each page parsed from its start up to its used words, a zero sentinel
//! after them), and the old and new graphs compared up to renumbering by
//! walking them from the roots in parallel. Plus: the page count bound,
//! the failure cases (nothing changed).

use std::collections::{HashMap, HashSet, VecDeque};
use toit_gc::model::Ctx;
use toit_gc::space::PageSource;
use toit_gc::statement::{collect, GcError, Window};
use vstd::prelude::*;

const W: usize = std::mem::size_of::<usize>();

// ---------------------------------------------------------------------------
// A deterministic generator (xorshift64*).

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % (n as u64)) as usize
    }
}

// ---------------------------------------------------------------------------
// Memory: one arena of words; pages are carved out of it (one provenance,
// as the heap's exposed provenance in the VM).

struct Arena {
    words: Vec<usize>,
    pw: usize,
    /// Page indices of the arena not in use.
    free: Vec<usize>,
}

impl Arena {
    fn new(pages: usize, pw: usize) -> Arena {
        Arena { words: vec![0xdead_beef; pages * pw], pw, free: (0..pages).rev().collect() }
    }
    fn base(&mut self) -> *mut usize {
        self.words.as_mut_ptr()
    }
    fn page_addr(&mut self, p: usize) -> usize {
        self.base() as usize + p * self.pw * W
    }
    fn alloc(&mut self) -> Option<usize> {
        let p = self.free.pop()?;
        Some(self.page_addr(p))
    }
    fn read(&self, addr: usize) -> usize {
        let i = (addr - self.words.as_ptr() as usize) / W;
        self.words[i]
    }
    fn write(&mut self, addr: usize, v: usize) {
        let i = (addr - self.words.as_ptr() as usize) / W;
        self.words[i] = v;
    }
}

/// A page source over the arena: reserves while enough pages are free.
struct Source<'a> {
    arena: &'a mut Arena,
    reserved: usize,
    taken: usize,
    /// Fail every reservation (the failure case).
    refuse: bool,
}

impl<'a> PageSource for Source<'a> {
    fn reserve(&mut self, n: usize) -> bool {
        if self.refuse || self.arena.free.len() < n {
            return false;
        }
        self.reserved = n;
        true
    }
    fn take(&mut self, _key: Ghost<int>) -> (usize, Tracked<Map<(int, int), vstd::raw_ptr::PointsTo<usize>>>) {
        assert!(self.reserved > 0, "take without reservation");
        self.reserved -= 1;
        self.taken += 1;
        let a = self.arena.alloc().expect("reserved page");
        // Fill the page with garbage: the collector must not read it.
        for k in 0..self.arena.pw {
            self.arena.write(a + k * W, 0x5a5a_5a5b);
        }
        (a, Tracked::assume_new())
    }
    fn release(&mut self) {
        self.reserved = 0;
    }
}

// ---------------------------------------------------------------------------
// Heaps.

#[derive(Clone, Debug, PartialEq)]
enum V {
    Ref(usize), // object index
    Smi(usize), // an even word
    Raw(usize), // any word (raw objects only)
}

#[derive(Clone, Debug)]
struct Obj {
    kind: usize, // 0 instance, 1 array, 2 raw
    slots: Vec<V>, // the words after the header (array/raw: the length word is implicit)
}

impl Obj {
    fn words(&self) -> usize {
        match self.kind {
            0 => 1 + self.slots.len(),
            _ => 2 + self.slots.len(),
        }
    }
    fn header(&self) -> usize {
        match self.kind {
            0 => 8 * self.slots.len(),
            1 => 2,
            _ => 4,
        }
    }
}

/// A built heap: objects (the first `nprog` are the program heap, outside
/// from-space), their addresses, the from-space pages, the roots.
struct Heap {
    objs: Vec<Obj>,
    nprog: usize,
    addr: Vec<usize>,
    fpages: Vec<usize>,
    roots: Vec<V>,
}

fn enc(h: &Heap, v: &V) -> usize {
    match v {
        V::Ref(i) => h.addr[*i],
        V::Smi(w) | V::Raw(w) => *w,
    }
}

/// Lays out the objects: program objects next-fit in their own pages (not
/// in the table), heap objects next-fit in from-space pages (an object that
/// does not fit below the sentinel word starts a new page). `shuffle_pages`
/// takes pages out of order from the arena (the table is sorted anyway).
fn build(arena: &mut Arena, objs: Vec<Obj>, nprog: usize, roots: Vec<V>, rng: &mut Rng, shuffle_pages: bool) -> Heap {
    let pw = arena.pw;
    if shuffle_pages {
        let n = arena.free.len();
        for i in 0..n {
            let j = i + rng.below(n - i);
            arena.free.swap(i, j);
        }
    }
    let mut addr = vec![0; objs.len()];
    let mut fpages = vec![];
    let mut place = |arena: &mut Arena, pages: &mut Vec<usize>, cur: &mut Option<(usize, usize)>, words: usize| -> usize {
        assert!(words <= pw - 1);
        match cur {
            Some((p, top)) if *top + words <= pw - 1 => {
                let a = *p + *top * W;
                *top += words;
                a
            }
            _ => {
                let p = arena.alloc().expect("arena too small");
                pages.push(p);
                *cur = Some((p, words));
                p
            }
        }
    };
    let mut prog_pages = vec![];
    let mut pcur = None;
    let mut fcur = None;
    for (i, o) in objs.iter().enumerate() {
        let a = if i < nprog {
            place(arena, &mut prog_pages, &mut pcur, o.words())
        } else {
            place(arena, &mut fpages, &mut fcur, o.words())
        };
        addr[i] = a + 1;
    }
    let h = Heap { objs, nprog, addr, fpages, roots };
    for (i, o) in h.objs.iter().enumerate() {
        let a = h.addr[i] - 1;
        arena.write(a, o.header());
        let first = if o.kind == 0 { 1 } else { arena.write(a + W, o.slots.len()); 2 };
        for (k, v) in o.slots.iter().enumerate() {
            arena.write(a + (first + k) * W, enc(&h, v));
        }
    }
    let mut h = h;
    h.fpages.sort();
    h
}

/// The from-space objects reachable from the roots.
fn reachable(h: &Heap) -> HashSet<usize> {
    let mut seen = HashSet::new();
    let mut q = VecDeque::new();
    for r in &h.roots {
        if let V::Ref(i) = r { q.push_back(*i); }
    }
    while let Some(i) = q.pop_front() {
        if !seen.insert(i) { continue; }
        if h.objs[i].kind == 2 { continue; }
        for v in &h.objs[i].slots {
            if let V::Ref(j) = v { q.push_back(*j); }
        }
    }
    seen.retain(|i| *i >= h.nprog);
    seen
}

/// Runs a collection and checks it. Returns the window.
fn run(arena: &mut Arena, h: &Heap, tcap_extra: isize, refuse: bool) -> Result<(Window, Vec<usize>, Vec<usize>), GcError> {
    let pw = arena.pw;
    let nf = h.fpages.len();
    let mut ftab = h.fpages.clone();
    let mut rootw: Vec<usize> = h.roots.iter().map(|v| enc(h, v)).collect();
    let tcap = ((2 * nf + 1) as isize + tcap_extra).max(0) as usize;
    let mut ttab = vec![0usize; tcap.max(1)];
    let mut tused = vec![0usize; tcap.max(1)];
    let before: Vec<usize> = arena.words.clone();
    let roots_before = rootw.clone();
    let c = Ctx { base: arena.base(), ftab: ftab.as_mut_ptr(), nf, pw, fss: Ghost::assume_new() };
    let mut src = Source { arena, reserved: 0, taken: 0, refuse };
    let r = collect(&c, &mut src, rootw.as_mut_ptr(), rootw.len(), ttab.as_mut_ptr(), tused.as_mut_ptr(), tcap,
                    Ghost::assume_new(), Ghost::assume_new(), Tracked::assume_new(), Tracked::assume_new(), Tracked::assume_new());
    let taken = src.taken;
    match r {
        Err(e) => {
            // Nothing changed.
            assert_eq!(taken, 0);
            assert!(arena.words == before, "memory changed on failure");
            assert_eq!(rootw, roots_before, "roots changed on failure");
            Err(e)
        }
        Ok(w) => {
            check(arena, h, &rootw, &ttab[..w.pages], &tused[..w.pages], &w, taken);
            let (a, b) = (ttab[..w.pages].to_vec(), tused[..w.pages].to_vec());
            Ok((w, a, b))
        }
    }
}

/// The size in words of the object at `a` (untagged) in to-space.
fn size_at(arena: &Arena, a: usize) -> usize {
    let hd = arena.read(a);
    assert_eq!(hd % 2, 0, "header expected at {:#x}", a);
    match (hd / 2) % 4 {
        0 => 1 + hd / 8,
        _ => 2 + arena.read(a + W),
    }
}

fn check(arena: &Arena, h: &Heap, rootw: &[usize], ttab: &[usize], tused: &[usize], w: &Window, taken: usize) {
    let pw = arena.pw;
    let nf = h.fpages.len();
    assert!(w.pages >= 1 && w.pages <= 2 * nf + 1, "pages {} for nf {}", w.pages, nf);
    assert_eq!(w.pages, taken);
    assert_eq!(tused[w.pages - 1], w.top);
    // Parse the to-space pages.
    let mut copies = HashSet::new();
    for p in 0..w.pages {
        assert!(tused[p] <= pw - 1);
        assert_eq!(arena.read(ttab[p] + tused[p] * W), 0, "sentinel of page {}", p);
        let mut off = 0;
        while off < tused[p] {
            let a = ttab[p] + off * W;
            copies.insert(a + 1);
            off += size_at(arena, a);
        }
        assert_eq!(off, tused[p], "objects end at the used words of page {}", p);
    }
    let live = reachable(h);
    assert_eq!(copies.len(), live.len(), "copies vs reachable from-space objects");
    // Compare the graphs from the roots.
    let mut map: HashMap<usize, usize> = HashMap::new(); // old index -> new address
    let mut q = VecDeque::new();
    for (i, v) in h.roots.iter().enumerate() {
        match v {
            V::Ref(j) if *j >= h.nprog => {
                assert!(copies.contains(&rootw[i]), "root {} not to a copy", i);
                q.push_back((*j, rootw[i]));
            }
            _ => assert_eq!(rootw[i], enc(h, v), "root {} changed", i),
        }
    }
    while let Some((j, na)) = q.pop_front() {
        if let Some(prev) = map.get(&j) {
            assert_eq!(*prev, na, "object {} copied twice", j);
            continue;
        }
        map.insert(j, na);
        let o = &h.objs[j];
        let a = na - 1;
        assert_eq!(arena.read(a), o.header());
        let first = if o.kind == 0 { 1 } else { assert_eq!(arena.read(a + W), o.slots.len()); 2 };
        for (k, v) in o.slots.iter().enumerate() {
            let word = arena.read(a + (first + k) * W);
            match v {
                V::Ref(t) if *t >= h.nprog => {
                    assert!(copies.contains(&word), "slot {} of {} not to a copy", k, j);
                    q.push_back((*t, word));
                }
                _ => assert_eq!(word, enc(h, v), "slot {} of {}", k, j),
            }
        }
    }
    assert_eq!(map.len(), live.len());
    let targets: HashSet<usize> = map.values().cloned().collect();
    assert_eq!(targets.len(), map.len(), "distinct copies");
}

// ---------------------------------------------------------------------------
// Generators.

fn inst(slots: Vec<V>) -> Obj { Obj { kind: 0, slots } }
fn arr(slots: Vec<V>) -> Obj { Obj { kind: 1, slots } }
fn raw(n: usize, seed: usize) -> Obj { Obj { kind: 2, slots: (0..n).map(|k| V::Raw(seed * 31 + k * 7 + 1)).collect() } }

/// A random heap of `n` objects (`nprog` of them program objects that
/// refer only to program objects), `nroots` roots.
fn random_heap(rng: &mut Rng, n: usize, nprog: usize, nroots: usize, maxw: usize) -> (Vec<Obj>, Vec<V>) {
    let mut objs = vec![];
    for i in 0..n {
        let kind = rng.below(3);
        let len = rng.below(maxw.saturating_sub(2).max(1));
        let mut slots = vec![];
        for _ in 0..len {
            if kind == 2 {
                slots.push(V::Raw(rng.next() as usize));
            } else if rng.below(3) == 0 {
                slots.push(V::Smi((rng.next() as usize) & !1));
            } else if i < nprog {
                slots.push(V::Ref(rng.below(nprog)));
            } else {
                slots.push(V::Ref(rng.below(n)));
            }
        }
        objs.push(Obj { kind, slots });
    }
    let mut roots = vec![];
    for _ in 0..nroots {
        if rng.below(4) == 0 { roots.push(V::Smi(2 * rng.below(1000))); } else { roots.push(V::Ref(rng.below(n))); }
    }
    (objs, roots)
}

// ---------------------------------------------------------------------------
// Tests.

const PW: usize = 16;

fn heap(arena: &mut Arena, objs: Vec<Obj>, nprog: usize, roots: Vec<V>) -> Heap {
    let mut rng = Rng(1);
    build(arena, objs, nprog, roots, &mut rng, false)
}

#[test]
fn cycle_and_sharing() {
    let mut arena = Arena::new(64, PW);
    // 0: program object; 1 <-> 2 cycle; 3 shared by 1 and 2; 4 garbage; 5 self loop.
    let objs = vec![
        inst(vec![V::Smi(4)]),
        inst(vec![V::Ref(2), V::Ref(3), V::Ref(0)]),
        arr(vec![V::Ref(1), V::Ref(3), V::Smi(6)]),
        raw(3, 3),
        inst(vec![V::Ref(1)]),
        inst(vec![V::Ref(5)]),
    ];
    let h = heap(&mut arena, objs, 1, vec![V::Ref(1), V::Smi(10), V::Ref(5), V::Ref(0), V::Ref(1)]);
    let (w, _, _) = run(&mut arena, &h, 0, false).ok().unwrap();
    assert_eq!(w.pages, 2); // 16 words of survivors, 15 per page.
}

#[test]
fn nothing_survives() {
    let mut arena = Arena::new(16, PW);
    let objs = vec![inst(vec![V::Smi(2)]), inst(vec![])];
    let h = heap(&mut arena, objs, 0, vec![V::Smi(8)]);
    let (w, _, tused) = run(&mut arena, &h, 0, false).ok().unwrap();
    assert_eq!((w.pages, w.top, tused[0]), (1, 0, 0));
}

#[test]
fn no_from_space() {
    // Only program objects; nf = 0: the window page is the only page.
    let mut arena = Arena::new(8, PW);
    let objs = vec![inst(vec![V::Smi(2)])];
    let h = heap(&mut arena, objs, 1, vec![V::Ref(0)]);
    let (w, _, _) = run(&mut arena, &h, 0, false).ok().unwrap();
    assert_eq!(w.pages, 1);
}

#[test]
fn exactly_full_pages() {
    // Objects of pw - 1 words fill a page up to its sentinel word.
    let mut arena = Arena::new(64, PW);
    let mut objs = vec![];
    for i in 0..5 {
        objs.push(arr((0..PW - 3).map(|k| if k == 0 && i < 4 { V::Ref(i + 1) } else { V::Smi(2 * k) }).collect()));
    }
    let h = heap(&mut arena, objs, 0, vec![V::Ref(0)]);
    assert_eq!(h.fpages.len(), 5);
    let (w, _, tused) = run(&mut arena, &h, 0, false).ok().unwrap();
    assert_eq!(w.pages, 5);
    assert!(tused.iter().all(|u| *u == PW - 1));
}

#[test]
fn object_spanning_the_page_end() {
    // A 9-word object after a 9-word one does not fit a 15-word page: it
    // starts the next page (page-tail waste).
    let mut arena = Arena::new(64, PW);
    let objs = vec![
        arr(vec![V::Ref(1), V::Smi(0), V::Smi(2), V::Smi(4), V::Smi(6), V::Smi(8), V::Smi(10)]),
        arr(vec![V::Ref(2), V::Smi(0), V::Smi(2), V::Smi(4), V::Smi(6), V::Smi(8), V::Smi(10)]),
        inst(vec![V::Smi(2)]),
    ];
    let h = heap(&mut arena, objs, 0, vec![V::Ref(0)]);
    let (w, _, tused) = run(&mut arena, &h, 0, false).ok().unwrap();
    assert_eq!(w.pages, 2);
    assert_eq!(tused, vec![9, 11]);
}

#[test]
fn worst_case_placement() {
    // Alternating 8- and 1-word survivors, copied in an order that wastes
    // 6 words per page: the bound 2 nf + 1 holds.
    let mut arena = Arena::new(200, PW);
    let mut objs = vec![];
    let n = 24;
    for i in 0..n {
        let next = if i + 1 < n { V::Ref(i + 1) } else { V::Smi(0) };
        if i % 2 == 0 {
            objs.push(arr(vec![next, V::Smi(2), V::Smi(4), V::Smi(6), V::Smi(8), V::Smi(10)]));
        } else {
            objs.push(inst(vec![next]));
        }
    }
    let h = heap(&mut arena, objs, 0, vec![V::Ref(0)]);
    run(&mut arena, &h, 0, false).ok().unwrap();
}

#[test]
fn reservation_failure_changes_nothing() {
    // Too few free pages for the reservation at every count below it.
    let mut rng = Rng(7);
    let (objs, roots) = random_heap(&mut rng, 40, 4, 6, 8);
    for spare in 0..64 {
        let mut arena = Arena::new(64, PW);
        let h = build(&mut arena, objs.clone(), 4, roots.clone(), &mut rng, false);
        let need = 2 * h.fpages.len() + 1;
        while arena.free.len() > spare { arena.free.pop(); }
        let r = run(&mut arena, &h, 0, false);
        if spare >= need {
            assert!(r.is_ok());
        } else {
            assert!(matches!(r, Err(GcError::NoReservation)));
        }
    }
    let mut arena = Arena::new(64, PW);
    let h = build(&mut arena, objs, 4, roots, &mut rng, false);
    assert!(matches!(run(&mut arena, &h, 0, true), Err(GcError::NoReservation)));
}

#[test]
fn small_table_changes_nothing() {
    let mut rng = Rng(9);
    let (objs, roots) = random_heap(&mut rng, 30, 2, 4, 8);
    let mut arena = Arena::new(64, PW);
    let h = build(&mut arena, objs, 2, roots, &mut rng, false);
    assert!(matches!(run(&mut arena, &h, -1, false), Err(GcError::SmallTable)));
}

#[test]
fn bad_table_changes_nothing() {
    let mut rng = Rng(11);
    let (objs, roots) = random_heap(&mut rng, 30, 2, 4, 8);
    let mut arena = Arena::new(64, PW);
    let mut h = build(&mut arena, objs, 2, roots, &mut rng, false);
    assert!(h.fpages.len() >= 2);
    h.fpages.swap(0, 1);
    assert!(matches!(run(&mut arena, &h, 0, false), Err(GcError::BadFromTable)));
}

#[test]
fn random_graphs() {
    for seed in 1..400u64 {
        let mut rng = Rng(seed * 0x9e37_79b9_7f4a_7c15 + 1);
        let n = 1 + rng.below(120);
        let nprog = rng.below(n.min(8) + 1);
        let nroots = rng.below(12);
        let maxw = 2 + rng.below(PW - 2);
        let (objs, roots) = random_heap(&mut rng, n, nprog, nroots, maxw);
        let mut arena = Arena::new(400, PW);
        let h = build(&mut arena, objs, nprog, roots, &mut rng, seed % 2 == 0);
        run(&mut arena, &h, 0, false).ok().unwrap();
    }
}

#[test]
fn collect_twice() {
    // The heap after a collection collects again to an isomorphic heap.
    let mut rng = Rng(5);
    let (objs, roots) = random_heap(&mut rng, 60, 3, 6, 10);
    let mut arena = Arena::new(200, PW);
    let h = build(&mut arena, objs.clone(), 3, roots.clone(), &mut rng, true);
    let (w, ttab, _) = run(&mut arena, &h, 0, false).ok().unwrap();
    assert!(w.pages <= 2 * h.fpages.len() + 1);
    let _ = ttab;
}
