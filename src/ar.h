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

#include <functional>

#include "top.h"

namespace toit {
namespace ar {

constexpr const int AR_END_OF_ARCHIVE = 1;
constexpr const int AR_ERRNO_ERROR = -1;
constexpr const int AR_FORMAT_ERROR = -2;
constexpr const int AR_OUT_OF_MEMORY = -3;
constexpr const int AR_NOT_FOUND = - 4;

enum DisposalStrategy {
  AR_FREE,
  AR_DONT_FREE,
};

class File {
 public:

  File(const char* name, DisposalStrategy name_disposal, const uint8* content_arg, DisposalStrategy content_disposal, int byte_size_arg)
    : name_(name)
    , name_disposal_(name_disposal)
    , content_(content_arg)
    , content_disposal_(content_disposal)
    , byte_size(byte_size_arg) { }

  File()
    : name_(null)
    , name_disposal_(AR_DONT_FREE)
    , content_(null)
    , content_disposal_(AR_DONT_FREE)
    , byte_size(0) { }

  ~File() {
    free_name();
    free_content();
  }

  const char* name() const { return name_; }

  void clear_name() {
    set_name(null, AR_DONT_FREE);
  }

  void set_name(const char* name, DisposalStrategy disposal) {
    free_name();
    name_disposal_ = disposal;
    name_ = name;
  }

  void free_name() {
    if (name_disposal_ == AR_FREE) {
      free(const_cast<char*>(name_));
    }
    name_ = null;
  }

  const uint8* content() const { return content_; }

  void clear_content() {
    set_content(null, AR_DONT_FREE);
  }

  void set_content(uint8* content, DisposalStrategy disposal) {
    free_content();
    content_disposal_ = disposal;
    content_ = content;
  }

  void free_content() {
    if (content_disposal_ == AR_FREE) {
      free(const_cast<uint8*>(content_));
    }
    content_ = null;
  }

 private:
  const char* name_;  // Max 16 bytes.
  DisposalStrategy name_disposal_;
  const uint8* content_;
  DisposalStrategy content_disposal_;

 public:
  int byte_size;
};

/// Builds an 'ar' archive in memory.
class MemoryBuilder {
 public:
  ~MemoryBuilder() {
    free(buffer_);
  }

  /// Returns 0 on success.
  /// Returns [AR_OUT_OF_MEMORY] if memory couldn't be allocated.
  int open();

  /// Returns 0 on success.
  /// Returns [AR_OUT_OF_MEMORY] if memory couldn't be allocated.
  int add(File file);

  /// Finalizes the archive.
  /// Returns the result in [buffer] and [size].
  /// After this call no further call to [add] is allowed.
  /// The returned buffer should be freed with 'free'.
  /// It is safe to call close even if an earlier operation (like
  /// [open] or [add] failed.
  void close(uint8** buffer, int* size) {
    *buffer = buffer_;
    *size = size_;
    buffer_ = null;
    size_ = 0;
  }

 private:
  uint8* buffer_ = null;
  int size_ = 0;
};

/// Builds an Ar archive, writing it directly to a file.
class FileBuilder {
 public:
  /// Opens the file.
  /// Returns 0 on success.
  /// Returns [AR_ERRNO_ERROR] otherwise. Use 'errno' to extract the error.
  int open(const char* archive_path);

  /// Closes the file.
  /// Returns [AR_ERRNO_ERROR] otherwise. Use 'errno' to extract the error.
  /// It is safe (but not necessary) to call `close` even when the
  /// [open] operation failed.
  int close();

  /// Adds the given [ar_file].
  /// Returns 0 on success.
  /// Returns [AR_ERRNO_ERROR] otherwise. Use 'errno' to extract the error.
  int add(File ar_file);

 private:
  FILE* file_ = NULL;
};

class MemoryReader {
 public:
  MemoryReader(uint8* buffer, int size) : buffer_(buffer), size_(size) {}

  /// Fills the next file.
  /// On success, the name of the file is allocated and should be freed with
  /// 'free'.
  /// On success, the content of the file is pointing directly into the memory
  /// that was given at construction.
  ///
  ///
  /// Returns 0 when a file was successfully read.
  ///
  /// Returns [AR_END_OF_ARCHIVE] when at the end of the archive.
  ///
  /// Returns [AR_FORMAT_ERROR] on error. For example, when the data structure
  /// is corrupted or truncated.
  int next(File* file);

  /// Finds the file with the given name and fills the given [file] structure.
  /// On success, the name of the file points to the given [name], and
  /// the content of the file is pointing directly into the memory that
  /// was given at construction.
  ///
  /// If [reset] is true, starts searching at the beginning of the memory.
  ///
  /// Returns 0 when a file was successfully read.
  /// Returns [AR_NOT_FOUND] when the file wasn't found.
  ///
  /// Returns [AR_FORMAT_ERROR] when the data structure is corrupted or truncated.
  int find(const char* name, File* file, bool reset = true);

 private:
  uint8* buffer_;
  int size_;
  int offset_ = 0;
};

class FileReader {
 public:
  FileReader() {}

  /// Provides this instance with an already opened file pointer.
  /// In this case the calls to [open] and [close] are not necessary.
  FileReader(FILE* file) : file_(file) {}

  /// Opens the file.
  /// Returns 0 on success.
  /// Returns [AR_ERRNO_ERROR] otherwise. Use 'errno' to extract the error.
  int open(const char* archive_path);

  /// Closes the file.
  /// Returns 0 on success.
  /// Returns [AR_ERRNO_ERROR] otherwise. Use 'errno' to extract the error.
  /// It is safe (but not necessary) to call `close` even when the
  /// [open] operation failed.
  int close();

  /// Fills the next file.
  ///
  /// Returns 0 when a file was successfully read.
  /// In this case:
  ///   - The name of the file is allocated and should be freed with 'free'.
  ///   - The content of the file is allocated and should be freed with 'free'.
  ///
  /// Returns [AR_END_OF_ARCHIVE] when at the end of the archive.
  ///
  /// Returns [AR_ERRNO_ERROR] on file error. Use 'errno' to extract the error.
  /// Note that [AR_ERRNO_ERROR] is also returned, when the file is truncated.
  /// Returns [AR_FORMAT_ERROR] on other errors. For example, when the data
  /// structure is corrupted.
  /// Returns [AR_OUT_OF_MEMORY] when malloc failed.
  int next(File* file);

  /// Finds the file with the given name and fills the given [file] structure.
  ///
  /// If [reset] is true, starts searching at the beginning of the file. This
  /// requires the file to be seekable.
  ///
  /// Returns 0 when a file was successfully read.
  /// In that case:
  ///   - The name of the file is pointing to the given [name].
  ///   - The content of the file is allocated and should be freed with 'free'.
  ///
  /// Returns [AR_NOT_FOUND] when the file wasn't found.
  ///
  /// Returns [AR_ERRNO_ERROR] on file error. Use 'errno' to extract the error.
  /// Note that [AR_ERRNO_ERROR] is also returned, when the file is truncated.
  /// Returns [AR_FORMAT_ERROR] on other errors. For example, when the data
  /// structure is corrupted.
  /// Returns [AR_OUT_OF_MEMORY] when malloc failed.
  int find(const char* name, File* file, bool reset = true);

 private:
  bool _is_first = true;
  FILE* file_ = null;

  int read_ar_header();
  int read_file_header(File* file);
  int read_file_content(File* file);
  int skip_file_content(File* file);
};

} // namespace toit::Ar
} // namespace toit
