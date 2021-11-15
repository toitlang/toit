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

#include "../top.h"

#ifdef TOIT_BSD

#include <sys/param.h>
#include <libgen.h>
#include <unistd.h>
#include <errno.h>
#include <libproc.h>

#include "filesystem_local.h"

namespace toit {
namespace compiler {

char* FilesystemLocal::get_executable_path() {
  pid_t pid = getpid();
  char* path = _new char[PROC_PIDPATHINFO_MAXSIZE];
  if (proc_pidpath(pid, path, PROC_PIDPATHINFO_MAXSIZE) <= 0) {
    FATAL("failure reading executable path: %d", errno);
  }
  return path;
}

} // namespace toit::compiler
} // namespace toit

#endif // TOIT_LINUX
