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

const wchar_t* current_dir(Process* process) {
  const wchar_t* current_directory = process->current_directory();
  if (current_directory) return current_directory;
  word length = GetCurrentDirectoryW(0, NULL);
  if (length == 0) {
    FATAL("Failed to get current dir");
  }
  current_directory = unvoid_cast<wchar_t*>(malloc(length * sizeof(wchar_t)));
  if (GetCurrentDirectoryW(length, const_cast<wchar_t*>(current_directory)) == 0) {
    FATAL("Failed to get current dir");
  }
  process->set_current_directory(current_directory);
  return current_directory;
}

HeapObject* get_absolute_path(Process* process, const wchar_t* pathname, wchar_t* output) {
  size_t pathname_length = wcslen(pathname);

  // Poor man's version. For better platform handling, use PathCchAppendEx.
  // TODO(florian): we should probably use PathCchCombine here. That would remove
  // all the special checks.

  if (!PathIsRelativeW(pathname)) {
    if (GetFullPathNameW(pathname, MAX_PATH, output, NULL) == 0) WINDOWS_ERROR;
    return null;
  }

  const wchar_t* current_directory = current_dir(process);

  // Check if the path is rooted. On Windows paths might not be absolute, but
  // relative to the drive/root of the current working directory.
  // For example the path `\foo\bar` is a rooted path which is relative to
  // the drive of the current working directory.
  wchar_t root[MAX_PATH];
  const wchar_t* relative_to = null;
  if (pathname_length > 0 && (pathname[0] == '\\' || pathname[0] == '/')) {
    // Relative to the root of the drive/share.
    // For example '\foo\bar' is rooted to the current directory's drive.
    wcsncpy(root, current_directory, MAX_PATH);
    root[MAX_PATH - 1] = '\0';
    if (!PathStripToRootW(root)) WINDOWS_ERROR;
    relative_to = root;
  } else {
    relative_to = current_directory;
  }

  wchar_t temp[MAX_PATH];
  if (snwprintf(temp, MAX_PATH, L"%ls\\%ls", relative_to, pathname) >= MAX_PATH) INVALID_ARGUMENT;
  if (GetFullPathNameW(temp, MAX_PATH, output, NULL) == 0) WINDOWS_ERROR;
  return null;
}

// Filesystem primitives should generally use this, since the chdir primitive
// merely changes a string representing the current directory.
#define BLOB_TO_ABSOLUTE_PATH(result, blob)                                 \
  WideCharAllocationManager allocation_##result(process);                   \
  wchar_t* wchar_##result = allocation_##result.to_wcs(&blob);              \
  wchar_t result[MAX_PATH];                                                 \
  auto error_##result = get_absolute_path(process, wchar_##result, result); \
  if (error_##result) return error_##result

PRIMITIVE(open) {
  ARGS(StringOrSlice, pathname, int, flags, int, mode);
  BLOB_TO_ABSOLUTE_PATH(path, pathname);

  int os_flags = _O_BINARY;
  if ((flags & FILE_RDWR) == FILE_RDONLY) os_flags |= _O_RDONLY;
  else if ((flags & FILE_RDWR) == FILE_WRONLY) os_flags |= _O_WRONLY;
  else if ((flags & FILE_RDWR) == FILE_RDWR) os_flags |= _O_RDWR;
  else INVALID_ARGUMENT;
  if ((flags & FILE_APPEND) != 0) os_flags |= _O_APPEND;
  if ((flags & FILE_CREAT) != 0) os_flags |= _O_CREAT;
  if ((flags & FILE_TRUNC) != 0) os_flags |= _O_TRUNC;
  int fd = _wopen(path, os_flags, mode);
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
    if (_wcsicmp(L"\\\\.\\NUL", path) != 0) INVALID_ARGUMENT;
  }
  closer.clear();
  return Smi::from(fd);
}

class Directory : public SimpleResource {
 public:
  TAG(Directory);
  explicit Directory(SimpleResourceGroup* resource_group, const wchar_t* path) : SimpleResource(resource_group) {
    snwprintf(path_, MAX_PATH, L"%ls\\*", path);
  }

  const wchar_t* path() { return path_; }
  WIN32_FIND_DATAW* find_file_data() { return &find_file_data_; }
  void set_dir_handle(HANDLE dir_handle) { dir_handle_ = dir_handle; }
  HANDLE dir_handle() { return dir_handle_; }
  bool done() const { return done_; }
  void set_done(bool done) { done_ = done; }

 private:
  wchar_t path_[MAX_PATH]{};
  WIN32_FIND_DATAW find_file_data_{};
  HANDLE dir_handle_ = INVALID_HANDLE_VALUE;
  bool done_ = false;
};

PRIMITIVE(opendir) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(opendir2) {
  ARGS(SimpleResourceGroup, group, StringOrSlice, pathname);
  BLOB_TO_ABSOLUTE_PATH(path, pathname);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  auto directory = _new Directory(group, path);

  HANDLE dir_handle = FindFirstFileW(directory->path(), directory->find_file_data());
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

  const wchar_t* utf_16 = directory->find_file_data()->cFileName;
  size_t utf_16_len = wcslen(utf_16);
  size_t utf_8_len = Utils::utf_16_to_8(utf_16, utf_16_len);

  process->register_external_allocation(static_cast<int>(utf_8_len));

  auto backing = unvoid_cast<uint8*>(malloc(utf_8_len + 1));  // Can't fail on non-embedded.

  Utils::utf_16_to_8(utf_16, utf_16_len, backing, utf_8_len);

  proxy->set_external_address(static_cast<int>(utf_8_len), backing);

  if (FindNextFileW(directory->dir_handle(), directory->find_file_data()) == 0) {
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
  ARGS(StringOrSlice, pathname, bool, follow_links);
  BLOB_TO_ABSOLUTE_PATH(path, pathname);

  USE(follow_links);

  struct stat64 statbuf{};
  int result = _wstat64(path, &statbuf);
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
  ARGS(StringOrSlice, pathname);
  BLOB_TO_ABSOLUTE_PATH(path, pathname);

  int result = _wunlink(path);
  if (result < 0) return return_open_error(process, errno);
  return process->program()->null_object();
}

PRIMITIVE(rmdir) {
  ARGS(StringOrSlice, pathname);
  BLOB_TO_ABSOLUTE_PATH(path, pathname);

  if (RemoveDirectoryW(path) == 0) WINDOWS_ERROR;
  return process->program()->null_object();
}

PRIMITIVE(rename) {
  ARGS(StringOrSlice, old_name_blob, StringOrSlice, new_name_blob);
  BLOB_TO_ABSOLUTE_PATH(old_name, old_name_blob);
  BLOB_TO_ABSOLUTE_PATH(new_name, new_name_blob);
  int result = _wrename(old_name, new_name);
  if (result < 0) return return_open_error(process, errno);
  return process->program()->null_object();
}

PRIMITIVE(chdir) {
  ARGS(StringOrSlice, pathname);
  if (pathname.length() == 0) INVALID_ARGUMENT;
  BLOB_TO_ABSOLUTE_PATH(path, pathname);

  wchar_t* copy = wcsdup(path);

  process->set_current_directory(copy);

  return process->program()->null_object();
}

PRIMITIVE(mkdir) {
  ARGS(StringOrSlice, pathname, int, mode);
  BLOB_TO_ABSOLUTE_PATH(path, pathname);

  int result = CreateDirectoryW(path, NULL);
  if (result == 0) WINDOWS_ERROR;
  return process->program()->null_object();
}

PRIMITIVE(mkdtemp) {
  ARGS(StringOrSlice, prefix_blob);
  DWORD ret;

  WideCharAllocationManager allocation(process);
  wchar_t* prefix = allocation.to_wcs(&prefix_blob);

  bool in_standard_tmp_dir = false;
  if (wcsncmp(prefix, L"/tmp/", 5) == 0) {
    in_standard_tmp_dir = true;
    prefix += 5;
  }

  static const int UUID_TEXT_LENGTH = 32;

  wchar_t temp_dir_name[MAX_PATH];
  temp_dir_name[0] = '\0';

  if (in_standard_tmp_dir) {
    // Get the location of the Windows temp directory.
    ret = GetTempPathW(MAX_PATH, temp_dir_name);
    if (ret + 2 > MAX_PATH) INVALID_ARGUMENT;
    if (ret == 0) WINDOWS_ERROR;
    if (temp_dir_name[wcslen(temp_dir_name) - 1] != '\\') {
      wcsncat(temp_dir_name, L"\\", wcslen(temp_dir_name) - 1);
    }
  }
  if (wcslen(temp_dir_name) + UUID_TEXT_LENGTH + wcslen(prefix) + 1 > MAX_PATH) INVALID_ARGUMENT;

  UUID uuid;
  ret = UuidCreate(&uuid);
  if (ret != RPC_S_OK && ret != RPC_S_UUID_LOCAL_ONLY) OTHER_ERROR;

  uint16* uuid_string;
  ret = UuidToStringW(&uuid, &uuid_string);
  wcsncat(temp_dir_name, prefix, MAX_PATH - wcslen(temp_dir_name) - 1);
  wcsncat(temp_dir_name, reinterpret_cast<wchar_t*>(uuid_string), MAX_PATH - wcslen(temp_dir_name) - 1);
  RpcStringFreeW(&uuid_string);

  uword total_len = Utils::utf_16_to_8(temp_dir_name, wcslen(temp_dir_name));

  ByteArray* result = process->allocate_byte_array(static_cast<int>(total_len));
  if (result == null) ALLOCATION_FAILED;

  ByteArray::Bytes blob(result);

  int posix_result = CreateDirectoryW(temp_dir_name, null);
  if (posix_result < 0) return return_open_error(process, errno);

  Utils::utf_16_to_8(temp_dir_name, wcslen(temp_dir_name), blob.address(), blob.length());

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
  ARGS(StringOrSlice, filename_blob);
  WideCharAllocationManager allocation(process);
  wchar_t* filename = allocation.to_wcs(&filename_blob);
  DWORD result_length = GetFullPathNameW(filename, 0, NULL, NULL);
  if (result_length == 0) WINDOWS_ERROR;

  WideCharAllocationManager allocation2(process);
  wchar_t* w_result = allocation2.wcs_alloc(result_length);

  if (GetFullPathNameW(filename, result_length, w_result, NULL) == 0) {
    WINDOWS_ERROR;
  }

  // The toit package expects a null value when the file does not exist. Win32 does not detect this in GetFile
  if (!PathFileExistsW(w_result)) {
    return process->program()->null_object();
  }

  String* result = process->allocate_string(w_result);
  if (result == null) ALLOCATION_FAILED;

  return result;
}

PRIMITIVE(cwd) {
  Object* result = process->allocate_string(current_dir(process));
  if (result == null) ALLOCATION_FAILED;
  return result;
}

}

#endif  // TOIT_WINDOWS.
