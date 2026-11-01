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

#include "native_build.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <fstream>
#include <sstream>
#include <vector>

#include "../flags.h"
#include "../snapshot_bundle.h"
#include "../top.h"

#include "filesystem_local.h"
#include "util.h"

#ifndef TOIT_WINDOWS
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char** environ;
#endif

namespace toit {
namespace compiler {

#ifdef TOIT_WINDOWS

NativeBuild::~NativeBuild() {}

bool NativeBuild::prepare(bool needs_sdk) {
  fprintf(stderr, "Native code isn't supported on this platform\n");
  return false;
}

int NativeBuild::create_executable(const char* out_path, SnapshotBundle bundle) {
  return -1;
}

int NativeBuild::write_source(const char* out_path, SnapshotBundle bundle, bool is_boot) {
  return -1;
}

#else

// The name of the file in the SDK. It has the flags for
// compiling on the first line and the ones for linking on the second.
static const char* FLAGS_FILE = "native.flags";
// Marks the flags that are files in the SDK.
static const char* SDK_PREFIX = "@SDK@/";

// The compiler exits directly if the program has errors.
static NativeBuild* active_build = null;
// The compiler can do its work in a forked process, which must leave the folder alone.
static pid_t active_build_pid = 0;

static const char* cxx_compiler() {
  const char* compiler = getenv("TOIT_CXX");
  return (compiler != null && compiler[0] != '\0') ? compiler : "clang++";
}

static void add_flags(const std::string& line, const std::string& sdk_folder, std::vector<std::string>* result) {
  std::istringstream stream(line);
  std::string flag;
  size_t prefix_length = strlen(SDK_PREFIX);
  while (stream >> flag) {
    if (flag.compare(0, prefix_length, SDK_PREFIX) == 0) {
      flag = sdk_folder + "/" + flag.substr(prefix_length);
    }
    result->push_back(flag);
  }
}

// Returns the exit code of the command or -1.
static int run_command(const std::vector<std::string>& command) {
  std::vector<char*> argv;
  for (auto& argument : command) argv.push_back(const_cast<char*>(argument.c_str()));
  argv.push_back(null);
  pid_t pid;
  if (posix_spawnp(&pid, argv[0], null, null, argv.data(), environ) != 0) return -1;
  int status = 0;
  do {
    if (waitpid(pid, &status, 0) == -1) return -1;
  } while (!WIFEXITED(status) && !WIFSIGNALED(status));
  if (!WIFEXITED(status)) return -1;
  // The shell convention for commands that weren't found. A
  // 'posix_spawnp' implementation is allowed to report it this way.
  if (WEXITSTATUS(status) == 127) return -1;
  return WEXITSTATUS(status);
}

NativeBuild::~NativeBuild() {
  remove_temp_folder();
  active_build = null;
}

void NativeBuild::remove_temp_folder() {
  if (temp_folder_.empty()) return;
  unlink(code_path_.c_str());
  rmdir(temp_folder_.c_str());
  temp_folder_.clear();
}

void NativeBuild::remove_active_temp_folder() {
  if (active_build != null && getpid() == active_build_pid) active_build->remove_temp_folder();
}

bool NativeBuild::prepare(bool needs_sdk) {
  if (Flags::native != null) {
    fprintf(stderr, "The --native flag can't be combined with -Xnative\n");
    return false;
  }
  FilesystemLocal fs;
  PathBuilder builder(&fs);
  builder.join(fs.sdk_path(), "lib", "toit", "native");
  sdk_folder_ = builder.buffer();
  std::string flags_path = sdk_folder_ + "/" + FLAGS_FILE;
  if (needs_sdk && access(flags_path.c_str(), R_OK) != 0) {
    fprintf(stderr, "This SDK doesn't support native code (missing '%s')\n", flags_path.c_str());
    return false;
  }
  const char* temp = getenv("TMPDIR");
  std::string pattern = std::string((temp != null && temp[0] != '\0') ? temp : "/tmp") + "/toit-native-XXXXXX";
  std::vector<char> buffer(pattern.begin(), pattern.end());
  buffer.push_back('\0');
  if (mkdtemp(buffer.data()) == null) {
    perror("mkdtemp");
    return false;
  }
  temp_folder_ = buffer.data();
  active_build = this;
  active_build_pid = getpid();
  atexit(&NativeBuild::remove_active_temp_folder);
  code_path_ = temp_folder_ + "/code.cc";
  Flags::native = strdup(code_path_.c_str());
  return true;
}

// The format is the one that is used for patching vessels: the size of
// the bundle followed by the bundle. All characters are escaped, so
// the size of the literal doesn't matter much to the C++ compiler.
bool NativeBuild::add_snapshot(SnapshotBundle bundle, bool is_boot) {
  FILE* file = fopen(code_path_.c_str(), "ab");
  if (file == null) {
    perror(code_path_.c_str());
    return false;
  }
  int size = bundle.size();
  if (is_boot) {
    // The system program takes the place of the snapshot the executables boot from.
    fprintf(file, "\nextern \"C\" unsigned int toit_run_snapshot_len;\n");
    fprintf(file, "unsigned int toit_run_snapshot_len = %d;\n", size);
    fprintf(file, "extern \"C\" unsigned char toit_run_snapshot[];\n");
    fprintf(file, "unsigned char toit_run_snapshot[] =\n\"");
  } else {
    fprintf(file, "\nunsigned char vessel_snapshot_data[] =\n\"");
    for (int i = 0; i < 4; i++) fprintf(file, "\\%03o", (size >> (i * 8)) & 0xff);
  }
  for (int i = 0; i < size; i++) {
    if ((i & 0x3f) == 0) fprintf(file, "\"\n\"");
    fprintf(file, "\\%03o", bundle.buffer()[i]);
  }
  fprintf(file, "\";\n");
  return fclose(file) == 0;
}

int NativeBuild::write_source(const char* out_path, SnapshotBundle bundle, bool is_boot) {
  if (!add_snapshot(bundle, is_boot)) return -1;
  std::ifstream source(code_path_, std::ios::binary);
  std::ofstream output(out_path, std::ios::binary);
  output << source.rdbuf();
  output.close();
  if (!output) {
    fprintf(stderr, "Unable to write '%s'\n", out_path);
    return -1;
  }
  return 0;
}

int NativeBuild::create_executable(const char* out_path, SnapshotBundle bundle) {
  if (!add_snapshot(bundle, false)) return -1;
  std::ifstream flags_file(sdk_folder_ + "/" + FLAGS_FILE);
  std::string compile_flags;
  std::string link_flags;
  if (!std::getline(flags_file, compile_flags) || !std::getline(flags_file, link_flags)) {
    fprintf(stderr, "Invalid file '%s/%s'\n", sdk_folder_.c_str(), FLAGS_FILE);
    return -1;
  }

  std::vector<std::string> command;
  command.push_back(cxx_compiler());
  add_flags(compile_flags, sdk_folder_, &command);
  // The generated code marks everything but the hot code as optimize-for-size.
  command.push_back("-O2");
  command.push_back(code_path_);
  command.push_back("-o");
  command.push_back(out_path);
  add_flags(link_flags, sdk_folder_, &command);

  int result = run_command(command);
  if (result == 0) return 0;
  unlink(out_path);
  fprintf(stderr, "Unable to build native code with '%s'. It needs a compiler with guaranteed tail\n"
                  "calls, like a recent clang. Use TOIT_CXX to select one.\n", cxx_compiler());
  return result == -1 ? 1 : result;
}

#endif  // TOIT_WINDOWS

} // namespace toit::compiler
} // namespace toit
