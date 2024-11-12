// Copyright (C) 2018 Toitware ApS.
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

#include "top.h"
#include "flags.h"
#include <stdarg.h>
#ifdef TOIT_POSIX
#include <execinfo.h>
#include <unistd.h>
#include <cxxabi.h>
#include <dlfcn.h>
#endif

namespace toit {

void print_stacktrace() {
#ifdef TOIT_POSIX
  void* callstack[10];
  int frames = backtrace(callstack, 10);
  char** symbols = backtrace_symbols(callstack, frames);
  for (int i = 0; i < frames; i++) {
    Dl_info info;
    if (dladdr(callstack[i], &info)) {
      int status;
      char* demangled = abi::__cxa_demangle(info.dli_sname, NULL, 0, &status);
      const char* name = (status == 0) ? demangled : info.dli_sname;
      ptrdiff_t offset = (char*)callstack[i] - (char*)info.dli_saddr;
      fprintf(stderr, "%-3d %p %s + %td\n", i, callstack[i], name, offset);
      free(demangled);
    } else {
      fprintf(stderr, "%-3d %s\n", i, symbols[i]);
    }
  }
#endif
}

#ifndef TOIT_DEPLOY

void fail(const char* file, int line, const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  fprintf(stderr, "%s:%d: fatal: ", file, line);
  vfprintf(stderr, format, const_cast<va_list&>(arguments));
  fprintf(stderr, "\n");
  va_end(arguments);
  print_stacktrace();
  abort();
}

#else

void fail(const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  fprintf(stderr, "fatal: ");
  vfprintf(stderr, format, const_cast<va_list&>(arguments));
  fprintf(stderr, "\n");
  va_end(arguments);
  print_stacktrace();
  abort();
}

#endif

// Normally we don't allow throwing new to be called, because we compile with
// -fno-exceptions and we need to catch allocation failures on the device.
// However the compiler does a lot of 'new'-ing and does not run on the device
// so it gets to switch off this.
bool throwing_new_allowed = false;

}

#ifndef __SANITIZE_THREAD__

// Override new operator (normal version) so we can log allocations.
void* operator new(size_t size) {
  // We should not call this since the constructor will fail with a null
  // pointer exception when allocation fails.  Use _new which will call the
  // nothrow version instead, which skips the constructor when allocation
  // fails.
  if (!toit::throwing_new_allowed) FATAL("Throwing new not allowed: %zu", size);
  return malloc(size);
}

// Override new operator (no-expections version) so we can log allocations.
void* operator new(size_t size, const std::nothrow_t& tag) {
  return malloc(size);
}

// Override new[] operator (normal version) so we can log allocations.
void* operator new[](size_t size) {
  // We should not call this since the constructor will fail with a null
  // pointer exception when allocation fails.  Use _new which will call the
  // nothrow version instead, which skips the constructor when allocation
  // fails.
  if (!toit::throwing_new_allowed) FATAL("Throwing new[] not allowed: %zu", size);
  return malloc(size);
}

// Override new[] operator (no-exceptions version) so we can log allocations.
void* operator new[](size_t size, const std::nothrow_t& tag) {
  return malloc(size);
}

// Override delete[] operator (no-exceptions version) so we can log allocations.
void operator delete[](void* ptr, const std::nothrow_t& tag) {
  free(ptr);
}

#endif
