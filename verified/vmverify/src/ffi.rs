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

//! TRUSTED: the C ABI (src/verifier_v2.h). The structs must match
//! `toit_vmverify_input` and `toit_vmverify_result` (checked by
//! verified/layout_check.cc).

#[cfg(feature = "std")]
use core::ffi::c_char;
use core::ffi::c_void;
use toit_verified_core::ffi::ProgramTables;
use crate::clock::Clock;
use crate::from_vm::{self, PrimitiveArities};
use crate::verify;

/// `toit_vmverify_input`.
#[repr(C)]
pub struct VerifyInput {
    /// The tables as `toit_v2_run` gets them, with the program's initial
    /// globals.
    pub program: *const ProgramTables,
    /// The VM's primitive table: per module the number of primitives, and
    /// all arities concatenated.
    pub prim_counts: *const u32,
    pub prim_module_count: usize,
    pub prim_arities: *const u8,
    pub prim_arities_length: usize,
    /// Non-zero: the trusted rules (HALT 2 and 3 allowed).
    pub trusted: usize,
    /// The shipped certificate (format/18-shipped-certificate.md), or null:
    /// then the inference computes one (hosts, the `infer` feature) or
    /// the program is rejected.
    pub certificate: *const u8,
    pub certificate_length: usize,
    /// Called with `progress_context` and the method index before each
    /// method of a shipped certificate is checked (in order, once per
    /// method), or null. The VM tells its scheduler that the verification,
    /// which runs inside one primitive, is making progress (README.md,
    /// "Install time"). It must not touch the program, its tables or the
    /// certificate.
    pub progress: Option<unsafe extern "C" fn(context: *mut c_void, method: usize)>,
    pub progress_context: *mut c_void,
}

/// The VM's progress callback (`VerifyInput::progress`) as the checker's
/// `Progress` (toit_spec::progress).
#[derive(Clone, Copy)]
pub struct VmProgress {
    callback: Option<unsafe extern "C" fn(context: *mut c_void, method: usize)>,
    context: *mut c_void,
}

impl toit_spec::progress::Progress for VmProgress {
    fn method(&mut self, m: usize) {
        // SAFETY: the VM's callback with the context it passed (VerifyInput).
        if let Some(f) = self.callback { unsafe { f(self.context, m) } }
    }
}

pub const MESSAGE_SIZE: usize = 200;

/// `toit_vmverify_result`.
#[repr(C)]
pub struct VerifyResult {
    pub code: usize,
    /// The rejected method (index into the method table) and the offset of
    /// the rejected instruction from its entry, or -1.
    pub method: isize,
    pub offset: isize,
    /// Program-heap objects reachable from the roots, globals and literals.
    pub objects: usize,
    pub convert_ns: u64,
    pub heap_ns: u64,
    pub infer_ns: u64,
    pub check_ns: u64,
    /// High-water mark of the Rust heap during the call, above its level at
    /// entry (approximate when other threads allocate meanwhile).
    pub peak_bytes: usize,
    /// NUL-terminated reason.
    pub message: [u8; MESSAGE_SIZE],
}

fn set_message(r: &mut VerifyResult, text: &str) {
    // Truncated to the buffer, NUL-terminated (no slicing: no panic path).
    let mut n = 0;
    for (d, s) in r.message.iter_mut().take(MESSAGE_SIZE - 1).zip(text.bytes()) {
        *d = s;
        n += 1;
    }
    if let Some(d) = r.message.get_mut(n) { *d = 0; }
}

unsafe fn arities<'a>(i: &VerifyInput) -> PrimitiveArities<'a> {
    let counts = if i.prim_module_count == 0 { &[][..] } else { core::slice::from_raw_parts(i.prim_counts, i.prim_module_count) };
    let arities = if i.prim_arities_length == 0 { &[][..] } else { core::slice::from_raw_parts(i.prim_arities, i.prim_arities_length) };
    PrimitiveArities { counts, arities }
}

/// Verifies the program described by `input`. Returns the result code
/// (also in `result`). On hosts (`std`) a panic of the verifier rejects
/// the program (`INTERNAL`); without `std` there is no unwinding and a
/// panic aborts (the inference is total: PHASE4-REQUESTS.md R6).
///
/// # Safety
/// `input` and `result` must be valid; see `from_vm::convert` for the
/// tables.
#[no_mangle]
pub unsafe extern "C" fn toit_vmverify_verify(input: *const VerifyInput, result: *mut VerifyResult) -> usize {
    let input = &*input;
    let r = &mut *result;
    r.code = verify::INTERNAL;
    r.method = -1;
    r.offset = -1;
    r.objects = 0;
    r.convert_ns = 0;
    r.heap_ns = 0;
    r.infer_ns = 0;
    r.check_ns = 0;
    r.peak_bytes = 0;
    set_message(r, "verifier failed");
    #[cfg(feature = "std")]
    let base = crate::counting::start_peak();
    #[cfg(feature = "std")]
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run(input))).ok();
    #[cfg(not(feature = "std"))]
    let outcome = Some(run(input));
    #[cfg(feature = "std")]
    { r.peak_bytes = crate::counting::peak_since(base); }
    if let Some((v, objects, convert_ns)) = outcome {
        r.code = v.code;
        r.method = v.method;
        r.offset = v.offset;
        r.objects = objects;
        r.convert_ns = convert_ns;
        r.heap_ns = v.heap_ns;
        r.infer_ns = v.infer_ns;
        r.check_ns = v.check_ns;
        set_message(r, &v.message);
    }
    r.code
}

/// The conversion and the verdict: (verdict, objects, conversion time).
unsafe fn run(input: &VerifyInput) -> (verify::Verdict, usize, u64) {
    let t = Clock::start();
    let converted = from_vm::convert(&*input.program, &arities(input));
    mem_trace!("converted (roots, globals, literals, primitive table)");
    let convert_ns = t.ns();
    match converted {
        Err(e) if e.oom => (verify::Verdict::out_of_memory(), 0, convert_ns),
        Err(e) => {
            let v = verify::Verdict::new(verify::MALFORMED, text!("malformed program memory", "{} ({})", e.what, e.detail));
            (v, 0, convert_ns)
        }
        Ok(mut converted) => {
            let cert = if input.certificate.is_null() { None } else {
                Some(core::slice::from_raw_parts(input.certificate, input.certificate_length))
            };
            let progress = VmProgress { callback: input.progress, context: input.progress_context };
            let v = verify::verify(&mut converted, input.trusted != 0, cert, progress);
            (v, converted.objects.count(), convert_ns)
        }
    }
}

/// Writes the canonical form (canonical.rs) of the program described by
/// `input` to the file `path`. Returns 0 on success, 1 if the memory could
/// not be converted, 2 if the file could not be written. Test support for
/// verified/tools/vmverify_differential.toit. A path ending in `.tables`
/// gets the raw input instead (tables.rs, for the fuzz driver).
///
/// # Safety
/// As `toit_vmverify_verify`; `path` must be a NUL-terminated string.
#[cfg(feature = "std")]
#[no_mangle]
pub unsafe extern "C" fn toit_vmverify_canonical(input: *const VerifyInput, path: *const c_char) -> usize {
    let input = &*input;
    let path = match core::ffi::CStr::from_ptr(path).to_str() {
        Ok(p) => p.to_string(),
        Err(_) => return 2,
    };
    if path.ends_with(".tables") {
        // The raw input, for the in-process fuzz driver (tables.rs).
        return if crate::tables::save(input, &path).is_ok() { 0 } else { 2 };
    }
    match from_vm::convert(&*input.program, &arities(input)) {
        Err(e) => {
            eprintln!("cannot convert the program: {} ({})", e.what, e.detail);
            1
        }
        Ok(mut c) => {
            let heap = match c.collect_heap() {
                Ok(heap) => heap,
                Err(e) => {
                    eprintln!("cannot convert the program: {} ({})", e.what, e.detail);
                    return 1;
                }
            };
            let text = crate::canonical::canonical(&c.program(), &heap, &c.globals, &c.prim_arity);
            if std::fs::write(&path, text).is_ok() { 0 } else { 2 }
        }
    }
}

// The layout check's tables (verified/layout_check.cc) exist on hosts only
// (`std`): the check does not run for devices, and as exports of the static
// library their names would stay in the firmware's merged string section,
// which the linker cannot garbage-collect.
macro_rules! layout_entries {
    ($($name:expr => $value:expr),* $(,)?) => {
        #[cfg(feature = "std")]
        const LAYOUT: &[(&[u8], usize)] = &[$(($name, $value),)*];
    };
}

layout_entries!(
    b"VMVERIFY_INPUT_SIZE\0" => core::mem::size_of::<VerifyInput>(),
    b"VMVERIFY_INPUT_program\0" => core::mem::offset_of!(VerifyInput, program),
    b"VMVERIFY_INPUT_prim_counts\0" => core::mem::offset_of!(VerifyInput, prim_counts),
    b"VMVERIFY_INPUT_prim_module_count\0" => core::mem::offset_of!(VerifyInput, prim_module_count),
    b"VMVERIFY_INPUT_prim_arities\0" => core::mem::offset_of!(VerifyInput, prim_arities),
    b"VMVERIFY_INPUT_prim_arities_length\0" => core::mem::offset_of!(VerifyInput, prim_arities_length),
    b"VMVERIFY_INPUT_trusted\0" => core::mem::offset_of!(VerifyInput, trusted),
    b"VMVERIFY_INPUT_certificate\0" => core::mem::offset_of!(VerifyInput, certificate),
    b"VMVERIFY_INPUT_certificate_length\0" => core::mem::offset_of!(VerifyInput, certificate_length),
    b"VMVERIFY_INPUT_progress\0" => core::mem::offset_of!(VerifyInput, progress),
    b"VMVERIFY_INPUT_progress_context\0" => core::mem::offset_of!(VerifyInput, progress_context),
    b"VMVERIFY_RESULT_SIZE\0" => core::mem::size_of::<VerifyResult>(),
    b"VMVERIFY_RESULT_code\0" => core::mem::offset_of!(VerifyResult, code),
    b"VMVERIFY_RESULT_method\0" => core::mem::offset_of!(VerifyResult, method),
    b"VMVERIFY_RESULT_offset\0" => core::mem::offset_of!(VerifyResult, offset),
    b"VMVERIFY_RESULT_objects\0" => core::mem::offset_of!(VerifyResult, objects),
    b"VMVERIFY_RESULT_convert_ns\0" => core::mem::offset_of!(VerifyResult, convert_ns),
    b"VMVERIFY_RESULT_heap_ns\0" => core::mem::offset_of!(VerifyResult, heap_ns),
    b"VMVERIFY_RESULT_infer_ns\0" => core::mem::offset_of!(VerifyResult, infer_ns),
    b"VMVERIFY_RESULT_check_ns\0" => core::mem::offset_of!(VerifyResult, check_ns),
    b"VMVERIFY_RESULT_peak_bytes\0" => core::mem::offset_of!(VerifyResult, peak_bytes),
    b"VMVERIFY_RESULT_message\0" => core::mem::offset_of!(VerifyResult, message),
    b"VMVERIFY_MESSAGE_SIZE\0" => MESSAGE_SIZE,
    b"VMVERIFY_ACCEPTED\0" => verify::ACCEPTED,
    b"VMVERIFY_MALFORMED\0" => verify::MALFORMED,
    b"VMVERIFY_HEAP\0" => verify::HEAP,
    b"VMVERIFY_TABLES\0" => verify::TABLES,
    b"VMVERIFY_METHOD\0" => verify::METHOD,
    b"VMVERIFY_INTERNAL\0" => verify::INTERNAL,
    b"VMVERIFY_CERTIFICATE\0" => verify::CERTIFICATE,
    b"VMVERIFY_NO_CERTIFICATE\0" => verify::NO_CERTIFICATE,
    b"VMVERIFY_OUT_OF_MEMORY\0" => verify::OUT_OF_MEMORY,
);

/// The number of layout entries (for verified/layout_check.cc).
#[cfg(feature = "std")]
#[no_mangle]
pub extern "C" fn toit_vmverify_layout_count() -> usize {
    LAYOUT.len()
}

/// Layout entry `i`: its name and value. False if `i` is out of range.
///
/// # Safety
/// `name` and `value` must be valid for writes.
#[cfg(feature = "std")]
#[no_mangle]
pub unsafe extern "C" fn toit_vmverify_layout_entry(i: usize, name: *mut *const c_char, value: *mut usize) -> bool {
    match LAYOUT.get(i) {
        Some((n, v)) => {
            *name = n.as_ptr() as *const c_char;
            *value = *v;
            true
        }
        None => false,
    }
}

/// The arity of primitive `index` of `module` in the verifier's generated
/// table (v2::prim_arity::PRIM_TABLE), or -1: compared against the VM's
/// table by the layout check.
#[cfg(feature = "std")]
#[no_mangle]
pub extern "C" fn toit_vmverify_generated_arity(module: usize, index: usize) -> isize {
    let table = toit_spec::v2::prim_arity::PRIM_TABLE;
    match table.get(module).and_then(|(_, prims)| prims.get(index)) {
        Some((_, a)) => *a as isize,
        None => -1,
    }
}

/// Computes the certificate of the program described by `input` (the
/// inference, `v2::encode`) and checks it with the proven checker of
/// shipped certificates (`v2::cert::verify_shipped`). On success returns 0
/// and sets `*bytes`/`*length` to the certificate, which the caller frees
/// with `toit_vmverify_free_certificate`; returns 1 if the memory could not
/// be converted, 2 if no accepted certificate was found. Host only (the
/// `infer` feature): the toolchain's producer of shipped certificates
/// (format/18-shipped-certificate.md).
///
/// # Safety
/// As `toit_vmverify_verify`; `bytes` and `length` must be writable.
#[cfg(feature = "infer")]
#[no_mangle]
pub unsafe extern "C" fn toit_vmverify_certify(input: *const VerifyInput, bytes: *mut *mut u8, length: *mut usize) -> usize {
    let input = &*input;
    *bytes = core::ptr::null_mut();
    *length = 0;
    let mut c = match from_vm::convert(&*input.program, &arities(input)) {
        Err(_) => return 1,
        Ok(c) => c,
    };
    let global_count = c.globals.len() as u64;
    let prim_arity = c.prim_arity.clone();
    let (mut p, _) = c.split();
    let trusted = input.trusted != 0;
    p.unchecked = trusted;
    match toit_spec::v2::encode::certify(&p, global_count, prim_arity.clone(), trusted) {
        Err(_) => 2,
        Ok((cert, _)) => {
            let ok = matches!(toit_spec::v2::cert::verify_shipped(&p, &cert, global_count, &prim_arity, trusted), Ok((true, _, _)));
            if !ok { return 2; }
            let boxed = cert.into_boxed_slice();
            *length = boxed.len();
            *bytes = alloc::boxed::Box::into_raw(boxed) as *mut u8;
            0
        }
    }
}

/// Frees a certificate returned by `toit_vmverify_certify`.
///
/// # Safety
/// `bytes`/`length` must come from `toit_vmverify_certify`.
#[cfg(feature = "infer")]
#[no_mangle]
pub unsafe extern "C" fn toit_vmverify_free_certificate(bytes: *mut u8, length: usize) {
    if bytes.is_null() { return; }
    drop(alloc::boxed::Box::from_raw(core::ptr::slice_from_raw_parts_mut(bytes, length)));
}
