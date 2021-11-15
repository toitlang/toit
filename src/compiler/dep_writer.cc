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

#include "dep_writer.h"

#include <stdio.h>
#include <string.h>

#include "../top.h"
#include "../utils.h"

namespace toit {
namespace compiler {

void DepWriter::write_deps_to_file_if_different(const char* dep_path,
                                                const char* out_path,
                                                std::vector<ast::Unit*> units,
                                                int core_unit_index) {
  for (size_t i = 0; i < units.size(); i++) {
    auto unit = units[i];
    // Modules with empty paths can be ignored, as they are synthetic because we
    // couldn't find the actual sources.
    if (unit->absolute_path()[0] == '\0') continue;
    bool is_core_unit = i == static_cast<size_t>(core_unit_index);
    ListBuilder<const char*> builder;
    if (!is_core_unit) {
      builder.add(units[core_unit_index]->absolute_path());
    }
    for (auto import : unit->imports()) {
      if (import->unit()->absolute_path()[0] != '\0') {
        builder.add(import->unit()->absolute_path());
      }
    }
    generate_dependency_entry(unit->absolute_path(), builder.build());
  }

  auto dep_buffer = _buffer;

  _buffer = "";
  generate_header(out_path);
  auto header_buffer = _buffer;

  _buffer = "";
  generate_footer();
  auto footer_buffer = _buffer;

  if (strcmp(dep_path, "-") == 0) {
    printf("%s%s%s", header_buffer.c_str(), dep_buffer.c_str(), footer_buffer.c_str());
    return;
  }

  std::string new_deps = header_buffer + dep_buffer + footer_buffer;

  char* old_deps = null;
  FILE* file = fopen(dep_path, "r");
  if (file != null) {
    fseek(file, 0, SEEK_END);
    long file_size = ftell(file);
    rewind(file);
    char* buffer = unvoid_cast<char*>(malloc(file_size + 1));
    auto read_bytes = fread(buffer, 1, file_size, file);
    if (read_bytes == 0) {
      free(buffer);
    } else {
      buffer[file_size] = '\0';
      old_deps = buffer;
    }
    fclose(file);
  }

  if (old_deps == null || new_deps != old_deps) {
    file = fopen(dep_path, "w");
    fwrite(new_deps.c_str(), 1, new_deps.size(), file);
    fclose(file);
  }
  if (old_deps != null) free(old_deps);
}

void DepWriter::write(const char* data) {
  _buffer += data;
}

void DepWriter::writeln_int(int x) {
  const int MAX_DIGITS = 5;
  char buffer[MAX_DIGITS + 1];
  int written = snprintf(buffer, MAX_DIGITS, "%d\n", x);
  if (written < 0 || written >= MAX_DIGITS) FATAL("Couldn't write number of deps");
  write(buffer);
}

void PlainDepWriter::generate_header(const char* out_path) {}
void PlainDepWriter::generate_dependency_entry(const char* source, List<const char*> dependencies) {
  write(source);
  write(":\n");
  for (auto dep : dependencies) {
    write("  ");
    writeln(dep);
  }
}
void PlainDepWriter::generate_footer() {}

void NinjaDepWriter::generate_header(const char* out_path) {
  if (out_path == null) FATAL("out-path must not be null in ninja-dep mode");
  write_escaped(out_path);
  write(":");
}
void NinjaDepWriter::generate_dependency_entry(const char* source, List<const char*> dependencies) {
  // We don't even look at the dependencies.
  // Since the main function (`write_deps_to_file_if_different`) runs through all
  // units, we only need to record the source.
  write(" ");
  write_escaped(source);
}
void NinjaDepWriter::generate_footer() {
  write("\n");
}

void NinjaDepWriter::write_escaped(const char* path) {
  const char* first_space = strchr(path, ' ');
  if (first_space == null) {
    write(path);
    return;
  }
  std::string buffer;
  do {
    buffer += std::string(path, first_space);
    buffer += "\\ ";
    path = first_space + 1;
    first_space = strchr(path, ' ');
  } while (first_space != null);
  buffer += path;
  write(buffer.c_str());
}

} // namespace toit::compiler
} // namespace toit

