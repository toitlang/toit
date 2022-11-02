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
      : buffer_(buffer)
      , buffer_size_(buffer_size)
      , pos_(0)
      , should_be_null_terminated_(should_be_null_terminated) {}

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
    int null_terminator_size = should_be_null_terminated_ ? 1 : 0;
    if (len + null_terminator_size > remaining()) {
      // Mark as overrun.
      pos_ = buffer_size_ + 1;
      return;
    }
    strncpy(&buffer_[pos_], str, remaining());
    pos_ = len > remaining() ? 0 : pos_ + len;
    ASSERT(!should_be_null_terminated_ || buffer_[pos_] == '\0');
  }

  bool overrun() const {
    int null_terminator_size = should_be_null_terminated_ ? 1 : 0;
    return remaining() < null_terminator_size;
  }

  int length() const { return pos_; }

  void reset_to(int position) {
    pos_ = position;
    if (should_be_null_terminated_ && !overrun()) {
      buffer_[pos_] = '\0';
    }
  }

 private:
  char* buffer_;
  int buffer_size_;
  int pos_;
  bool should_be_null_terminated_;

  int remaining() const { return buffer_size_ - pos_; }
};

class PathBuilder {
 public:
  explicit PathBuilder(Filesystem* fs) : fs_(fs) {}

  int length() const { return buffer_.size(); }
  std::string buffer() const { return buffer_; }
  const char* c_str() const { return buffer_.c_str(); }
  char* strdup() const { return ::strdup(c_str()); }

  void add(const std::string& str) { buffer_ += str; }
  void add(char c) { buffer_ += c; }

  void reset_to(int size) {
    buffer_.resize(size);
  }

  char operator[](int index) const { return buffer_[index]; }

  // Ensures that there is a path-separator between the existing buffer
  // and the new segment.
  // Only inserts the separator if the buffer isn't empty.
  void join(const std::string& segment) {
    if (!buffer_.empty() && buffer_[buffer_.size() - 1] != fs_->path_separator()) {
      buffer_ += fs_->path_separator();
    }
    buffer_ += segment;
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
  Filesystem* fs_;
  std::string buffer_;
};

// Splits the given string according to the delimiters.
List<const char*> string_split(const char* str, const char* delim);
// Splits the given string, physically modifying the input, and using it
// in the returned list.
List<const char*> string_split(char* str, const char* delim);

} // namespace toit::compiler
} // namespace toit
