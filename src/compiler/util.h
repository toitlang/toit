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
#include <string.h>

#include "../utils.h"
#include "filesystem.h"

namespace toit {
namespace compiler {

class StringBuilder {
 public:
  StringBuilder(char* buffer, int buffer_size, bool should_be_null_terminated)
      : _buffer(buffer)
      , _buffer_size(buffer_size)
      , _pos(0)
      , _should_be_null_terminated(should_be_null_terminated) {}

  void add(const char* str) {
    add(str, strlen(str));
  }
  void add(char c) {
    char char_buffer[2];
    char_buffer[0] = c;
    char_buffer[1] = '\0';
    add(char_buffer, 1);
  }
  void add(const char* str, int len) {
    int null_terminator_size = _should_be_null_terminated ? 1 : 0;
    if (len + null_terminator_size > remaining()) {
      // Mark as overrun.
      _pos = _buffer_size + 1;
      return;
    }
    strncpy(&_buffer[_pos], str, remaining());
    _pos = len > remaining() ? 0 : _pos + len;
    ASSERT(!_should_be_null_terminated || _buffer[_pos] == '\0');
  }

  bool overrun() const {
    int null_terminator_size = _should_be_null_terminated ? 1 : 0;
    return remaining() < null_terminator_size;
  }

  int length() const { return _pos; }

  void reset_to(int position) {
    _pos = position;
    if (_should_be_null_terminated && !overrun()) {
      _buffer[_pos] = '\0';
    }
  }

 private:
  char* _buffer;
  int _buffer_size;
  int _pos;
  bool _should_be_null_terminated;

  int remaining() const { return _buffer_size - _pos; }
};

class PathBuilder {
 public:
  explicit PathBuilder(Filesystem* fs) : _fs(fs) {}

  int length() const { return _buffer.size(); }
  std::string buffer() const { return _buffer; }
  const char* c_str() const { return _buffer.c_str(); }
  char* strdup() const { return ::strdup(c_str()); }

  void add(const std::string& str) { _buffer += str; }
  void add(char c) { _buffer += c; }

  void reset_to(int size) {
    _buffer.resize(size);
  }

  char operator[](int index) const { return _buffer[index]; }

  // Ensures that there is a path-separator between the existing buffer
  // and the new segment.
  // Only inserts the separator if the buffer isn't empty.
  void join(const std::string& segment) {
    if (!_buffer.empty() && _buffer[_buffer.size() - 1] != _fs->path_separator()) {
      _buffer += _fs->path_separator();
    }
    _buffer += segment;
  }

  void join(const std::string& segment, const std::string& segment2) {
    join(segment);
    join(segment2);
  }

  void join(const std::string& segment, const std::string& segment2, const std::string& segment3) {
    join(segment);
    join(segment2);
    join(segment3);
  }

  void join(const std::string& segment, const std::string& segment2, const std::string& segment3, const std::string& segment4) {
    join(segment);
    join(segment2);
    join(segment3);
    join(segment4);
  }

  void canonicalize();

 private:
  Filesystem* _fs;
  std::string _buffer;
};

// Splits the given string according to the delimiters.
List<const char*> string_split(const char* str, const char* delim);
// Splits the given string, physically modifying the input, and using it
// in the returned list.
List<const char*> string_split(char* str, const char* delim);

struct Defer {
  std::function<void()> fun;
  ~Defer() { fun(); }
};

} // namespace toit::compiler
} // namespace toit
