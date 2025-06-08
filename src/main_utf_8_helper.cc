// Copyright (C) 2025 Toit contributors.
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
#include "main_utf_8_helper.h"

#ifndef TOIT_WINDOWS

// For non-Windows platforms, we can directly use the standard main function.
int run_with_utf_8_args(int (*main_func)(int, char**), int argc, char** argv) {
  return main_func(argc, argv);
}

#else

#include <windows.h>
#include "utils.h"

int run_with_utf_8_args(int (*main_func)(int, char**), int argc, char** argv) {
  // The argv are in local code page, so we don't use them.
  // Instead we use the wide character command line arguments accessible via GetCommandLineW.
  LPWSTR cmdLineW = GetCommandLineW();
  int wargc;
  LPWSTR* wargv = CommandLineToArgvW(cmdLineW, &wargc);

  // According to the internet, argc and wargc might differ. So we use wargc from now on.
  // Convert wide char arguments to UTF-8 arguments.
  // Since the callee may change the argv, we keep a copy of the UTF-8 arguments.
  char** utf_8_args = toit::unvoid_cast<char**>(malloc(sizeof(char*) * (wargc + 1)));
  char** utf_8_copy = toit::unvoid_cast<char**>(malloc(sizeof(char*) * (wargc + 1)));
  utf_8_args[wargc] = null;
  for (int i = 0; i < wargc; ++i) {
    uword total_len = toit::Utils::utf_16_to_8(wargv[i], wcslen(wargv[i]));
    char* utf_8_arg = toit::unvoid_cast<char*>(malloc(total_len + 1));  // +1 for null terminator.
    toit::Utils::utf_16_to_8(wargv[i], wcslen(wargv[i]), reinterpret_cast<uint8*>(utf_8_arg), total_len);
    utf_8_arg[total_len] = '\0';  // Null-terminate the string.
    utf_8_args[i] = utf_8_arg;  // Keep a copy.
    utf_8_copy[i] = utf_8_arg;
  }
  LocalFree(wargv);

  int exit_state = main_func(wargc, utf_8_args);
  // Free the converted arguments.
  for (int i = 0; i < wargc; ++i) {
    free(utf_8_copy[i]);
  }
  free(utf_8_args);
  free(utf_8_copy);
  return exit_state;
}

#endif  // TOIT_WINDOWS
