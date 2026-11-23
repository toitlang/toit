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

// A minimal executable that keeps exactly what the VM uses of the Rust
// library (the core's run loop and the verifier's entry point), for size
// measurements after linker garbage collection (device_size.sh). Never run.

#include <stddef.h>
#include <stdint.h>

typedef uintptr_t uword;

uword toit_v2_run(void* context);
uword toit_vmverify_verify(const void* input, void* result);

// The C++ helpers the core calls (src/interpreter_v2.h) and the panic
// handler of the device runtime: stubs.
uword toit_v2_current_stack(void* p) { return 0; }
uword toit_v2_allocate_instance(void* p, uword c) { return 0; }
uword toit_v2_allocate_double(void* p, uint64_t b) { return 0; }
uword toit_v2_allocate_exception(void* p, uword v, uword k, const uword* w, uword c) { return 0; }
uword toit_v2_allocate_array(void* p, uword l, uword f) { return 0; }
uword toit_v2_grow_stack(void* p, uword n) { return 0; }
uword toit_v2_try_allocate_large_integer(void* p, int64_t v) { return 0; }
uword toit_v2_try_allocate_double(void* p, uint64_t b) { return 0; }
uword toit_v2_try_allocate_array(void* p, uword l, void* f) { return 0; }
uword toit_v2_try_allocate_string(void* p, uword l) { return 0; }
uword toit_v2_try_allocate_byte_array(void* p, uword l) { return 0; }
uword toit_v2_primitive(void* p, uword m, uword i, uword a, uword f, uword* r) { return 0; }
void toit_v2_report(void* p, uword k, uword b, uword d) {}
uword toit_v2_tracing(void* p) { return 0; }
void toit_vmverify_panic(const uint8_t* file, uword length) { for (;;) {} }

// Opaque inputs: the linker cannot drop either entry point.
volatile uword sink;
void* volatile context_pointer;
void* volatile input_pointer;
void* volatile result_pointer;

int main(void) {
  sink = toit_v2_run(context_pointer);
  sink = toit_vmverify_verify(input_pointer, result_pointer);
  return 0;
}
