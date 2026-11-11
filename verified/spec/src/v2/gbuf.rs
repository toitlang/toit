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

//! The global part of a certificate in owned buffers (untrusted): the byte
//! tables `check::XGlobal` borrows (format/18-shipped-certificate.md),
//! built and updated by the inference (`v2::infer`), and written out with
//! the maps stream as a shipped certificate (`v2::encode`).

use alloc::vec;
use alloc::vec::Vec;
use crate::v2::check::*;
use crate::v2::vprog::*;

const KIND_BLOCK: u8 = 3;

/// The node words of a kind (`check::dk`); `None` if it does not fit.
pub fn kind_words(k: XKind) -> Option<(u32, u32)> {
    match k {
        XKind::Val => Some((0, 0)),
        XKind::Param => Some((1, 0)),
        XKind::Token => Some((2, 0)),
        XKind::Method(t) => Some((3, t)),
        XKind::Block(d, s) => if d < (1 << 29) { Some((4 | (d << 3), s)) } else { None },
    }
}

pub fn rd32(s: &[u8], i: usize) -> u32 {
    match s.get(i..i.wrapping_add(4)) {
        Some(b) => u32::from_le_bytes([b[0], b[1], b[2], b[3]]),
        None => 0,
    }
}

pub fn wr32(s: &mut [u8], i: usize, v: u32) {
    if let Some(b) = s.get_mut(i..i.wrapping_add(4)) {
        b.copy_from_slice(&v.to_le_bytes());
    }
}

pub fn push32(s: &mut Vec<u8>, v: u32) {
    s.extend_from_slice(&v.to_le_bytes());
}

pub struct GBuf {
    pub n: usize,
    /// A word per method (block methods: context record + 1; others:
    /// block-parameter mask).
    pub mw: Vec<u8>,
    pub crec: Vec<u8>,
    pub sel: Vec<u8>,
    pub pins: Vec<u8>,
    pub nodes: Vec<u8>,
    /// Trusted: set by the caller.
    pub global_count: u64,
    pub prim_arity: Vec<Vec<u8>>,
    /// A kind could not be represented (the certificate will be rejected).
    pub unrepresentable: bool,
}

impl GBuf {
    pub fn new(n: usize, global_count: u64, prim_arity: Vec<Vec<u8>>) -> GBuf {
        GBuf {
            n,
            mw: vec![0; n.saturating_mul(4)],
            crec: Vec::new(),
            sel: Vec::new(),
            pins: Vec::new(),
            nodes: Vec::new(),
            global_count,
            prim_arity,
            unrepresentable: false,
        }
    }

    /// The checker's view, with the method table `methods`.
    pub fn view<'a>(&'a self, methods: &'a [VMethod]) -> XGlobal<'a> {
        XGlobal {
            n: self.n,
            methods,
            mw: &self.mw,
            crec: &self.crec,
            sel: &self.sel,
            pins: &self.pins,
            nodes: &self.nodes,
            global_count: self.global_count,
            prim_arity: &self.prim_arity,
        }
    }

    pub fn word(&self, m: usize) -> u32 {
        rd32(&self.mw, m.wrapping_mul(4))
    }

    pub fn set_word(&mut self, m: usize, w: u32) {
        wr32(&mut self.mw, m.wrapping_mul(4), w)
    }

    /// The context of block method `t`: (outer, slot, top node).
    pub fn ctx(&self, t: usize) -> Option<(u32, u32, u32)> {
        let w = self.word(t) as usize;
        if w == 0 || w > self.crec.len() / 12 { return None; }
        let j = (w - 1) * 12;
        Some((rd32(&self.crec, j), rd32(&self.crec, j + 4), rd32(&self.crec, j + 8)))
    }

    pub fn node_count(&self) -> usize {
        self.nodes.len() / 12
    }

    /// Appends the list `kinds` (bottom first) to the node table, sharing
    /// its first `share` slots with the list whose node ids are `ids`.
    /// Returns the top node (`EMPTY_MAP` for the empty list).
    pub fn add_list(&mut self, kinds: &[XKind]) -> u32 {
        let mut top = EMPTY_MAP;
        for &k in kinds {
            let id = self.node_count() as u32;
            let (a, b) = match kind_words(k) {
                Some(x) => x,
                None => { self.unrepresentable = true; (0, 0) },
            };
            push32(&mut self.nodes, if top == EMPTY_MAP { id } else { top });
            push32(&mut self.nodes, a);
            push32(&mut self.nodes, b);
            top = id;
        }
        top
    }

    /// The list of node `top`, bottom first.
    pub fn list(&self, top: u32) -> Vec<XKind> {
        x_fchain(&self.nodes, top)
    }

    /// Sets the context of block method `t`; an existing one with another
    /// creator or slot is kept (the checker then rejects the other
    /// creation).
    pub fn set_ctx(&mut self, t: usize, outer: u32, slot: u32, kinds: &[XKind]) {
        match self.ctx(t) {
            Some((o, s, top)) => {
                if o == outer && s == slot && self.list(top) != kinds {
                    let top = self.add_list(kinds);
                    let j = (self.word(t) as usize - 1) * 12;
                    wr32(&mut self.crec, j + 8, top);
                }
            }
            None => {
                let j = self.crec.len() / 12;
                if j >= u32::MAX as usize - 1 { return; }
                let top = self.add_list(kinds);
                push32(&mut self.crec, outer);
                push32(&mut self.crec, slot);
                push32(&mut self.crec, top);
                self.set_word(t, j as u32 + 1);
            }
        }
    }

    /// Removes every context (block methods' words, records, nodes).
    pub fn clear_ctxs(&mut self, methods: &[VMethod]) {
        for (m, info) in methods.iter().enumerate() {
            if info.kind == KIND_BLOCK { self.set_word(m, 0); }
        }
        self.crec.clear();
        self.nodes.clear();
    }

    /// Sets bit `x` of method `t`'s block-parameter mask; whether it
    /// changed. Parameters from 32 on cannot be block parameters.
    pub fn set_bit(&mut self, t: usize, x: usize) -> bool {
        if x >= 32 { return false; }
        let w = self.word(t);
        if w & (1 << x) != 0 { return false; }
        self.set_word(t, w | (1 << x));
        true
    }

    /// The selector records from (selector, representative) pairs, sorted.
    pub fn set_sels(&mut self, reps: &[(u32, u32)]) {
        self.sel.clear();
        for &(s, r) in reps {
            push32(&mut self.sel, s);
            push32(&mut self.sel, r);
        }
    }

    /// The pins from (method, offset, kinds), sorted and without
    /// duplicates.
    pub fn set_pins(&mut self, pins: &[(u32, u32, Vec<XKind>)]) {
        self.pins.clear();
        for (m, off, kinds) in pins {
            let top = self.add_list(kinds);
            push32(&mut self.pins, *m);
            push32(&mut self.pins, *off);
            push32(&mut self.pins, top);
        }
    }

    /// The pins: (method, offset, top node).
    pub fn pin_list(&self) -> Vec<(u32, u32, u32)> {
        (0..self.pins.len() / 12).map(|i| {
            (rd32(&self.pins, i * 12), rd32(&self.pins, i * 12 + 4), rd32(&self.pins, i * 12 + 8))
        }).collect()
    }
}
