// Copyright (C) 2022 Toitware ApS.
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

#include <functional>

#include "../../top.h"

#include "../list.h"

namespace toit {
namespace compiler {

class Diagnostics;

struct LspFsConnection {
  virtual ~LspFsConnection() {}
  virtual void initialize(Diagnostics* diagnostics) = 0;
  virtual void putline(const char* line) = 0;
  virtual char* getline() = 0;
  virtual int read_data(uint8* content, int size) = 0;
};

class LspFsProtocol {
 public:
  LspFsProtocol(LspFsConnection* connection) : _connection(connection) { }
  struct PathInfo {
    bool exists;
    bool is_regular_file;
    bool is_directory;
    int size;
    const uint8* content;
  };

  void initialize(Diagnostics* diagnostics) {
    _connection->initialize(diagnostics);
  }

  const char* sdk_path();
  List<const char*> package_cache_paths();
  void list_directory_entries(const char* path,
                              const std::function<void (const char*)> callback);

  PathInfo fetch_info_for(const char* path);

 private:
  LspFsConnection* _connection;
};

} // namespace toit::compiler
} // namespace toit
