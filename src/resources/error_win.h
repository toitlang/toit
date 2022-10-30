// Copyright (C) 2022 Toitware ApS.
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

#ifdef TOIT_WINDOWS
#include "windows.h"

#define WINDOWS_ERROR return windows_error(process)

namespace toit {
  HeapObject* windows_error(Process* process);
  HeapObject* windows_error(Process* process, DWORD error_number);
  void close_keep_errno(SOCKET socket);
  void close_handle_keep_errno(HANDLE handle);
}

#endif // TOIT_WINDOWS
