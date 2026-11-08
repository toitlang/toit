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

//! TRUSTED: C ABI glue. Not processed by Verus. The struct layout must
//! match `src/verified_core.h`.

use crate::exec::{self, Env, Outcome, VState};
use crate::layout::*;
use crate::view::{CodeView, DispatchView, RoomOracle, StackView};
use core::sync::atomic::AtomicUsize;

#[repr(C)]
pub struct VcoreState {
    pub stack_limit: *mut usize,
    pub stack_len: usize,
    pub sp: usize,
    pub try_sp: usize,
    pub code: *const u8,
    pub code_len: usize,
    pub bcp: usize,
    pub dispatch: *const i32,
    pub dispatch_len: usize,
    pub frame_marker: usize,
    pub watermark: *const AtomicUsize,
    pub preempt_a_lot: usize,
    pub fuel: usize,
    /// Out: number of instructions the core executed.
    pub steps: usize,
}

pub const VCORE_STOP: usize = 0;
pub const VCORE_TRAP: usize = 1;

/// Runs covered opcodes starting at `state.bcp`. Updates `sp`, `try_sp`
/// and `bcp` in place.
///
/// # Safety
/// See TRUSTED.md, "FFI entry".
#[no_mangle]
pub unsafe extern "C" fn toit_vcore_run(state: *mut VcoreState) -> usize {
    let s = &mut *state;
    let mut st = VState {
        stack: StackView::from_raw(s.stack_limit, s.stack_len),
        sp: s.sp,
        try_sp: s.try_sp,
        bcp: s.bcp,
    };
    let env = Env {
        code: CodeView::from_raw(s.code, s.code_len),
        dispatch: DispatchView::from_raw(s.dispatch, s.dispatch_len),
        code_base: s.code as usize,
        frame_marker: s.frame_marker,
        preempt_a_lot: s.preempt_a_lot != 0,
        room: RoomOracle::from_raw(s.stack_limit, s.watermark),
    };
    let (r, steps) = exec::entry(&mut st, &env, s.fuel);
    s.steps = steps;
    s.sp = st.sp;
    s.try_sp = st.try_sp;
    s.bcp = st.bcp;
    match r {
        Outcome::Trap => VCORE_TRAP,
        _ => VCORE_STOP,
    }
}

/// Whether the core executes `op` (used by the C++ hook and the layout
/// check).
#[no_mangle]
pub extern "C" fn toit_vcore_covers(op: u8) -> bool {
    exec::covers_exec(op)
}

/// The core's Method::max_height() (used by the layout check).
#[no_mangle]
pub extern "C" fn toit_vcore_max_height(kind_height: u8) -> usize {
    exec::method_max_height(kind_height)
}

macro_rules! layout_table {
    ($($name:ident),* $(,)?) => {
        const LAYOUT: &[(&[u8], usize)] = &[
            $((concat!(stringify!($name), "\0").as_bytes(), $name as usize),)*
        ];
    };
}

layout_table!(
    FRAME_SIZE, FRAME_MARKER_SLOT, RETURN_ADDRESS_SLOT,
    LINK_REASON_SLOT, LINK_TARGET_SLOT, LINK_RESULT_SLOT, LINK_WORDS,
    SMI_TAG_SIZE, SMI_TAG_MASK, SMI_TAG, SMI_SCALE,
    SMI_LINK_RESULT_INIT, SMI_LINK_TARGET_INIT, SMI_LINK_REASON_INIT,
    BLOCK_SALT,
    METHOD_KIND_HEIGHT_OFFSET, METHOD_KIND_BITS_DIVISOR, METHOD_HEIGHT_SCALE, METHOD_ENTRY_OFFSET,
    OP_LOAD_LOCAL, OP_LOAD_LOCAL_WIDE, OP_STORE_LOCAL, OP_LOAD_OUTER, OP_STORE_OUTER,
    OP_LOAD_LOCAL_0, OP_LOAD_LOCAL_1, OP_LOAD_LOCAL_2, OP_LOAD_LOCAL_3, OP_LOAD_LOCAL_4,
    OP_LOAD_LOCAL_5, OP_LOAD_SMI_U8, OP_POP, OP_POP_1, OP_INVOKE_STATIC, OP_RETURN,
    OP_NON_LOCAL_RETURN, OP_NON_LOCAL_RETURN_WIDE, OP_LINK, OP_UNLINK,
    LEN_LOAD_LOCAL, LEN_LOAD_LOCAL_WIDE, LEN_STORE_LOCAL, LEN_LOAD_OUTER, LEN_STORE_OUTER,
    LEN_LOAD_LOCAL_N, LEN_LOAD_SMI_U8, LEN_POP, LEN_POP_1, LEN_INVOKE_STATIC, LEN_RETURN,
    LEN_NON_LOCAL_RETURN, LEN_NON_LOCAL_RETURN_WIDE, LEN_LINK, LEN_UNLINK,
);

/// The C ABI of `VcoreState`, checked against `toit_vcore_state` in
/// src/verified_core.h.
const STATE_LAYOUT: &[(&[u8], usize)] = &[
    (b"STATE_SIZE\0", core::mem::size_of::<VcoreState>()),
    (b"STATE_OFFSET_stack_limit\0", core::mem::offset_of!(VcoreState, stack_limit)),
    (b"STATE_OFFSET_stack_len\0", core::mem::offset_of!(VcoreState, stack_len)),
    (b"STATE_OFFSET_sp\0", core::mem::offset_of!(VcoreState, sp)),
    (b"STATE_OFFSET_try_sp\0", core::mem::offset_of!(VcoreState, try_sp)),
    (b"STATE_OFFSET_code\0", core::mem::offset_of!(VcoreState, code)),
    (b"STATE_OFFSET_code_len\0", core::mem::offset_of!(VcoreState, code_len)),
    (b"STATE_OFFSET_bcp\0", core::mem::offset_of!(VcoreState, bcp)),
    (b"STATE_OFFSET_dispatch\0", core::mem::offset_of!(VcoreState, dispatch)),
    (b"STATE_OFFSET_dispatch_len\0", core::mem::offset_of!(VcoreState, dispatch_len)),
    (b"STATE_OFFSET_frame_marker\0", core::mem::offset_of!(VcoreState, frame_marker)),
    (b"STATE_OFFSET_watermark\0", core::mem::offset_of!(VcoreState, watermark)),
    (b"STATE_OFFSET_preempt_a_lot\0", core::mem::offset_of!(VcoreState, preempt_a_lot)),
    (b"STATE_OFFSET_fuel\0", core::mem::offset_of!(VcoreState, fuel)),
    (b"STATE_OFFSET_steps\0", core::mem::offset_of!(VcoreState, steps)),
    (b"VCORE_STOP\0", VCORE_STOP),
    (b"VCORE_TRAP\0", VCORE_TRAP),
    (b"WORD_SIZE\0", core::mem::size_of::<usize>()),
];

/// Number of layout entries.
#[no_mangle]
pub extern "C" fn toit_vcore_layout_count() -> usize {
    LAYOUT.len() + STATE_LAYOUT.len()
}

/// Layout entry `i`: writes its NUL-terminated name and value. Returns false
/// if `i` is out of range.
///
/// # Safety
/// `name` and `value` must be valid for writes.
#[no_mangle]
pub unsafe extern "C" fn toit_vcore_layout_entry(i: usize, name: *mut *const u8, value: *mut usize) -> bool {
    let entry = if i < LAYOUT.len() { LAYOUT.get(i) } else { STATE_LAYOUT.get(i - LAYOUT.len()) };
    match entry {
        None => false,
        Some((n, v)) => {
            *name = n.as_ptr();
            *value = *v;
            true
        }
    }
}
