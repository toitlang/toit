// Copyright (C) 2026 Toit contributors.
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

#include "file_writer.h"

#include <atomic>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string>
#include <sys/stat.h>

#ifdef TOIT_WINDOWS
#include <io.h>
#include <windows.h>
#else
#include <unistd.h>
#endif

#ifndef O_BINARY
#define O_BINARY 0
#endif

namespace toit {

namespace {

std::atomic<unsigned int> next_temporary_id(0);

#ifdef TOIT_WINDOWS

std::wstring wide_path(const char* path) {
  int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                   path, -1, null, 0);
  if (length <= 0) return std::wstring();
  std::wstring result(length, L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                          path, -1, &result[0], length) == 0) {
    return std::wstring();
  }
  result.resize(length - 1);
  return result;
}

bool replace_file(const std::string& temporary, const std::string& path) {
  std::wstring temporary_w = wide_path(temporary.c_str());
  std::wstring path_w = wide_path(path.c_str());
  if (temporary_w.empty() || path_w.empty()) {
    errno = EINVAL;
    return false;
  }
  if (MoveFileExW(temporary_w.c_str(), path_w.c_str(),
                  MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0) {
    return true;
  }
  errno = EIO;
  return false;
}

int process_id() {
  return _getpid();
}

#else

bool replace_file(const std::string& temporary, const std::string& path) {
  return rename(temporary.c_str(), path.c_str()) == 0;
}

int process_id() {
  return getpid();
}

#endif

std::string temporary_path(const std::string& path) {
  unsigned int id = next_temporary_id.fetch_add(1);
  return path + ".tmp." + std::to_string(process_id()) + "." +
      std::to_string(id);
}

} // namespace

bool write_file_atomically(const char* path,
                           const uint8* content,
                           size_t size,
                           int create_mode) {
  if (path == null || path[0] == '\0') {
    errno = EINVAL;
    return false;
  }
  if (content == null && size != 0) {
    errno = EINVAL;
    return false;
  }

  std::string destination(path);
  int existing_mode = -1;

#ifdef TOIT_WINDOWS
  std::wstring destination_w = wide_path(path);
  if (destination_w.empty()) {
    errno = EINVAL;
    return false;
  }
  struct _stat64 destination_stat;
  if (_wstat64(destination_w.c_str(), &destination_stat) == 0) {
    if ((destination_stat.st_mode & _S_IFMT) != _S_IFREG) {
      errno = EINVAL;
      return false;
    }
    if ((destination_stat.st_mode & _S_IWRITE) == 0
        || _waccess(destination_w.c_str(), 2) != 0) {
      errno = EACCES;
      return false;
    }
    existing_mode =
        destination_stat.st_mode & (_S_IREAD | _S_IWRITE);
  } else if (errno != ENOENT) {
    return false;
  }
#else
  struct stat destination_stat;
  if (lstat(path, &destination_stat) == 0) {
    if (S_ISLNK(destination_stat.st_mode)) {
      char resolved[PATH_MAX];
      if (realpath(path, resolved) == null) return false;
      return write_file_atomically(resolved, content, size, create_mode);
    }
    if (!S_ISREG(destination_stat.st_mode)) {
      errno = EINVAL;
      return false;
    }
    if ((destination_stat.st_mode & 0222) == 0
        || access(path, W_OK) != 0) {
      errno = EACCES;
      return false;
    }
    existing_mode = destination_stat.st_mode & 07777;
  } else if (errno != ENOENT) {
    return false;
  }
#endif

  std::string temporary;
  int fd = -1;
  for (int attempt = 0; attempt < 100 && fd < 0; attempt++) {
    temporary = temporary_path(destination);
#ifdef TOIT_WINDOWS
    std::wstring temporary_w = wide_path(temporary.c_str());
    if (temporary_w.empty()) {
      errno = EINVAL;
      return false;
    }
    fd = _wopen(temporary_w.c_str(),
                O_WRONLY | O_CREAT | O_EXCL | O_BINARY,
                create_mode);
#else
    fd = open(temporary.c_str(),
              O_WRONLY | O_CREAT | O_EXCL | O_BINARY,
              create_mode);
#endif
    if (fd < 0 && errno != EEXIST) return false;
  }
  if (fd < 0) return false;

  bool succeeded = true;
  size_t written = 0;
  while (written < size) {
#ifdef TOIT_WINDOWS
    size_t remaining = size - written;
    unsigned int chunk = remaining > INT_MAX
        ? INT_MAX
        : static_cast<unsigned int>(remaining);
    int result = _write(fd, content + written, chunk);
#else
    size_t remaining = size - written;
    size_t chunk = remaining > SSIZE_MAX ? SSIZE_MAX : remaining;
    ssize_t result = write(fd, content + written, chunk);
#endif
    if (result < 0 && errno == EINTR) continue;
    if (result <= 0) {
      succeeded = false;
      break;
    }
    written += result;
  }

  if (succeeded && existing_mode >= 0) {
#ifdef TOIT_WINDOWS
    std::wstring temporary_w = wide_path(temporary.c_str());
    succeeded = !temporary_w.empty()
        && _wchmod(temporary_w.c_str(), existing_mode) == 0;
#else
    succeeded = fchmod(fd, existing_mode) == 0;
#endif
  }
#ifdef TOIT_WINDOWS
  if (succeeded) succeeded = _commit(fd) == 0;
  if (_close(fd) != 0) succeeded = false;
#else
  if (succeeded) succeeded = fsync(fd) == 0;
  if (close(fd) != 0) succeeded = false;
#endif

  if (succeeded) succeeded = replace_file(temporary, destination);
  if (!succeeded) {
    int failure_errno = errno;
#ifdef TOIT_WINDOWS
    std::wstring temporary_w = wide_path(temporary.c_str());
    if (!temporary_w.empty()) _wunlink(temporary_w.c_str());
#else
    unlink(temporary.c_str());
#endif
    errno = failure_errno;
  }
  return succeeded;
}

} // namespace toit
