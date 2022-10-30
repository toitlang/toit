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

#include "../top.h"

#ifdef TOIT_WINDOWS
#include "windows.h"
#include "../objects.h"
#include "../objects_inline.h"

namespace toit {

HeapObject* windows_error(Process* process, DWORD error_number) {
  LPVOID lpMsgBuf;
  FormatMessage(
      FORMAT_MESSAGE_ALLOCATE_BUFFER |
      FORMAT_MESSAGE_FROM_SYSTEM |
      FORMAT_MESSAGE_IGNORE_INSERTS,
      NULL,
      error_number,
      MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
      (LPTSTR) &lpMsgBuf,
      0, NULL );
  if (lpMsgBuf) {
    String* error = process->allocate_string((LPCTSTR) lpMsgBuf);
    free(lpMsgBuf);
    if (error == null) ALLOCATION_FAILED;
    return Primitive::mark_as_error(error);
  } else {
    char buf[80];
    snprintf(buf, 80, "Low-level win32 error: %lu", error_number);
    String* error = process->allocate_string(buf);
    if (error == null) ALLOCATION_FAILED;
    return Primitive::mark_as_error(error);
  }
}

HeapObject* windows_error(Process* process) {
  return windows_error(process, GetLastError());
}

void close_keep_errno(SOCKET socket) {
  DWORD err = GetLastError();
  closesocket(socket);
  SetLastError(err);
}

void close_handle_keep_errno(HANDLE handle) {
  DWORD err = GetLastError();
  CloseHandle(handle);
  SetLastError(err);
}

}

#endif // TOIT_WINDOWS
