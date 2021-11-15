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

#pragma once

#include <vector>
#include "ast.h"
#include "list.h"

namespace toit {
namespace compiler {

class DepWriter {
 public:
  void write_deps_to_file_if_different(const char* dep_path,
                                       const char* out_path,
                                       std::vector<ast::Unit*> units,
                                       int core_unit_index);

 protected:
  /// Writes the given [data].
  ///
  /// The [data] is not held onto, and does not need to stay valid after the call.
  void write(const char* data);
  void writeln(const char* data) {
    write(data);
    write("\n");
  }
  void writeln_int(int x);

  /// Reports a direct dependency from [source] to [dependencies].
  /// The dependencies list might contain duplicates.
  virtual void generate_dependency_entry(const char* source, List<const char*> dependencies) = 0;
  // This function will be called *after* all invocations of `generate_dependency_entry`.
  virtual void generate_header(const char* out_path) = 0;
  virtual void generate_footer() = 0;

 private:
  std::string _buffer;
};

class PlainDepWriter : public DepWriter {
 protected:
  void generate_header(const char* out_path);
  void generate_footer();
  void generate_dependency_entry(const char* source, List<const char*> dependencies);
};

class NinjaDepWriter : public DepWriter {
 protected:
  void generate_header(const char* out_path);
  void generate_footer();
  void generate_dependency_entry(const char* source, List<const char*> dependencies);

 private:
  void write_escaped(const char* path);
};

} // namespace toit::compiler
} // namespace toit
