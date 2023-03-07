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
      : absolute_path_(absolute_path)
      , package_id_(package_id)
      , error_path_(error_path)
      , text_(text)
      , size_(size),
      offset_(offset) {}

  static SourceManagerSource invalid() {
    return SourceManagerSource(null, Package::INVALID_PACKAGE_ID, "", null, 0, 0);
  }

  bool is_valid() const { return text_ != null; }

  /// Returns the path of the source.
  ///
  /// Might be "", if the source was given as argument to the compiler.
  const char* absolute_path() const {
    ASSERT(is_valid());
    return absolute_path_;
  }

  std::string package_id() const {
    return package_id_;
  }

  std::string error_path() const {
    ASSERT(is_valid());
    return error_path_;
  }

  const uint8* text() const {
    ASSERT(is_valid());
    return text_;
  }

  Range range(int from, int to) const {
    ASSERT(is_valid());
    ASSERT(0 <= from && from <= size_);
    ASSERT(0 <= to && to <= size_);
    return Range(Position::from_token(offset_ + from),
                 Position::from_token(offset_ + to));
  }

  int size() const {
    ASSERT(is_valid());
    return size_;
  }

  /// Returns the offset of the given [position] in this source.
  /// Returns -1 if the position is not from this source.
  int offset_in_source(Position position) const {
    if (offset_ <= position.token() && position.token() <= offset_ + size_) {
      return position.token() - offset_;
    }
    return -1;
  }

  bool is_lsp_marker_at(int offset) { return false; }

  void text_range_without_marker(int from, int to, const uint8** text_from, const uint8** text_to) {
    *text_from = &text_[from];
    *text_to = &text_[to];
  }

  int offset() const { return offset_; }

 private:
  const char* absolute_path_;
  std::string package_id_;
  std::string error_path_;
  const uint8* text_;
  int size_;
  int offset_;
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
  return filesystem_->library_root();
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
  return path_to_source_.find(path) != path_to_source_.end();
}

SourceManager::LoadResult SourceManager::load_file(const std::string& path, const Package& package) {
  auto probe = path_to_source_.find(path);
  if (probe != path_to_source_.end()) {
    // The path is already loaded.
    auto entry = probe->second;
    return {
      .source = entry,
      .absolute_path = path,
      .status = LoadResult::OK,
    };
  }
  if (!filesystem_->exists(path.c_str())) {
    return {
      .source = null,
      .absolute_path = path,
      .status = LoadResult::NOT_FOUND,
    };
  }
  if (!filesystem_->is_regular_file(path.c_str())) {
    return {
      .source = null,
      .absolute_path = path,
      .status = LoadResult::NOT_REGULAR_FILE,
    };
  }
  int size;
  auto buffer = filesystem_->read_content(path.c_str(), &size);
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
    error_path = package.build_error_path(filesystem_, path);
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
                                        next_offset_);
  sources_.push_back(entry);
  if (absolute_path != "") {
    path_to_source_.add(absolute_path, entry);
  }
  // Add one for the terminating character. This also allows to point to errors
  // at the end of the file. (Like unclosed strings, comments, ...)
  next_offset_ = entry->offset() + entry->size() + 1;
  return entry;
}

Source* SourceManager::source_for_position(Source::Position position) const {
  int absolute_offset = position.token();
  ASSERT(0 <= absolute_offset && absolute_offset < next_offset_);

  SourceManagerSource* entry = null;

  if (entry == null) {
    int start_index = 0;
    int end_index = sources_.size() - 1;
    while (start_index != end_index) {
      int half_index = start_index + (end_index - start_index) / 2;
      auto current = sources_[half_index];
      if (absolute_offset < current->offset()) {
        end_index = half_index - 1;
      } else if (absolute_offset > current->offset() + current->size()) {
        start_index = half_index + 1;
      } else {
        start_index = end_index = half_index;
        break;
      }
    }
    entry = sources_[start_index];
    ASSERT(entry->offset() <= absolute_offset && absolute_offset <= entry->offset() + entry->size());
  }
  ASSERT(entry != null);

  cached_offset_ = absolute_offset;
  cached_source_entry_ = entry;
  cached_location_ = Source::Location::invalid();

  return entry;
}

Source::Location SourceManager::compute_location(Source::Position position) const {
  int absolute_offset = position.token();
  ASSERT(0 <= absolute_offset && absolute_offset < next_offset_);

  SourceManagerSource* entry = null;

  int start_offset = 0;  // The starting offset to search for.
  int line = 1;  // The line number.
  int line_start = 0;  // The start of the line.

  if (cached_offset_ >= 0 &&
      cached_source_entry_->offset() <= absolute_offset &&
      absolute_offset <= cached_source_entry_->offset() + cached_source_entry_->size()) {
    entry = cached_source_entry_;
    if (cached_offset_ < absolute_offset) {
      if (cached_location_.is_valid()) {
        start_offset = cached_offset_ - entry->offset();
        line = cached_location_.line_number;
        line_start = cached_location_.line_offset;
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
    if (c == '\r' && text[i + 1] == '\n') {
      i++;
      c = '\n';
    }
    if (c == '\n') {
      line_start = i + 1;
      line++;
    }
  }

  int offset_in_line = offset_in_source - line_start;
  Source::Location result(entry, offset_in_source, offset_in_line, line, line_start);

  cached_offset_ = absolute_offset;
  cached_source_entry_ = entry;
  cached_location_ = result;
  return result;
}

} // namespace toit::compiler
} // namespace toit
