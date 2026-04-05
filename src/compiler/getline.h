// Copyright (C) 2026 Toitware ApS.
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

#pragma once

#include "../top.h"

// Portable implementation of POSIX getline(3), testable on all platforms.
//
// Reads a line from 'stream' into the buffer at '*lineptr' (of size '*n'),
// growing it as needed. Returns the number of characters read (including the
// newline), or (size_t)-1 on error/EOF.
size_t toit_getline(char** lineptr, size_t* n, FILE* stream);
