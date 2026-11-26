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

// Stand-ins for the page source and the panic hook, so that the no-panic
// check links (check.sh). toit_gc_panic is kept only if the panic handler
// is reachable, which the check forbids.

#include <stddef.h>
#include <stdbool.h>

bool toit_gc_page_reserve(size_t n) { return n < 1000; }
size_t toit_gc_page_take(void) { return 0x1000; }
void toit_gc_page_release(void) {}
void toit_gc_panic(void) { for (;;) {} }
