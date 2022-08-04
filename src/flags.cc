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

#include "flags.h"

namespace toit {

#ifdef TOIT_DEBUG
#define MATERIALIZE_DEBUG_FLAG(type, prefix, name, value, doc) type Flags::name = value;
#else
#define MATERIALIZE_DEBUG_FLAG(type, prefix, name, value, doc)
#endif

#define MATERIALIZE_DEPLOY_FLAG(type, prefix, name, value, doc) type Flags::name = value;

FLAGS_DO(MATERIALIZE_DEBUG_FLAG, MATERIALIZE_DEPLOY_FLAG)

#ifndef IOT_DEVICE

static bool is_valid_flag(const char* argument) {
  return (strncmp(argument, "-X", 2) == 0) && (strlen(argument) > 2);
}

static void print_flag_bool(const char* name, bool value, bool init, const char* doc) {
  printf(" - bool %s = %s\n", name, value ? "true" : "false");
}

static void print_flag_int(const char* name, int value, int init, const char* doc) {
  printf(" - int %s = %d\n", name, value);
}

static void print_flag_string(const char* name, const char* value, const char* init, const char* doc) {
  printf(" - string %s = '%s'\n", name, value);
}
#define XSTR(str) #str

#ifdef TOIT_DEBUG
#define PRINT_DEBUG_FLAG(type, prefix, name, value, doc) \
  print_flag_##prefix(XSTR(name), Flags::name, value, doc);
#else
#define PRINT_DEBUG_FLAG(type, prefix, name, value, doc)
#endif

#define PRINT_DEPLOY_FLAG(type, prefix, name, value, doc) \
  print_flag_##prefix(XSTR(name), Flags::name, value, doc);

void print_flags() {
  printf("List of command line flags:\n");
  FLAGS_DO(PRINT_DEBUG_FLAG, PRINT_DEPLOY_FLAG);
}

static bool flag_matches(const char* a, const char* b) {
  for (; *b != '\0'; a++, b++) {
    if ((*a != *b) && ((*a != '-') || (*b != '_'))) return false;
  }
  return (*a == '\0') || (*a == '=');
}

static bool process_flag_bool(const char* name_ptr, const char* value_ptr,
                              const char* name, bool* field) {
  // -Xname
  if (value_ptr == null) {
    if (flag_matches(name_ptr, name)) {
      *field = true;
      return true;
    }
    return false;
  }
  // -Xname=<boolean>
  if (flag_matches(name_ptr, name)) {
    if (strcmp(value_ptr, "false") == 0) {
      *field = false;
      return true;
    }
    if (strcmp(value_ptr, "true") == 0) {
      *field = true;
      return true;
    }
  }
  return false;
}

static bool process_flag_int(const char* name_ptr, const char* value_ptr,
                             const char* name, int* field) {
  // -Xname=<int>
  if (flag_matches(name_ptr, name)) {
    char* end;
    int value = strtol(value_ptr, &end, 10);
    if (*end == '\0') {
      *field = value;
      return true;
    }
  }
  return false;
}

static bool process_flag_string(const char* name_ptr, const char* value_ptr,
                                const char* name, const char** field) {
  // -Xname=<string>
  if (flag_matches(name_ptr, name)) {
    const char* value = value_ptr;
    *field = value;
    return true;
  }
  return false;
}

#ifdef TOIT_DEBUG
#define PROCESS_DEBUG_FLAG(type, prefix, name, value, doc)                \
  if (process_flag_##prefix(name_ptr, value_ptr, XSTR(name), &Flags::name)) \
    return;
#else
#define PROCESS_DEBUG_FLAG(type, prefix, name, value, doc)
#endif

#define PROCESS_DEPLOY_FLAG(type, prefix, name, value, doc)              \
  if (process_flag_##prefix(name_ptr, value_ptr, XSTR(name), &Flags::name)) \
    return;

static void process_argument(const char* argument) {
  const char* name_ptr = argument + 2;  // skip "-X"
  const char* equals_ptr = strchr(name_ptr, '=');
  const char* value_ptr = equals_ptr != null ? equals_ptr + 1 : null;

  FLAGS_DO(PROCESS_DEBUG_FLAG, PROCESS_DEPLOY_FLAG);
}

int Flags::process_args(int* argc, char** argv) {
  // Compute number of provided flag arguments.
  int number_of_flags = 0;
  for (int index = 1; index < *argc; index++) {
    if (is_valid_flag(argv[index])) number_of_flags++;
  }
  if (number_of_flags != 0) {
    int count = 1;
    for (int index = 1; index < *argc; index++) {
      if (is_valid_flag(argv[index])) {
        process_argument(argv[index]);
      } else {
        argv[count++] = argv[index];
      }
    }
    argv[count] = null;
    *argc = count;
  }
  return number_of_flags;
}
#endif

const char* Flags::program_name = null;

}
