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

#include "sources.h"

#include <stdio.h>
#include <stdarg.h>
#include <limits.h>

#include "ast.h"
#include "diagnostic.h"
#include "lock.h"
#include "util.h"

#include "../utils.h"

namespace toit {
namespace compiler {

class SourceManagerSource : public Source {
 public:
  SourceManagerSource(const char* absolute_path,
                      const std::string& package_id,
                      const std::string& error_path,
                      const uint8* text,
                      int size,
                      int offset)
      : _absolute_path(absolute_path)
      , _package_id(package_id)
      , _error_path(error_path)
      , _text(text)
      , _size(size),
      _offset(offset) { }

  static SourceManagerSource invalid() {
    return SourceManagerSource(null, Package::INVALID_PACKAGE_ID, "", null, 0, 0);
  }

  bool is_valid() const { return _text != null; }

  /// Returns the path of the source.
  ///
  /// Might be "", if the source was given as argument to the compiler.
  const char* absolute_path() const {
    ASSERT(is_valid());
    return _absolute_path;
  }

  std::string package_id() const {
    return _package_id;
  }

  std::string error_path() const {
    ASSERT(is_valid());
    return _error_path;
  }

  const uint8* text() const {
    ASSERT(is_valid());
    return _text;
  }

  Range range(int from, int to) const {
    ASSERT(is_valid());
    ASSERT(0 <= from && from <= _size);
    ASSERT(0 <= to && to <= _size);
    return Range(Position::from_token(_offset + from),
                 Position::from_token(_offset + to));
  }

  int size() const {
    ASSERT(is_valid());
    return _size;
  }

  /// Returns the offset of the given [position] in this source.
  /// Returns -1 if the position is not from this source.
  int offset_in_source(Position position) const {
    if (_offset <= position.token() && position.token() <= _offset + _size) {
      return position.token() - _offset;
    }
    return -1;
  }

  bool is_lsp_marker_at(int offset) { return false; }

  void text_range_without_marker(int from, int to, const uint8** text_from, const uint8** text_to) {
    *text_from = &_text[from];
    *text_to = &_text[to];
  }

  int offset() const { return _offset; }

 private:
  const char* _absolute_path;
  std::string _package_id;
  std::string _error_path;
  const uint8* _text;
  int _size;
  int _offset;
};

const char* error_message_for_load_error(SourceManager::LoadResult::Status status) {
  switch (status) {
    case SourceManager::LoadResult::OK: UNREACHABLE();
    case SourceManager::LoadResult::NOT_REGULAR_FILE: return "Not a regular file: '%s'";
    case SourceManager::LoadResult::NOT_FOUND: return "File not found: '%s'";
    case SourceManager::LoadResult::FILE_ERROR: return "Error while reading file: '%s'";
  }
  UNREACHABLE();
}

const char* SourceManager::library_root() {
  return _filesystem->library_root();
}

void SourceManager::LoadResult::report_error(Diagnostics* diagnostics) {
  diagnostics->report_error(error_message_for_load_error(status),
                            absolute_path.c_str());
}

void SourceManager::LoadResult::report_error(const Source::Range& range,
                                             Diagnostics* diagnostics) {
  diagnostics->report_error(range,
                            error_message_for_load_error(status),
                            absolute_path.c_str());
}

bool SourceManager::is_loaded(const char* path) {
  return is_loaded(std::string(path));
}

bool SourceManager::is_loaded(const std::string& path) {
  return _path_to_source.find(path) != _path_to_source.end();
}

SourceManager::LoadResult SourceManager::load_file(const std::string& path, const Package& package) {
  auto probe = _path_to_source.find(path);
  if (probe != _path_to_source.end()) {
    // The path is already loaded.
    auto entry = probe->second;
    return {
      .source = entry,
      .absolute_path = path,
      .status = LoadResult::OK,
    };
  }
  if (!_filesystem->exists(path.c_str())) {
    return {
      .source = null,
      .absolute_path = path,
      .status = LoadResult::NOT_FOUND,
    };
  }
  if (!_filesystem->is_regular_file(path.c_str())) {
    return {
      .source = null,
      .absolute_path = path,
      .status = LoadResult::NOT_REGULAR_FILE,
    };
  }
  int size;
  auto buffer = _filesystem->read_content(path.c_str(), &size);
  if (buffer == null) {
    return {
      .source = null,
      .absolute_path = path,
      .status = LoadResult::FILE_ERROR,
    };
  }
  // This is the first time we encounter this path.
  std::string error_path;
  std::string package_id;
  if (package.is_valid()) {
    error_path = package.build_error_path(_filesystem, path);
    package_id = package.id();
  } else {
    error_path = path;
    package_id = Package::ENTRY_PACKAGE_ID;
  }
  auto source = register_source(path, package_id, error_path, buffer, size);
  return {
    .source = source,
    .absolute_path = path,
    .status = LoadResult::OK,
  };
}

SourceManagerSource* SourceManager::register_source(const std::string& absolute_path,
                                                    const std::string& package_id,
                                                    const std::string& error_path,
                                                    const uint8* source,
                                                    int size) {
  auto entry = _new SourceManagerSource(strdup(absolute_path.c_str()),
                                        package_id,
                                        error_path,
                                        source,
                                        size,
                                        _next_offset);
  _sources.push_back(entry);
  if (absolute_path != "") {
    _path_to_source.add(absolute_path, entry);
  }
  // Add one for the terminating character. This also allows to point to errors
  // at the end of the file. (Like unclosed strings, comments, ...)
  _next_offset = entry->offset() + entry->size() + 1;
  return entry;
}

Source* SourceManager::source_for_position(Source::Position position) const {
  int absolute_offset = position.token();
  ASSERT(0 <= absolute_offset && absolute_offset < _next_offset);

  SourceManagerSource* entry = null;

  if (entry == null) {
    int start_index = 0;
    int end_index = _sources.size() - 1;
    while (start_index != end_index) {
      int half_index = start_index + (end_index - start_index) / 2;
      auto current = _sources[half_index];
      if (absolute_offset < current->offset()) {
        end_index = half_index - 1;
      } else if (absolute_offset > current->offset() + current->size()) {
        start_index = half_index + 1;
      } else {
        start_index = end_index = half_index;
        break;
      }
    }
    entry = _sources[start_index];
    ASSERT(entry->offset() <= absolute_offset && absolute_offset <= entry->offset() + entry->size());
  }
  ASSERT(entry != null);

  _cached_offset = absolute_offset;
  _cached_source_entry = entry;
  _cached_location = Source::Location::invalid();

  return entry;
}

Source::Location SourceManager::compute_location(Source::Position position) const {
  int absolute_offset = position.token();
  ASSERT(0 <= absolute_offset && absolute_offset < _next_offset);

  SourceManagerSource* entry = null;

  int start_offset = 0;  // The starting offset to search for.
  int line = 1;  // The line number.
  int line_start = 0;  // The start of the line.

  if (_cached_offset >= 0 &&
      _cached_source_entry->offset() <= absolute_offset &&
      absolute_offset <= _cached_source_entry->offset() + _cached_source_entry->size()) {
    entry = _cached_source_entry;
    if (_cached_offset < absolute_offset) {
      if (_cached_location.is_valid()) {
        start_offset = _cached_offset - entry->offset();
        line = _cached_location.line_number;
        line_start = _cached_location.line_offset;
      }
    }
  }
  if (entry == null) {
    entry = static_cast<SourceManagerSource*>(source_for_position(position));
  }
  ASSERT(entry != null);
  const uint8* text = entry->text();
  int offset_in_source = absolute_offset - entry->offset();

  for (int i = start_offset; i < offset_in_source; i++) {
    int c = text[i];
    if (c == 10 || c == 13) {
      int other = (c == 10) ? 13 : 10;
      if (text[i + 1] == other) i++;
      line_start = i + 1;
      line++;
    }
  }

  int offset_in_line = offset_in_source - line_start;
  Source::Location result(entry, offset_in_source, offset_in_line, line, line_start);

  _cached_offset = absolute_offset;
  _cached_source_entry = entry;
  _cached_location = result;
  return result;
}

} // namespace toit::compiler
} // namespace toit
