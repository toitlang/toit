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

#include "../top.h"

#include <stdio.h>

#ifdef TOIT_POSIX
#include <sys/socket.h>
#endif
#ifdef TOIT_WINDOWS
#include <winsock.h>
#endif

#include "diagnostic.h"
#include "filesystem_lsp.h"
#include "../utils.h"

namespace toit {
namespace compiler {

char* get_executable_path();

bool FilesystemLsp::do_exists(const char* path) {
  auto info = info_for(path);
  return info.exists;
}

bool FilesystemLsp::do_is_regular_file(const char* path) {
  auto info = info_for(path);
  return info.is_regular_file;
}

bool FilesystemLsp::do_is_directory(const char* path) {
  auto info = info_for(path);
  return info.is_directory;
}

const char* FilesystemLsp::sdk_path() {
  return protocol_->sdk_path();
}

List<const char*> FilesystemLsp::package_cache_paths() {
  return protocol_->package_cache_paths();
}

const uint8* FilesystemLsp::do_read_content(const char* path, int* size) {
  auto info = info_for(path);
  *size = info.size;
  return info.content;
}

void FilesystemLsp::list_directory_entries(const char* path,
                                           const std::function<void (const char*)> callback) {
  protocol_->list_directory_entries(path, callback);
}

LspFsProtocol::PathInfo FilesystemLsp::info_for(const char* path) {
  std::string lookup_key(path);
  auto probe = file_cache_.find(lookup_key);
  if (probe != file_cache_.end()) return probe->second;

  auto info = protocol_->fetch_info_for(path);
  file_cache_[lookup_key] = info;
  return info;
}

} // namespace compiler
} // namespace toit
