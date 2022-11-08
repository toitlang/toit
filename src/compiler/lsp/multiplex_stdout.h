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

#include "../../top.h"

#include "protocol.h"
#include "fs_protocol.h"

namespace toit {
namespace compiler {

/// A LspWriter and LspFsConnection that both communicate over stdout/stdin.
/// Only the LspFsConnection is reading from stdin, so it can just work from it.
/// When sending data, then the messages are prefixed with the length of the
/// message. However, the LspFsConnection negates the size first, so that
/// the LSP server can figure out which protocol is currently used.

struct LspWriterMultiplexStdout : public LspWriter {
  void printf(const char* format, va_list& arguments);
  void write(const uint8* data, int size);
};

struct LspFsConnectionMultiplexStdout : public LspFsConnection {
  void initialize(Diagnostics* diagnostics) {}
  void putline(const char* line);
  char* getline();
  int read_data(uint8* content, int size);
};

} // namespace toit::compiler
} // namespace toit
