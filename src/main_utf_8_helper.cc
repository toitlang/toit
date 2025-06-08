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

  // Convert wide char arguments to UTF-8 arguments.
  char** utf_8_argv = toit::unvoid_cast<char**>(malloc(sizeof(char*) * (argc + 1)));
  utf_8_argv[argc] = null;
  for (int i = 0; i < argc; ++i) {
    uword total_len = toit::Utils::utf_16_to_8(wargv[i], wcslen(wargv[i]));
    char* utf_8_arg = toit::unvoid_cast<char*>(malloc(total_len + 1));  // +1 for null terminator.
    toit::Utils::utf_16_to_8(wargv[i], wcslen(wargv[i]), reinterpret_cast<uint8*>(utf_8_arg), total_len);
    utf_8_arg[total_len] = '\0';  // Null-terminate the string.
    utf_8_argv[i] = utf_8_arg;
  }
  LocalFree(wargv);

  int exit_state = main_func(argc, utf_8_argv);
  // Free the converted arguments.
  for (int i = 0; i < argc; ++i) {
    free(utf_8_argv[i]);
  }
  free(utf_8_argv);
  return exit_state;
}

#endif  // TOIT_WINDOWS
