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

#include <functional>
#include <string>

#include "../top.h"

#include "list.h"
#include "map.h"
#include "symbol.h"

namespace toit {
namespace compiler {

class Diagnostics;
class SourceManagerSource;
class Package;
class Filesystem;

class Source {
 public:
  class Position {
   public:
    static Position invalid() { return Position(-1); }

    bool is_valid() const { return token_ != -1; }

    /// Whether this position is before the [other] position.
    ///
    /// Should only be used for positions in the same file.
    /// However, will return a deterministic response for positions
    /// from two different files.
    bool is_before(const Position& other) const {
      return token_ < other.token_;
    }

    size_t hash() const {
      return token_;
    }

    bool operator==(const Position& other) const {
      return token_ == other.token_;
    }

    bool operator!=(const Position& other) const {
      return !(*this == other);
    }

   public:  // Only for `Source` implementations and the location_id (in the source_mapping).
    static Position from_token(int token) { return Position(token); }
    int token() const { return token_; }

   private:
    explicit Position(int token) : token_(token) {}

    int token_;
  };

  class Range {
   public:
    explicit Range(Position position) : from_(position), to_(position) {}
    Range(Position from, Position to) : from_(from), to_(to) {
      ASSERT((from.is_valid() && to.is_valid()) || (!from.is_valid() && !to.is_valid()));
    }

    static Range invalid() { return Range(Position::invalid()); }

    [[nodiscard]] Range extend(Range other) const {
      auto extended_from = from().is_before(other.from()) ? from() : other.from();
      auto extended_to = to().is_before(other.to()) ? other.to() : to();
      return Range(extended_from, extended_to);
    }
    [[nodiscard]] Range extend(Position to) const { return extend(Range(to, to)); }

    bool is_valid() const { return from_.is_valid(); }

    /// Whether this range is before the [other] range.
    ///
    /// Only looks at the [from] position.
    ///
    /// Should only be used for ranges in the same file.
    /// However, will return a deterministic response for ranges
    /// from two different files.
    bool is_before(const Range& other) const {
      return from_.is_before(other.from());
    }

    Position from() const {
      ASSERT(is_valid());
      return from_;
    }

    Position to() const {
      ASSERT(is_valid());
      return to_;
    }

    bool operator==(const Range& other) const {
      return from_ == other.from_ && to_ == other.to_;
    }

    bool operator!=(const Range& other) const {
      return !(*this == other);
    }

    size_t hash() const {
      return (from_.hash() << 13) ^ (to_.hash());
    }

   private:
    Position from_;
    Position to_;
  };

  struct Location {
    Location(Source* source,
             int offset_in_source,
             int offset_in_line,
             int line_number,
             int line_offset)
        : source(source)
        , offset_in_source(offset_in_source)
        , offset_in_line(offset_in_line)
        , line_number(line_number)
        , line_offset(line_offset) {}

    Source* source;
    int offset_in_source;
    int offset_in_line; // 0-based.
    int line_number;    // 1-based.
    int line_offset;

    bool is_valid() const { return source != null; }
    static Location invalid() { return Location(null, 0, 0, 0, 0); }
  };

  /// Returns the path of the source.
  ///
  /// Might be "", if the source was given as argument to the compiler.
  virtual const char* absolute_path() const = 0;

  /// The package this source comes from.
  virtual std::string package_id() const = 0;

  /// Returns the error path of the source.
  ///
  /// This is the path the we would like to show to the user in stack traces, or
  /// when there is an error message, or
  virtual std::string error_path() const = 0;

  virtual const uint8* text() const = 0;

  virtual Range range(int from, int to) const = 0;

  virtual int size() const = 0;

  /// Returns the offset of the given [position] in this source.
  /// Returns -1 if the position is not from this source.
  virtual int offset_in_source(Position position) const = 0;

  /// Whether the position at `offset` is an lsp_marker (see `scanner.h`)
  virtual bool is_lsp_marker_at(int offset) = 0;

  /// Fills the given [text_from] and [text_to] parameters with pointers to
  ///   text corresponding to the `text[from]-text[to]` without any marker.
  virtual void text_range_without_marker(int from, int to,
                                         const uint8** text_from, const uint8** text_to) = 0;
};

class SourceManager {
 public:
  struct LoadResult {
    enum Status {
      OK,
      NOT_REGULAR_FILE,
      NOT_FOUND,
      FILE_ERROR,  // Error reading file.
    };

    Source* source;
    std::string absolute_path;  // The absolute path is always set, even in case of errors.
    Status status;

    void report_error(const Source::Range& range, Diagnostics* diagnostics);
    void report_error(Diagnostics* diagnostics);
  };

  static constexpr const char* const VIRTUAL_FILE_PREFIX = "///";

  SourceManager(Filesystem* filesystem)
      : filesystem_(filesystem)
      , cached_source_entry_(null)
      , cached_offset_(-1)
      , cached_location_(null, 0, 0, 0, 0) {}

  /// Loads the given file.
  ///
  /// The [error_path_callback] is used to get the error path. The callback is
  /// only invoked if we haven't seen the file before.
  LoadResult load_file(const std::string& path, const Package& package);

  Source* source_for_position(Source::Position position) const;
  Source::Location compute_location(Source::Position position) const;

  const char* library_root();

  // Virtual files are not stored on the disk and can only be provided
  // directly (from within the compiler), or through a [Filesystem] instance
  // that isn't directly accessing the actual filesystem.
  //
  // Usually they are unsaved files. These files are not stored and disk and
  // only exist for the compilation.
  static bool is_virtual_file(const char* path) {
    return strncmp(path, VIRTUAL_FILE_PREFIX, strlen(VIRTUAL_FILE_PREFIX)) == 0;
  }

  bool is_loaded(const char* path);
  bool is_loaded(const std::string& path);

 private:
  Filesystem* filesystem_;

  int next_offset_ = 0;

  std::vector<SourceManagerSource*> sources_;
  UnorderedMap<std::string, SourceManagerSource*> path_to_source_;

  mutable SourceManagerSource* cached_source_entry_;
  mutable int cached_offset_;
  mutable Source::Location cached_location_;

  SourceManagerSource* register_source(const std::string& path,
                                       const std::string& package_id,
                                       const std::string& error_path,
                                       const uint8* source,
                                       int size);
};

} // namespace toit::compiler
} // namespace toit


namespace std {
  template <> struct hash<::toit::compiler::Source::Position> {
    std::size_t operator()(const ::toit::compiler::Source::Position& position) const {
      return position.hash();
    }
  };
  template <> struct less<::toit::compiler::Source::Position> {
    bool operator()(const ::toit::compiler::Source::Position& a,
                    const ::toit::compiler::Source::Position& b) const {
      return a.is_before(b);
    }
  };

  template <> struct hash<::toit::compiler::Source::Range> {
    std::size_t operator()(const ::toit::compiler::Source::Range& range) const {
      return range.hash();
    }
  };
  template <> struct less<::toit::compiler::Source::Range> {
    bool operator()(const ::toit::compiler::Source::Range& a,
                    const ::toit::compiler::Source::Range& b) const {
      return a.is_before(b);
    }
  };
}  // namespace std
