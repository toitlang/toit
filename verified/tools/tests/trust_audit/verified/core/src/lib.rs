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

//! Fixture of verified/tools/tests/trust_audit_test.sh: every escape hatch
//! the audit knows, plus decoys that must not count. Not compiled.

#![verifier::loop_isolation(false)]
#![cfg_attr(verus_keep_ghost, verifier::exec_allows_no_decreases_clause)]
#![allow(unused)]

use vstd::prelude::*;

#[cfg(verus_keep_ghost)]
use vstd::std_specs::*;

// Decoys: assume(x) admit() unsafe #[verifier::external_body] in a comment.
/* A block comment /* nested */ with assume(false) and unsafe { } inside. */

verus! {

#![verifier::external]

pub struct Point {
    pub x: u32,
    pub y: u32,
}

#[verifier::external_body]
pub fn trusted_add(a: u32, b: u32) -> (r: u32)
    ensures r == a + b,
{
    a.wrapping_add(b)
}

#[verifier::external]
fn ignored() {
}

#[verifier::external_fn_specification]
pub fn ex_spec(x: u8) -> u8 {
    x
}

#[verifier::external_type_specification]
pub struct ExPoint(Point);

#[verifier::external_trait_specification]
pub trait ExTrait {
    fn method(&self);
}

#[verifier::external_trait_extension(TraitSpec via TraitSpecImpl)]
pub trait Extended {
    fn ext(&self);
}

#[verifier::external_derive]
#[derive(Clone)]
pub struct Derived {
    v: u8,
}

#[verifier::assume_termination]
fn loops_forever() {
    loop {}
}

#[verifier::exec_allows_no_decreases_clause]
fn no_decreases(n: u32) {
    let mut i = 0;
    while i < n {
        i = i + 1;
    }
}

#[verifier::truncate]
fn truncating(x: u64) -> u8 {
    x as u8
}

#[verifier::when_used_as_spec(spec_len)]
pub fn len(v: &Vec<u8>) -> usize {
    v.len()
}

#[verifier::ghost_wrapper]
#[verifier::tracked_swap_primitive]
#[verifier::tracked_take_option_primitive]
fn internal_primitives() {
}

#[verifier::some_future_attribute]
fn unknown_attribute_fails_closed() {
}

#[verifier(external_body, spinoff_prover)]
fn old_style(x: u8) -> u8 {
    x
}

#[verus_verify(external_body)]
fn verus_verify_form() {
}

#[verus_spec(verifier::assume_termination)]
fn verus_spec_form() {
}

#[verus::internal(something)]
fn internal_attr() {
}

#[verus::trusted]
fn verus_attr() {
}

#[cfg(verus_only)]
fn only_for_verus() {
}

#[cfg_attr(verus_keep_ghost, verifier::external_body)]
fn cfg_attr_hatch() {
}

#[cfg(toit_vcore_hosted)]
fn hosted_only() {
}

#[cfg(feature = "verus_like")]
fn cfg_on_a_string() {
}

#[cfg(not_verus)]
fn not_a_verus_cfg() {
}

fn assume_in_body(x: u8)
    requires x > 0,
{
    assume(x < 10);
    admit();
    let t = Tracked::assume_new();
    let g = Ghost::assume_new_fallback();
    verus_builtin::assume_(true);
    unsafe { core::ptr::null::<u8>().read() };
    let s = "assume(x) unsafe admit()";
    let r = r#"assume(false) "quoted" unsafe"#;
    let b = br"admit()";
    let c = '"';
    let d = b'\'';
    let e = '\u{1F600}';
    let lifetime_like: &'static str = "x";
    if cfg!(verus_keep_ghost) {
    }
    if cfg!(target_os = "linux") {
    }
    #[verifier::truncate]
    let y = x as u8;
    let z = 0x1F_u8 + 1_000u16 as u8 + 1e3 as u8 + 0b1010 + 0o17;
    inline_air_stmt("(assert true)");
}

fn assume_not_called(assume: u8) -> u8 {
    assume
}

pub uninterp spec fn opaque_value(x: int) -> int;

pub spec fn bodiless(x: int) -> int;

pub open spec fn with_body(x: int) -> int {
    x + 1
}

pub closed spec fn closed_one(x: int) -> int {
    x
}

#[verifier::opaque]
pub open spec fn opaque_one(x: int) -> int {
    x
}

#[verifier::rlimit(50)]
proof fn heavy_proof()
    ensures true,
{
}

pub axiom fn axiom_fact(x: int)
    ensures x == x;

proof fn empty_with_ensures(x: int)
    ensures x + 0 == x,
{}

proof fn top_level_theorem(x: int)
    requires x > 0,
    ensures x >= 1,
{
    lemma_helper(x);
}

proof fn lemma_helper(x: int)
    ensures x == x,
{
}

pub fn entry_point(x: u32) -> (r: u32)
    requires x < 100,
    ensures r == x + 1,
{
    x + 1
}

fn caller() {
    let r = entry_point_called(3);
}

fn entry_point_called(x: u32) -> (r: u32)
    ensures r == x,
{
    x
}

pub assume_specification[ core::mem::swap::<u8> ](a: &mut u8, b: &mut u8);

global size_of usize == 8;

broadcast group group_of_lemmas {
    lemma_helper,
}

broadcast use group_of_lemmas;

pub trait Shape {
    spec fn area(&self) -> int;

    proof fn area_positive(&self)
        ensures self.area() >= 0;
}

impl<T: Copy> Shape for Wrapper<T> where T: Sized {
    open spec fn area(&self) -> int {
        0
    }

    proof fn area_positive(&self) {
    }
}

mod inner {
    pub fn in_module() {
        unsafe { }
    }

    mod deeper {
        #[verifier::external_body]
        fn deep() {
        }
    }
}

impl Point {
    #[verifier::external_body]
    pub fn method(&self) -> u32 {
        self.x
    }
}

tracked struct TrackedThing {
    v: u8,
}

ghost enum GhostChoice {
    A,
    B,
}

layout Point is size == 8, align == 4;

} // verus!

#[verifier::external_body]
fn outside_verus() {
}

pub fn plain_rust_function() -> u8 {
    unsafe { 0 }
}

macro_rules! plain_macro {
    () => { unsafe { } };
}

extern "C" {
    fn c_function(x: i32) -> i32;
}

unsafe impl Send for Point {}

static mut COUNTER: u32 = 0;

const LIMIT: u32 = 10;

type Alias = u32;
