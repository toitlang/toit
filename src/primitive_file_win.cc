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

// TODO(mikkel/florian) Figure out a better way to do this for cross builds
#ifdef _WIN32_WINNT
#undef _WIN32_WINNT
#endif
#define _WIN32_WINNT 0xa000

#include "objects.h"
#include "primitive_file.h"
#include "primitive.h"
#include "process.h"

#include <dirent.h>
#include <cerrno>
#include <rpc.h>     // For rpcdce.h.
#include <rpcdce.h>  // For UuidCreate.
#include <sys/stat.h>
#include <sys/types.h>
#include <windows.h>

#include <pathcch.h>
#include <shlwapi.h>
#include <fileapi.h>
#include <ntdef.h>

#include "objects_inline.h"

#include "error_win.h"

namespace toit {

MODULE_IMPLEMENTATION(file, MODULE_FILE)

class AutoCloser {
 public:
  explicit AutoCloser(HANDLE handle) : handle_(handle) {}
  ~AutoCloser() {
    if (handle_ != INVALID_HANDLE_VALUE) {
      CloseHandle(handle_);
    }
  }

  HANDLE clear() {
    HANDLE tmp = handle_;
    handle_ = INVALID_HANDLE_VALUE;
    return tmp;
  }

 private:
  HANDLE handle_;
};

// For Posix-like calls, including socket calls.
static Object* return_open_error(Process* process, int err) {
  if (err == EPERM || err == EACCES || err == EROFS) FAIL(PERMISSION_DENIED);
  if (err == EMFILE || err == ENFILE || err == ENOSPC) FAIL(QUOTA_EXCEEDED);
  if (err == EEXIST) FAIL(ALREADY_EXISTS);
  if (err == EINVAL || err == EISDIR || err == ENAMETOOLONG) FAIL(INVALID_ARGUMENT);
  if (err == ENODEV || err == ENOENT || err == ENOTDIR) FAIL(FILE_NOT_FOUND);
  if (err == ENOMEM) FAIL(MALLOC_FAILED);
  FAIL(ERROR);
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

static const int UNIX_CHARACTER_DEVICE = 1;
static const int UNIX_DIRECTORY = 2;
static const int UNIX_REGULAR_FILE = 4;
static const int UNIX_SYMBOLIC_LINK = 5;
static const int UNIX_SOCKET = 6;
static const int UNIX_DIRECTORY_SYMBOLIC_LINK = 7;

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

Object* get_absolute_path(Process* process, const wchar_t* pathname, wchar_t* output, const wchar_t* used_for_relative) {
  size_t pathname_length = wcslen(pathname);

  // Poor man's version. For better platform handling, use PathCchAppendEx.
  // TODO(florian): we should probably use PathCchCombine here. That would remove
  // all the special checks.

  if (!PathIsRelativeW(pathname)) {
    if (GetFullPathNameW(pathname, MAX_PATH, output, NULL) == 0) WINDOWS_ERROR;
    return null;
  }

  if (used_for_relative == null) used_for_relative = current_dir(process);

  // Check if the path is rooted. On Windows paths might not be absolute, but
  // relative to the drive/root of the current working directory.
  // For example the path `\foo\bar` is a rooted path which is relative to
  // the drive of the current working directory.
  wchar_t root[MAX_PATH];
  const wchar_t* relative_to = null;
  if (pathname_length > 0 && (pathname[0] == '\\' || pathname[0] == '/')) {
    // Relative to the root of the drive/share.
    // For example '\foo\bar' is rooted to the current directory's drive.
    wcsncpy(root, used_for_relative, MAX_PATH);
    root[MAX_PATH - 1] = '\0';
    if (!PathStripToRootW(root)) WINDOWS_ERROR;
    relative_to = root;
  } else {
    relative_to = used_for_relative;
  }

  wchar_t temp[MAX_PATH];
  if (snwprintf(temp, MAX_PATH, L"%ls\\%ls", relative_to, pathname) >= MAX_PATH) FAIL(INVALID_ARGUMENT);
  if (GetFullPathNameW(temp, MAX_PATH, output, NULL) == 0) WINDOWS_ERROR;
  return null;
}

PRIMITIVE(open) {
  ARGS(WindowsPath, path, int, flags, int, mode);

  DWORD os_flags = 0;
  if ((flags & FILE_RDWR) == FILE_RDONLY) os_flags |= GENERIC_READ;
  else if ((flags & FILE_RDWR) == FILE_WRONLY) os_flags |= GENERIC_WRITE;
  else if ((flags & FILE_RDWR) == FILE_RDWR) os_flags |= GENERIC_READ | GENERIC_WRITE;
  else FAIL(INVALID_ARGUMENT);

  DWORD open_flags = OPEN_EXISTING;
  if ((flags & FILE_CREAT) != 0 && (flags & FILE_TRUNC) != 0) open_flags = CREATE_ALWAYS;
  else if ((flags & FILE_CREAT) != 0) open_flags = CREATE_NEW;

  HANDLE handle = CreateFileW(path, os_flags, FILE_SHARE_DELETE | FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                          open_flags, FILE_ATTRIBUTE_NORMAL, NULL);

  if (handle == INVALID_HANDLE_VALUE) WINDOWS_ERROR;
  AutoCloser closer(handle);

  DWORD type = GetFileType(handle);
  if (type != FILE_TYPE_DISK and type != FILE_TYPE_REMOTE) {
    // An attempt to open something with file::open that is not a regular file
    // with open (eg a pipe, a socket, a directory).  We forbid this because
    // these file descriptors can block, and this API does not support
    // blocking.
    if (_wcsicmp(L"\\\\.\\NUL", path) != 0) FAIL(INVALID_ARGUMENT);
  }
  closer.clear();
  return Smi::from(reinterpret_cast<word>(handle));
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
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(opendir2) {
  ARGS(SimpleResourceGroup, group, WindowsPath, path);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto directory = _new Directory(group, path);

  HANDLE dir_handle = FindFirstFileW(directory->path(), directory->find_file_data());
  if (dir_handle == INVALID_HANDLE_VALUE) {
    if (GetLastError() == ERROR_NO_MORE_FILES) {
      directory->set_done(true);
    } else {
      group->unregister_resource(directory);
      WINDOWS_ERROR;
    }
  }

  directory->set_dir_handle(dir_handle);

  proxy->set_external_address(directory);

  return proxy;
}

PRIMITIVE(readdir) {
  ARGS(ByteArray, directory_proxy);

  if (!directory_proxy->has_external_address()) FAIL(WRONG_OBJECT_TYPE);

  auto directory = directory_proxy->as_external<Directory>();

  if (directory->done()) return process->null_object();

  ByteArray* proxy = process->object_heap()->allocate_proxy(true);
  if (proxy == null) FAIL(ALLOCATION_FAILED);

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

  if (!proxy->has_external_address()) FAIL(WRONG_OBJECT_TYPE);
  auto directory = proxy->as_external<Directory>();

  FindClose(directory->dir_handle());

  directory->resource_group()->unregister_resource(directory);

  proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(read) {
  ARGS(int, fd);
  auto handle = reinterpret_cast<HANDLE>(fd);
  const int SIZE = 64 * KB;

  AllocationManager allocation(process);
  uint8* buffer = allocation.alloc(SIZE);
  if (!buffer) FAIL(ALLOCATION_FAILED);

  ByteArray* result = process->object_heap()->allocate_external_byte_array(
      SIZE, buffer, true /* dispose */, false /* clear */);
  if (!result) FAIL(ALLOCATION_FAILED);
  allocation.keep_result();

  ssize_t buffer_fullness = 0;
  while (buffer_fullness < SIZE) {
    DWORD bytes_read;
    BOOL success = ReadFile(handle,buffer + buffer_fullness, SIZE - buffer_fullness, &bytes_read, NULL);
    if (!success) WINDOWS_ERROR;
    buffer_fullness += bytes_read;
    if (bytes_read == 0) break;
  }

  if (buffer_fullness == 0) {
    return process->null_object();
  }

  if (buffer_fullness < SIZE) {
    result->resize_external(process, buffer_fullness);
  }
  return result;
}

PRIMITIVE(write) {
  ARGS(int, fd, Blob, bytes, int, from, int, to);
  auto handle = reinterpret_cast<HANDLE>(fd);
  if (from > to || from < 0 || to > bytes.length()) FAIL(OUT_OF_BOUNDS);
  ssize_t current_offset = from;
  while (current_offset < to) {
    DWORD bytes_written;
    BOOL success = WriteFile(handle, bytes.address() + current_offset, to - current_offset, &bytes_written, NULL);
    if (!success) WINDOWS_ERROR;
    current_offset += bytes_written;
  }
  return Smi::from(current_offset - from);
}

PRIMITIVE(close) {
  ARGS(int, fd);
  HANDLE handle = reinterpret_cast<HANDLE>(fd);
  while (true) {
    int result = CloseHandle(handle);
    if (result == 0) {
      if (GetFileType(handle) == FILE_TYPE_PIPE && GetLastError() == ERROR_INVALID_HANDLE) {
        return process->null_object(); // Ignore already closed on PIPEs
      }
      WINDOWS_ERROR;
    }
    return process->null_object();
  }
}

int64 low_high_to_int64(DWORD high, DWORD low) {
  return (static_cast<int64>(high) << 32) + low;
}

#define WINDOWS_TICKS_PER_SECOND 10000000
#define SEC_TO_UNIX_EPOCH 11644473600LL

Object* time_stamp(Process* process, FILETIME* time) {
  int64 windows_ticks = low_high_to_int64(time->dwHighDateTime, time->dwLowDateTime);
  int64 unix_ticks = (windows_ticks - SEC_TO_UNIX_EPOCH * WINDOWS_TICKS_PER_SECOND) * 100;
  return Primitive::integer(unix_ticks, process);
}

// Returns null for entries that do not exist.
// Otherwise returns an array with indices from the FILE_ST_xxx constants.
PRIMITIVE(stat) {
  ARGS(WindowsPath, path, bool, follow_links);

  DWORD attributes = FILE_FLAG_BACKUP_SEMANTICS | FILE_ATTRIBUTE_NORMAL;
  if (!follow_links) attributes |= FILE_OPEN_REPARSE_POINT;

  HANDLE handle = CreateFileW(path, 0, 0,
                              NULL, OPEN_EXISTING, attributes, NULL);

  if (handle == INVALID_HANDLE_VALUE) {
    if (GetLastError() == ERROR_FILE_NOT_FOUND ||
        GetLastError() == ERROR_PATH_NOT_FOUND ||
        GetLastError() == ERROR_INVALID_NAME) {
      return process->null_object(); // Toit code expects this to be null
    }
    WINDOWS_ERROR;
  }
  AutoCloser closer(handle);

  BY_HANDLE_FILE_INFORMATION file_info;
  BOOL success = GetFileInformationByHandle(handle, &file_info);
  if (!success) WINDOWS_ERROR;

  Array* array = process->object_heap()->allocate_array(11, Smi::zero());
  if (!array) FAIL(ALLOCATION_FAILED);

  FILE_STANDARD_INFO standard_info;
  success = GetFileInformationByHandleEx(handle, FileStandardInfo, &standard_info, sizeof(FILE_STANDARD_INFO));
  if (!success) WINDOWS_ERROR;

  int type;
  if (!follow_links && (file_info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    if (standard_info.Directory) {
      type = UNIX_DIRECTORY_SYMBOLIC_LINK;
    } else {
      type = UNIX_SYMBOLIC_LINK;
    }
  } else {
    if (standard_info.Directory) {
      type = UNIX_DIRECTORY;
    } else {
      DWORD file_type = GetFileType(handle);
      switch (file_type) { // Convert to unix enum
        case FILE_TYPE_CHAR:
          type = UNIX_CHARACTER_DEVICE;
          break;
        case FILE_TYPE_DISK:
          type = UNIX_REGULAR_FILE;
          break;
        case FILE_TYPE_PIPE:
          type = UNIX_SOCKET;
          break;
        default:
          FAIL(INVALID_ARGUMENT);
      }
    }
  }

  Object* device_id = Primitive::integer(file_info.dwVolumeSerialNumber, process);
  if (Primitive::is_error(device_id)) return device_id;

  Object* inode = Primitive::integer(low_high_to_int64(file_info.nFileIndexHigh, file_info.nFileIndexLow), process);
  if (Primitive::is_error(inode)) return inode;

  Object* size = Primitive::integer(low_high_to_int64(file_info.nFileSizeHigh, file_info.nFileSizeLow), process);
  if (Primitive::is_error(size)) return size;

  Object* atime = time_stamp(process, &file_info.ftLastAccessTime);
  if (Primitive::is_error(atime)) return atime;

  Object* mtime = time_stamp(process, &file_info.ftLastWriteTime);
  if (Primitive::is_error(mtime)) return mtime;

  Object* ctime = time_stamp(process, &file_info.ftCreationTime);
  if (Primitive::is_error(ctime)) return ctime;

  array->at_put(FILE_ST_DEV, device_id);
  array->at_put(FILE_ST_INO, inode);
  array->at_put(FILE_ST_MODE, Smi::from(file_info.dwFileAttributes));
  array->at_put(FILE_ST_TYPE, Smi::from(type));
  array->at_put(FILE_ST_NLINK, Smi::from(file_info.nNumberOfLinks));
  array->at_put(FILE_ST_UID, Smi::from(0));
  array->at_put(FILE_ST_GID, Smi::from(0));
  array->at_put(FILE_ST_SIZE, size);
  array->at_put(FILE_ST_ATIME, atime);
  array->at_put(FILE_ST_MTIME, mtime);
  array->at_put(FILE_ST_CTIME, ctime);

  return array;
}

PRIMITIVE(unlink) {
  ARGS(WindowsPath, path);

  // Remove any read-only attribute.
  SetFileAttributesW(path, FILE_ATTRIBUTE_NORMAL);
  int result = _wunlink(path);
  if (result < 0) return return_open_error(process, errno);
  return process->null_object();
}

PRIMITIVE(rmdir) {
  ARGS(WindowsPath, path);

  if (RemoveDirectoryW(path) == 0) WINDOWS_ERROR;
  return process->null_object();
}

PRIMITIVE(rename) {
  ARGS(WindowsPath, old_name, WindowsPath, new_name);
  int result = _wrename(old_name, new_name);
  if (result < 0) return return_open_error(process, errno);
  return process->null_object();
}

PRIMITIVE(chdir) {
  ARGS(WindowsPath, path);

  struct stat64 statbuf{};
  int result = _wstat64(path, &statbuf);
  if (result < 0) WINDOWS_ERROR;  // No such file or directory?
  if ((statbuf.st_mode & S_IFDIR) == 0) FAIL(FILE_NOT_FOUND);  // Not a directory.

  wchar_t* copy = wcsdup(path);

  process->set_current_directory(copy);

  return process->null_object();
}

PRIMITIVE(chmod) {
  ARGS(WindowsPath, path, int, mode);
  int result = SetFileAttributesW(path, mode);
  if (result == 0) WINDOWS_ERROR;
  return process->null_object();
}

PRIMITIVE(link) {
  ARGS(WindowsPath, source, Blob, target, int, type);
  WideCharAllocationManager allocation(process);
  wchar_t* target_relative = allocation.to_wcs(&target);

  int result;
  if (type == 0) {
    wchar_t target_absolute[MAX_PATH];
    auto error = get_absolute_path(process, target_relative, target_absolute);
    if (error) return error;
    result = CreateHardLinkW(source, target_absolute, NULL);
  } else {
    DWORD flags = SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE;
    if (type == 2) flags |= SYMBOLIC_LINK_FLAG_DIRECTORY;
    result = CreateSymbolicLinkW(source, target_relative, flags);
  }
  if (result == 0) WINDOWS_ERROR;
  return process->null_object();
}

PRIMITIVE(readlink) {
  ARGS(WindowsPath, path);
  HANDLE handle = CreateFileW(path, 0, 0,
                              NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  if (handle == INVALID_HANDLE_VALUE) WINDOWS_ERROR;
  AutoCloser closer(handle);

  char buffer[MAXIMUM_REPARSE_DATA_BUFFER_SIZE];
  DWORD bytes_returned;
  BOOL success = DeviceIoControl(handle, FSCTL_GET_REPARSE_POINT, NULL, 0, buffer, sizeof(buffer), &bytes_returned, 0);
  if (!success) WINDOWS_ERROR;

  auto reparse_data = reinterpret_cast<REPARSE_DATA_BUFFER*>(buffer);
  if (reparse_data->ReparseTag != IO_REPARSE_TAG_SYMLINK) FAIL(INVALID_ARGUMENT);

  WideCharAllocationManager allocation(process);
  USHORT link_name_bytes = reparse_data->SymbolicLinkReparseBuffer.SubstituteNameLength;

  word string_length = static_cast<word>(link_name_bytes / sizeof(wchar_t) + 1); // including null termination
  wchar_t* w_result = allocation.wcs_alloc(string_length);
  memcpy(w_result,
         reparse_data->SymbolicLinkReparseBuffer.PathBuffer +
            reparse_data->SymbolicLinkReparseBuffer.SubstituteNameOffset / sizeof(WCHAR),
         link_name_bytes);
  w_result[string_length - 1] = 0;

  String* result = process->allocate_string(w_result);
  if (result == null) FAIL(ALLOCATION_FAILED);

  return result;
}

PRIMITIVE(mkdir) {
  ARGS(WindowsPath, path, int, mode);

  int result = CreateDirectoryW(path, NULL);
  if (result == 0) WINDOWS_ERROR;
  return process->null_object();
}

PRIMITIVE(mkdtemp) {
  ARGS(CStringBlob, prefix_blob);
  DWORD ret;

  WideCharAllocationManager allocation(process);
  wchar_t* prefix = allocation.to_wcs(&prefix_blob);

  wchar_t* relative_to = null;

  bool in_standard_tmp_dir = false;
  if (wcsncmp(prefix, L"/tmp/", 5) == 0) {
    in_standard_tmp_dir = true;
    prefix += 5;
  }

  wchar_t temp_dir_name[MAX_PATH];
  temp_dir_name[0] = '\0';

  if (in_standard_tmp_dir) {
    // Get the location of the Windows temp directory.
    ret = GetTempPathW(MAX_PATH, temp_dir_name);
    if (ret + 2 > MAX_PATH) FAIL(OUT_OF_RANGE);
    if (ret == 0) WINDOWS_ERROR;
    relative_to = temp_dir_name;
  }
  wchar_t full_filename[MAX_PATH + 1];

  Object* error = get_absolute_path(process, prefix, full_filename, relative_to);
  if (error) return error;

  UUID uuid;
  ret = UuidCreate(&uuid);
  if (ret != RPC_S_OK && ret != RPC_S_UUID_LOCAL_ONLY) FAIL(ERROR);

  uint16* uuid_string;
  ret = UuidToStringW(&uuid, &uuid_string);
  auto uuid_string_w = reinterpret_cast<wchar_t*>(uuid_string);
  if (wcslen(full_filename) + wcslen(uuid_string_w) > MAX_PATH) FAIL(OUT_OF_RANGE);
  wcsncat(full_filename, uuid_string_w, MAX_PATH - wcslen(full_filename));
  RpcStringFreeW(&uuid_string);

  uword total_len = Utils::utf_16_to_8(full_filename, wcslen(full_filename));

  ByteArray* result = process->allocate_byte_array(static_cast<int>(total_len));
  if (result == null) FAIL(ALLOCATION_FAILED);

  ByteArray::Bytes blob(result);

  int ok = CreateDirectoryW(full_filename, null);
  if (ok == 0) WINDOWS_ERROR;

  Utils::utf_16_to_8(full_filename, wcslen(full_filename), blob.address(), blob.length());

  return result;
}

PRIMITIVE(is_open_file) {
  ARGS(int, fd);
  HANDLE handle = reinterpret_cast<HANDLE>(_get_osfhandle(fd));
  if (handle == INVALID_HANDLE_VALUE) WINDOWS_ERROR;
  int type = GetFileType(handle);
  if (type == FILE_TYPE_DISK) {
    return process->true_object();
  } else if (type == FILE_TYPE_PIPE || type == FILE_TYPE_CHAR) {
    return process->false_object();
  } else {
    FAIL(INVALID_ARGUMENT);
  }
}

PRIMITIVE(realpath) {
  ARGS(CStringBlob, filename_blob);
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
    return process->null_object();
  }

  String* result = process->allocate_string(w_result);
  if (result == null) FAIL(ALLOCATION_FAILED);

  return result;
}

PRIMITIVE(cwd) {
  Object* result = process->allocate_string(current_dir(process));
  if (result == null) FAIL(ALLOCATION_FAILED);
  return result;
}

PRIMITIVE(read_file_content_posix) {
  // This is currenly only used for /etc/resolv.conf.
  FAIL(UNIMPLEMENTED);
}

}

#endif  // TOIT_WINDOWS.
