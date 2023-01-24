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

#include "top.h"

#if defined(TOIT_WINDOWS)

#include "objects.h"
#include "primitive_file.h"
#include "primitive.h"
#include "process.h"

#include <dirent.h>
#include <cerrno>
#include <fcntl.h>
#include <rpc.h>     // For rpcdce.h.
#include <rpcdce.h>  // For UuidCreate.
#include <sys/param.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <windows.h>
#include <pathcch.h>
#include <shlwapi.h>

#include "objects_inline.h"

#include "error_win.h"

namespace toit {

MODULE_IMPLEMENTATION(file, MODULE_FILE)

class AutoCloser {
 public:
  explicit AutoCloser(int fd) : fd_(fd) {}
  ~AutoCloser() {
    if (fd_ >= 0) {
      close(fd_);
    }
  }

  int clear() {
    int tmp = fd_;
    fd_ = -1;
    return tmp;
  }

 private:
  int fd_;
};

// For Posix-like calls, including socket calls.
static Object* return_open_error(Process* process, int err) {
  if (err == EPERM || err == EACCES || err == EROFS) PERMISSION_DENIED;
  if (err == EMFILE || err == ENFILE || err == ENOSPC) QUOTA_EXCEEDED;
  if (err == EEXIST) ALREADY_EXISTS;
  if (err == EINVAL || err == EISDIR || err == ENAMETOOLONG) INVALID_ARGUMENT;
  if (err == ENODEV || err == ENOENT || err == ENOTDIR) FILE_NOT_FOUND;
  if (err == ENOMEM) MALLOC_FAILED;
  OTHER_ERROR;
}

// Coordinate with utils.toit.
static const int FILE_RDONLY = 1;
static const int FILE_WRONLY = 2;
static const int FILE_RDWR = 3;
static const int FILE_APPEND = 4;
static const int FILE_CREAT = 8;
static const int FILE_TRUNC = 0x10;

static const int FILE_ST_DEV = 0;
static const int FILE_ST_INO = 1;
static const int FILE_ST_MODE = 2;
static const int FILE_ST_TYPE = 3;
static const int FILE_ST_NLINK = 4;
static const int FILE_ST_UID = 5;
static const int FILE_ST_GID = 6;
static const int FILE_ST_SIZE = 7;
static const int FILE_ST_ATIME = 8;
static const int FILE_ST_MTIME = 9;
static const int FILE_ST_CTIME = 10;

const char* current_dir(Process* process) {
  const char* current_directory = process->current_directory();
  if (current_directory) return current_directory;
  DWORD length = GetCurrentDirectory(0, NULL);
  if (length == 0) {
    FATAL("Failed to get current dir");
  }
  current_directory = reinterpret_cast<char*>(malloc(length));
  if (!current_directory) return null;
  if (GetCurrentDirectory(length, const_cast<char*>(current_directory)) == 0) {
    FATAL("Failed to get current dir");
  }
  process->set_current_directory(current_directory);
  return current_directory;
}

HeapObject* get_relative_path(Process* process, const char* pathname, char* output) {
  size_t pathname_length = strlen(pathname);

  // Poor man's version. For better platform handling, use UNICODE and PathCchAppendEx.
  if (pathname[0] == '\\' ||
      (pathname_length > 2 && pathname[1] == ':' && (pathname[2] == '\\' || pathname[2] == '/'))) {
    if (GetFullPathName(pathname, MAX_PATH, output, NULL) == 0) WINDOWS_ERROR;
  } else {
    const char* current_directory = current_dir(process);
    if (!current_directory) MALLOC_FAILED;
    char temp[MAX_PATH];
    if (snprintf(temp, MAX_PATH, "%s\\%s", current_directory, pathname) >= MAX_PATH) INVALID_ARGUMENT;
    if (GetFullPathName(temp, MAX_PATH, output, NULL) == 0) WINDOWS_ERROR;
  }
  return null;
}

PRIMITIVE(open) {
  ARGS(cstring, pathname, int, flags, int, mode);
  char path[MAX_PATH];
  auto error = get_relative_path(process, pathname, path);
  if (error) return error;

  int os_flags = _O_BINARY;
  if ((flags & FILE_RDWR) == FILE_RDONLY) os_flags |= _O_RDONLY;
  else if ((flags & FILE_RDWR) == FILE_WRONLY) os_flags |= _O_WRONLY;
  else if ((flags & FILE_RDWR) == FILE_RDWR) os_flags |= _O_RDWR;
  else INVALID_ARGUMENT;
  if ((flags & FILE_APPEND) != 0) os_flags |= _O_APPEND;
  if ((flags & FILE_CREAT) != 0) os_flags |= _O_CREAT;
  if ((flags & FILE_TRUNC) != 0) os_flags |= _O_TRUNC;
  int fd = _open(path, os_flags, mode);
  AutoCloser closer(fd);
  if (fd < 0) return return_open_error(process, errno);
  struct stat statbuf{};
  int res = fstat(fd, &statbuf);
  if (res < 0) {
    if (errno == ENOMEM) MALLOC_FAILED;
    OTHER_ERROR;
  }
  int type = statbuf.st_mode & S_IFMT;
  if (type != S_IFREG) {
    // An attempt to open something with file::open that is not a regular file
    // with open (eg a pipe, a socket, a directory).  We forbid this because
    // these file descriptors can block, and this API does not support
    // blocking.
    if (strcmpi(R"(\\.\NUL)", pathname) != 0) INVALID_ARGUMENT;
  }
  closer.clear();
  return Smi::from(fd);
}

class Directory : public SimpleResource {
 public:
  TAG(Directory);
  explicit Directory(SimpleResourceGroup* resource_group, const char* path) : SimpleResource(resource_group) {
    snprintf(path_, MAX_PATH, "%s\\*", path);
  }

  const char* path() { return path_; }
  WIN32_FIND_DATA* find_file_data() { return &find_file_data_; }
  void set_dir_handle(HANDLE dir_handle) { dir_handle_ = dir_handle; }
  HANDLE dir_handle() { return dir_handle_; }
  bool done() const { return done_; }
  void set_done(bool done) { done_ = done; }

 private:
  char path_[MAX_PATH]{};
  WIN32_FIND_DATA find_file_data_{};
  HANDLE dir_handle_ = INVALID_HANDLE_VALUE;
  bool done_ = false;
};

PRIMITIVE(opendir) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(opendir2) {
  ARGS(SimpleResourceGroup, group, cstring, pathname);
  char path[MAX_PATH];
  auto error = get_relative_path(process, pathname, path);
  if (error) return error;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  auto directory = _new Directory(group, path);
  if (!directory) MALLOC_FAILED;

  HANDLE dir_handle = FindFirstFile(directory->path(), directory->find_file_data());
  if (dir_handle == INVALID_HANDLE_VALUE) {
    if (GetLastError() == ERROR_NO_MORE_FILES) {
      directory->set_done(true);
    } else {
      delete directory;
      WINDOWS_ERROR;
    }
  }

  directory->set_dir_handle(dir_handle);

  proxy->set_external_address(directory);

  return proxy;
}

PRIMITIVE(readdir) {
  ARGS(ByteArray, directory_proxy);

  if (!directory_proxy->has_external_address()) WRONG_TYPE;

  auto directory = directory_proxy->as_external<Directory>();

  if (directory->done()) return process->program()->null_object();

  ByteArray* proxy = process->object_heap()->allocate_proxy(true);
  if (proxy == null) {
    ALLOCATION_FAILED;
  }

  size_t len = strlen(directory->find_file_data()->cFileName);
  if (!Utils::is_valid_utf_8(unsigned_cast(directory->find_file_data()->cFileName), static_cast<int>(len))) {
    ILLEGAL_UTF_8;
  }

  process->register_external_allocation(static_cast<int>(len));

  auto backing = unvoid_cast<uint8*>(malloc(len));  // Can't fail on non-embedded.
  if (!backing) MALLOC_FAILED;

  memcpy(backing, unsigned_cast(directory->find_file_data()->cFileName), len);
  proxy->set_external_address(static_cast<int>(len), backing);

  if (FindNextFile(directory->dir_handle(), directory->find_file_data()) == 0) {
    if (GetLastError() == ERROR_NO_MORE_FILES) directory->set_done(true);
    else WINDOWS_ERROR;
  };

  return proxy;
}

PRIMITIVE(closedir) {
  ARGS(ByteArray, proxy);

  if (!proxy->has_external_address()) WRONG_TYPE;
  auto directory = proxy->as_external<Directory>();

  FindClose(directory->dir_handle());

  directory->resource_group()->unregister_resource(directory);

  proxy->clear_external_address();
  return process->program()->null_object();
}

PRIMITIVE(read) {
  ARGS(int, fd);

  ByteArray* byte_array = process->allocate_byte_array(4000, /*force_external*/ true);
  if (byte_array == null) ALLOCATION_FAILED;

  ByteArray::Bytes bytes(ByteArray::cast(byte_array));
  ssize_t buffer_fullness = 0;
  while (buffer_fullness < bytes.length()) {
    ssize_t bytes_read = _read(fd, bytes.address() + buffer_fullness, bytes.length() - buffer_fullness);
    if (bytes_read < 0) {
      if (errno == EINTR) continue;
      if (errno == EINVAL || errno == EISDIR || errno == EBADF) INVALID_ARGUMENT;
    }
    buffer_fullness += bytes_read;
    if (bytes_read == 0) break;
  }

  if (buffer_fullness == 0) {
    return process->program()->null_object();
  }

  byte_array->resize_external(process, buffer_fullness);
  return byte_array;
}

PRIMITIVE(write) {
  ARGS(int, fd, Blob, bytes, int, from, int, to);
  if (from > to || from < 0 || to > bytes.length()) OUT_OF_BOUNDS;
  ssize_t current_offset = from;
  while (current_offset < to) {
    ssize_t bytes_written = write(fd, bytes.address() + current_offset, to - current_offset);
    if (bytes_written < 0) {
      if (errno == EINTR) continue;
      if (errno == EINVAL || errno == EBADF) INVALID_ARGUMENT;
      OTHER_ERROR;
    }
    current_offset += bytes_written;
  }
  return Smi::from(current_offset - from);
}

PRIMITIVE(close) {
  ARGS(int, fd);
  while (true) {
    int result = close(fd);
    if (result < 0) {
      if (GetFileType(reinterpret_cast<HANDLE>(fd)) == FILE_TYPE_PIPE && errno == EBADF) {
        return process->program()->null_object(); // Ignore already closed on PIPEs
      }
      if (errno == EINTR) continue;
      if (errno == EBADF) ALREADY_CLOSED;
      if (errno == ENOSPC) QUOTA_EXCEEDED;
      OTHER_ERROR;
    }
    return process->program()->null_object();
  }
}

Object* time_stamp(Process* process, time_t time) {
  return Primitive::integer(time * 1000000000ll, process);
}

// Returns null for entries that do not exist.
// Otherwise returns an array with indices from the FILE_ST_xxx constants.
PRIMITIVE(stat) {
  ARGS(cstring, pathname, bool, follow_links);
  USE(follow_links);
  char path[MAX_PATH];
  auto error = get_relative_path(process, pathname, path);
  if (error) return error;

  struct stat statbuf{};
  int result = stat(path, &statbuf);
  if (result < 0) {
    if (errno == ENOENT || errno == ENOTDIR) {
      return process->program()->null_object();
    }
    return return_open_error(process, errno);
  }

  Array* array = process->object_heap()->allocate_array(11, Smi::zero());
  if (!array) ALLOCATION_FAILED;

  int type = (statbuf.st_mode & S_IFMT) >> 13;
  int mode = (statbuf.st_mode & 0x1ff);

  Object* device_id = Primitive::integer(statbuf.st_dev, process);
  if (Primitive::is_error(device_id)) return device_id;

  Object* inode = Primitive::integer(statbuf.st_ino, process);
  if (Primitive::is_error(inode)) return inode;

  Object* size = Primitive::integer(statbuf.st_size, process);
  if (Primitive::is_error(size)) return size;

  Object* atime = time_stamp(process, statbuf.st_atime);
  if (Primitive::is_error(atime)) return atime;

  Object* mtime = time_stamp(process, statbuf.st_mtime);
  if (Primitive::is_error(mtime)) return mtime;

  Object* ctime = time_stamp(process, statbuf.st_ctime);
  if (Primitive::is_error(ctime)) return ctime;

  array->at_put(FILE_ST_DEV, device_id);
  array->at_put(FILE_ST_INO, inode);
  array->at_put(FILE_ST_MODE, Smi::from(mode));
  array->at_put(FILE_ST_TYPE, Smi::from(type));
  array->at_put(FILE_ST_NLINK, Smi::from(statbuf.st_nlink));
  array->at_put(FILE_ST_UID, Smi::from(statbuf.st_uid));
  array->at_put(FILE_ST_GID, Smi::from(statbuf.st_gid));
  array->at_put(FILE_ST_SIZE, size);
  array->at_put(FILE_ST_ATIME, atime);
  array->at_put(FILE_ST_MTIME, mtime);
  array->at_put(FILE_ST_CTIME, ctime);

  return array;
}

PRIMITIVE(unlink) {
  ARGS(cstring, pathname);
  char path[MAX_PATH];
  auto error = get_relative_path(process, pathname, path);
  if (error) return error;

  int result = unlink(path);
  if (result < 0) return return_open_error(process, errno);
  return process->program()->null_object();
}

PRIMITIVE(rmdir) {
  ARGS(cstring, pathname);
  char path[MAX_PATH];
  auto error = get_relative_path(process, pathname, path);
  if (error) return error;

  if (RemoveDirectory(path) == 0) WINDOWS_ERROR;
  return process->program()->null_object();
}

PRIMITIVE(rename) {
  ARGS(cstring, old_name, cstring, new_name);
  int result = rename(old_name, new_name);
  if (result < 0) return return_open_error(process, errno);
  return process->program()->null_object();
}

PRIMITIVE(chdir) {
  ARGS(cstring, pathname);
  size_t pathname_length = strlen(pathname);

  if (pathname_length == 0) INVALID_ARGUMENT;

  char path[MAX_PATH];
  auto error = get_relative_path(process, pathname, path);
  if (error) return error;

  char* copy = strdup(path);
  if (!copy) MALLOC_FAILED;

  process->set_current_directory(copy);

  return process->program()->null_object();
}

PRIMITIVE(mkdir) {
  ARGS(cstring, pathname, int, mode);
  char path[MAX_PATH];
  auto error = get_relative_path(process, pathname, path);
  if (error) return error;

  int result = CreateDirectory(path, NULL);
  if (result == 0) WINDOWS_ERROR;
  return process->program()->null_object();
}

PRIMITIVE(mkdtemp) {
  ARGS(cstring, prefix);
  DWORD ret;

  bool in_standard_tmp_dir = false;
  if (strncmp(prefix, "/tmp/", 5) == 0) {
    in_standard_tmp_dir = true;
    prefix += 5;
  }

  char accumulator = 0;
  for (const char* p = prefix; *p; p++) accumulator |= *p;
  if (accumulator & 0x80) INVALID_ARGUMENT;  // Only supports ASCII prefix.

  static const int UUID_TEXT_LENGTH = 32;

  char temp_dir_name[MAX_PATH];
  temp_dir_name[0] = '\0';

  if (in_standard_tmp_dir) {
    // Get the location of the Windows temp directory.
    ret = GetTempPath(MAX_PATH, temp_dir_name);
    if (ret + 2 > MAX_PATH) INVALID_ARGUMENT;
    if (ret == 0) WINDOWS_ERROR;
    if (temp_dir_name[strlen(temp_dir_name)-1] != '\\') {
      strncat(temp_dir_name, "\\", strlen(temp_dir_name) - 1);
    }
  }
  if (strlen(temp_dir_name) + UUID_TEXT_LENGTH + strlen(prefix) + 1 > MAX_PATH) INVALID_ARGUMENT;

  UUID uuid;
  ret = UuidCreate(&uuid);
  if (ret != RPC_S_OK && ret != RPC_S_UUID_LOCAL_ONLY) OTHER_ERROR;

  unsigned char* uuid_string;
  ret = UuidToString(&uuid, &uuid_string);
  strncat(temp_dir_name, prefix, MAX_PATH - strlen(temp_dir_name) - 1);
  strncat(temp_dir_name, char_cast(uuid_string), MAX_PATH - strlen(temp_dir_name) - 1);
  RpcStringFree(&uuid_string);

  uword total_len = strlen(temp_dir_name);

  Object* result = process->allocate_byte_array(static_cast<int>(total_len));
  if (result == null) ALLOCATION_FAILED;

  int posix_result = mkdir(temp_dir_name);
  if (posix_result < 0) return return_open_error(process, errno);

  memcpy(ByteArray::Bytes(ByteArray::cast(result)).address(), temp_dir_name, total_len);

  return result;
}

PRIMITIVE(is_open_file) {
  ARGS(int, fd);
  int result = lseek(fd, 0, SEEK_CUR);
  if (result < 0) {
    if (errno == ESPIPE || errno == EINVAL || errno == EBADF) {
      return process->program()->false_object();
    }
    OTHER_ERROR;
  }
  return process->program()->true_object();
}

PRIMITIVE(realpath) {
  ARGS(cstring, filename);
  DWORD result_length = GetFullPathName(filename, 0, NULL, NULL);
  if (result_length == 0) WINDOWS_ERROR;

  char* c_result = reinterpret_cast<char*>(malloc(result_length));
  if (!c_result) MALLOC_FAILED;

  if (GetFullPathName(filename, result_length, c_result, NULL) == 0) {
    free(c_result);
    WINDOWS_ERROR;
  }
  // The toit package expects a null value when the file does not exist. Win32 does not detect his in GetFile
  if (!PathFileExists(c_result)) {
    free(c_result);
    return process->program()->null_object();
  }

  String* result = process->allocate_string(c_result);
  if (result == null) {
    free(c_result);
    ALLOCATION_FAILED;
  }

  return result;
}

PRIMITIVE(cwd) {
  const char* current_directory = current_dir(process);
  if (current_directory == null) MALLOC_FAILED;

  String* result = process->allocate_string(current_directory);
  if (result == null) ALLOCATION_FAILED;

  return result;
}

}

#endif  // TOIT_WINDOWS.
