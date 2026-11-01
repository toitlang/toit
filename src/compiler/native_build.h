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

#pragma once

#include <string>

#include "../snapshot_bundle.h"

namespace toit {

namespace compiler {

// Builds an executable from a program that is compiled to C++.
//
// The SDK has the headers, the libraries and the flags for this in its
// 'lib/toit/native' folder. Building the executable needs a C++ compiler that
// guarantees tail calls. It is clang++, unless the TOIT_CXX environment
// variable says something else.
class NativeBuild {
 public:
  ~NativeBuild();

  // Makes the compiler generate code into a temporary folder, and checks
  // that the SDK has what is needed for linking if that is going to happen.
  // Returns whether it succeeded. Must be called before compiling the program.
  bool prepare(bool needs_sdk);

  // Returns 0 if the executable was built.
  int create_executable(const char* out_path, SnapshotBundle bundle);

  // Writes the C++ program, including the snapshot, without compiling
  // it. The result doesn't depend on anything in the SDK until it is linked
  // with the libraries in 'lib/toit/native'. Returns 0 if it succeeded.
  int write_source(const char* out_path, SnapshotBundle bundle);

 private:
  bool add_snapshot(SnapshotBundle bundle);
  void remove_temp_folder();
  static void remove_active_temp_folder();

  std::string sdk_folder_;
  std::string temp_folder_;
  std::string code_path_;
};

} // namespace toit::compiler
} // namespace toit
