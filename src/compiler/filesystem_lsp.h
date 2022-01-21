// Copyright (C) 2020 Toitware ApS.
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

#include <stdio.h>
#include <string>

#include "../top.h"

#include "filesystem.h"
#include "map.h"

#include "lsp/fs_protocol.h"

namespace toit {
namespace compiler {

class FilesystemLsp : public Filesystem {
 public:
  explicit FilesystemLsp(LspFsProtocol* protocol) : _protocol(protocol) { }

  void initialize(Diagnostics* diagnostics) {
    _protocol->initialize(diagnostics);
  }

  const char* entry_path() { return null; }

  const char* sdk_path();
  List<const char*> package_cache_paths();
  bool is_absolute(const char* path) { return path[0] == '/'; }

 protected:
  bool do_exists(const char* path);
  bool do_is_regular_file(const char* path);
  bool do_is_directory(const char* path);

  const uint8* do_read_content(const char* path, int* size);

  const char* getcwd(char* buffer, int buffer_size) { UNREACHABLE(); }
  void list_directory_entries(const char* path,
                              const std::function<void (const char*)> callback);

 private:
  UnorderedMap<std::string, LspFsProtocol::PathInfo> _file_cache;
  LspFsProtocol* _protocol;

  LspFsProtocol::PathInfo info_for(const char* path);
};

} // namespace compiler
} // namespace toit
