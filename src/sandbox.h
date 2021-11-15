// Copyright (C) 2020 Toitware ApS.
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

namespace toit {

// Calls that are allowed for the compiler.
const int ALLOW_COMPILER_CALLS = 1;

// Calls that are allowed for a demo Toit VM running in a sandbox
const int ALLOW_SANDBOX_CALLS = 2;

// Most regular calls.  If you enable this set you have no extra security, but
// it may help identify a program that performs "unusual" syscalls.
const int ALLOW_MOST_CALLS = 4;

// Or flags to indicate which syscalls you want to allow.  Aborts on failure,
// returns on success.
void enable_sandbox(int flags);

}
