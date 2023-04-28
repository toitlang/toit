// Copyright (C) 2022 Toitware ApS.
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

#define _FILE_OFFSET_BITS 64

#include "primitive_file.h"
#include "primitive.h"
#include "process.h"
#include "objects_inline.h"

#if defined(TOIT_POSIX) || defined(TOIT_FREERTOS)

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifdef TOIT_FREERTOS
// The ESP32 has no notion of a shell and no cwd, so assume all paths are absolute.
#define FILE_OPEN_(dirfd, ...)                             open(__VA_ARGS__)
#define FILE_UNLINK_(dirfd, pathname, flags)               unlink(pathname)
#define FILE_RENAME_(olddirfd, oldpath, newdirfd, newpath) rename(oldpath, newpath)
#define FILE_MKDIR_(dirfd, ...)                            mkdir(__VA_ARGS__)
#else

#define FILE_OPEN_(...)     openat(__VA_ARGS__)
#define FILE_UNLINK_(...)   unlinkat(__VA_ARGS__)
#define FILE_RENAME_(...)   renameat(__VA_ARGS__)
#define FILE_MKDIR_(...)    mkdirat(__VA_ARGS__)
#endif // TOIT_FREERTOS

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

Object* return_open_error(Process* process, int err) {
  if (err == EPERM || err == EACCES || err == EROFS) PERMISSION_DENIED;
  if (err == EDQUOT || err == EMFILE || err == ENFILE || err == ENOSPC) QUOTA_EXCEEDED;
  if (err == EEXIST) ALREADY_EXISTS;
  if (err == EINVAL || err == EISDIR || err == ENAMETOOLONG) INVALID_ARGUMENT;
  if (err == ENODEV || err == ENOENT || err == ENOTDIR) FILE_NOT_FOUND;
  if (err == ENOMEM) MALLOC_FAILED;
  OTHER_ERROR;
}

PRIMITIVE(read_file_content_posix) {
#ifndef TOIT_POSIX
  UNIMPLEMENTED_PRIMITIVE;
#else
  ARGS(cstring, filename, int, file_size);
  ByteArray* result = process->allocate_byte_array(file_size);
  if (result == null) ALLOCATION_FAILED;
  ByteArray::Bytes result_bytes(result);
  int fd = open(filename, O_RDONLY);
  if (fd == -1) return return_open_error(process, errno);
  int position = 0;
  for (position = 0; position < file_size; ) {
    int n = read(fd, result_bytes.address() + position, file_size - position);
    if (n == -1) {
      if (errno == EINTR) continue;
      close(fd);
      OTHER_ERROR;
    }
    if (n == 0) INVALID_ARGUMENT;  // File changed size?
    position += n;
  }
  close(fd);
  return result;
#endif
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

int current_dir(Process* process) {
  int fd = process->current_directory();
  if (fd >= 0) return fd;
  fd = open(".", O_DIRECTORY | O_RDONLY | O_CLOEXEC);
  process->set_current_directory(fd);
  return fd;
}

PRIMITIVE(open) {
  ARGS(cstring, pathname, int, flags, int, mode);
  // We always set the close-on-exec flag otherwise we leak fds when we fork.
  // File descriptors that are intended for subprocesses have the the flags cleared.
  int os_flags = O_CLOEXEC;
  if ((flags & FILE_RDWR) == FILE_RDONLY) os_flags |= O_RDONLY;
  else if ((flags & FILE_RDWR) == FILE_WRONLY) os_flags |= O_WRONLY;
  else if ((flags & FILE_RDWR) == FILE_RDWR) os_flags |= O_RDWR;
  else INVALID_ARGUMENT;
  if ((flags & FILE_APPEND) != 0) os_flags |= O_APPEND;
  if ((flags & FILE_CREAT) != 0) os_flags |= O_CREAT;
  if ((flags & FILE_TRUNC) != 0) os_flags |= O_TRUNC;
  bool is_dev_null = strcmp(pathname, "/dev/null") == 0;
  int fd = FILE_OPEN_(current_dir(process), pathname, os_flags, mode);
  AutoCloser closer(fd);
  if (fd < 0) return return_open_error(process, errno);
  struct stat statbuf;
  int res = fstat(fd, &statbuf);
  if (res < 0) {
    if (errno == ENOMEM) MALLOC_FAILED;
    OTHER_ERROR;
  }
  int type = statbuf.st_mode & S_IFMT;
  if (!is_dev_null && type != S_IFREG) {
    // An attempt to open something with file::open that is not a regular file
    // with open (eg a pipe, a socket, a directory).  We forbid this because
    // these file descriptors can block, and this API does not support
    // blocking.
    INVALID_ARGUMENT;
  }
  closer.clear();
  return Smi::from(fd);
}

class LeakyDirectory {
 public:
  TAG(LeakyDirectory);
  LeakyDirectory(DIR* dir) : dir_(dir) {}
  ~LeakyDirectory() { closedir(dir_); }

  DIR* dir() const { return dir_; }

 private:
  DIR* dir_;
};

class Directory : public SimpleResource, public LeakyDirectory {
 public:
  TAG(Directory);
  Directory(SimpleResourceGroup* group, DIR* dir) : SimpleResource(group), LeakyDirectory(dir) {}
};

// Deprecated primitive that can leak memory if you forget to call close.
PRIMITIVE(opendir) {
  ARGS(cstring, pathname);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

#ifndef TOIT_FREERTOS
  int fd = FILE_OPEN_(current_dir(process), pathname, O_RDONLY | O_DIRECTORY);
  if (fd < 0) return return_open_error(process, errno);
  DIR* dir = fdopendir(fd);
  if (dir == null) {
    close(fd);
    return return_open_error(process, errno);
  }
#else
  DIR* dir = opendir(pathname);
  if (dir == null) {
    return return_open_error(process, errno);
  }
#endif

  LeakyDirectory* directory = _new LeakyDirectory(dir);
  if (directory == null) {
    closedir(dir);  // Also closes fd.
    MALLOC_FAILED;
  }

  proxy->set_external_address(directory);
  return proxy;
}

PRIMITIVE(opendir2) {
  ARGS(SimpleResourceGroup, group, cstring, pathname);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;
#ifndef TOIT_FREERTOS
  int fd = FILE_OPEN_(current_dir(process), pathname, O_RDONLY | O_DIRECTORY);
  if (fd < 0) return return_open_error(process, errno);
  DIR* dir = fdopendir(fd);
  if (dir == null) {
    close(fd);
    return return_open_error(process, errno);
  }
#else
  DIR* dir = opendir(pathname);
  if (dir == null) {
    return return_open_error(process, errno);
  }
#endif

  Directory* directory = _new Directory(group, dir);
  if (directory == null) {
    closedir(dir);  // Also closes fd.
    MALLOC_FAILED;
  }

  proxy->set_external_address(directory);
  return proxy;
}

PRIMITIVE(readdir) {
  ARGS(ByteArray, directory_proxy);

  if (!directory_proxy->has_external_address()) WRONG_TYPE;

  LeakyDirectory* directory;
  if (directory_proxy->external_tag() == Directory::tag_min) {
    directory = directory_proxy->as_external<Directory>();
  } else if (directory_proxy->external_tag() == LeakyDirectory::tag_min) {
    directory = directory_proxy->as_external<LeakyDirectory>();
  } else {
    WRONG_TYPE;
  }

  ByteArray* proxy = process->object_heap()->allocate_proxy(true);
  if (proxy == null) {
    ALLOCATION_FAILED;
  }

  struct dirent* entry = readdir(directory->dir());
  // After this point we can't bail out for GC because readdir is not really
  // restartable in Unix.

  if (entry == null) {
    return process->program()->null_object();
  }

  int len = strlen(entry->d_name);

  if (!Utils::is_valid_utf_8(unsigned_cast(entry->d_name), len)) {
    ILLEGAL_UTF_8;
  }

  process->register_external_allocation(len);

  uint8 *backing = unvoid_cast<uint8*>(malloc(len));  // Can't fail on non-embedded.
  ASSERT(backing);
  memcpy(backing, reinterpret_cast<const uint8*>(entry->d_name), len);

  proxy->set_external_address(len, backing);
  return proxy;
}

PRIMITIVE(closedir) {
  ARGS(ByteArray, proxy);

  if (!proxy->has_external_address()) WRONG_TYPE;

  if (proxy->external_tag() == Directory::tag_min) {
    Directory* directory = proxy->as_external<Directory>();
    if (directory != null) {
      directory->resource_group()->unregister_resource(directory);
    }
  } else if (proxy->external_tag() == LeakyDirectory::tag_min) {
    LeakyDirectory* directory = proxy->as_external<LeakyDirectory>();
    delete directory;
  } else {
    WRONG_TYPE;
  }

  proxy->clear_external_address();
  return process->program()->null_object();
}

PRIMITIVE(read) {
  ARGS(int, fd);
  const int SIZE = 64 * KB;

  AllocationManager allocation(process);
  uint8* buffer = allocation.alloc(SIZE);
  if (!buffer) ALLOCATION_FAILED;

  ByteArray* result = process->object_heap()->allocate_external_byte_array(
      SIZE, buffer, true /* dispose */, false /* clear */);
  if (!result) ALLOCATION_FAILED;
  allocation.keep_result();

  ssize_t buffer_fullness = 0;
  while (buffer_fullness < SIZE) {
    ssize_t bytes_read = read(fd, buffer + buffer_fullness, SIZE - buffer_fullness);
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

  if (buffer_fullness < SIZE) {
    result->resize_external(process, buffer_fullness);
  }
  return result;
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
      if (errno == EDQUOT || errno == ENOSPC) QUOTA_EXCEEDED;
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
      if (errno == EINTR) continue;
      if (errno == EBADF) ALREADY_CLOSED;
      if (errno == ENOSPC || errno == EDQUOT) QUOTA_EXCEEDED;
      OTHER_ERROR;
    }
    return process->program()->null_object();
  }
}

Object* time_stamp(Process* process, struct timespec time) {
  return Primitive::integer(time.tv_sec * 1000000000ll + time.tv_nsec, process);
}

// Returns null for entries that do not exist.
// Otherwise returns an array with indices from the FILE_ST_xxx constants.
PRIMITIVE(stat) {
  ARGS(cstring, pathname, bool, follow_links);
#if defined(TOIT_FREERTOS)
  USE(follow_links);
  struct stat statbuf;
  int result = stat(pathname, &statbuf); // FAT does not have symbolic links
#else
  struct stat statbuf;
  int result = fstatat(current_dir(process), pathname, &statbuf, follow_links ? 0 : AT_SYMLINK_NOFOLLOW);
#endif
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

#if defined(TOIT_LINUX) || defined(TOIT_FREERTOS)
  Object* atime = time_stamp(process, statbuf.st_atim);
  if (Primitive::is_error(atime)) return atime;

  Object* mtime = time_stamp(process, statbuf.st_mtim);
  if (Primitive::is_error(mtime)) return mtime;

  Object* ctime = time_stamp(process, statbuf.st_ctim);
  if (Primitive::is_error(ctime)) return ctime;
#else
  Object* atime = time_stamp(process, statbuf.st_atimespec);
  if (Primitive::is_error(atime)) return atime;

  Object* mtime = time_stamp(process, statbuf.st_mtimespec);
  if (Primitive::is_error(mtime)) return mtime;

  Object* ctime = time_stamp(process, statbuf.st_ctimespec);
  if (Primitive::is_error(ctime)) return ctime;
#endif
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
  int result = FILE_UNLINK_(current_dir(process), pathname, 0);
  if (result < 0) return return_open_error(process, errno);
  return process->program()->null_object();
}

PRIMITIVE(rmdir) {
  ARGS(cstring, pathname);
  int result = FILE_UNLINK_(current_dir(process), pathname, AT_REMOVEDIR);
  if (result < 0) return return_open_error(process, errno);
  return process->program()->null_object();
}

PRIMITIVE(rename) {
  ARGS(cstring, old_name, cstring, new_name);
  int result = FILE_RENAME_(current_dir(process), old_name, current_dir(process), new_name);
  if (result < 0) return return_open_error(process, errno);
  return process->program()->null_object();
}

PRIMITIVE(chdir) {
#ifndef TOIT_FREERTOS
  ARGS(cstring, pathname);
  int old_dir = current_dir(process);
  int new_dir = FILE_OPEN_(old_dir, pathname, O_DIRECTORY | O_RDONLY);
  if (new_dir < 0) return return_open_error(process, errno);
  process->set_current_directory(new_dir);
  close(old_dir);
  return process->program()->null_object();
#else
  UNIMPLEMENTED_PRIMITIVE;
#endif
}

PRIMITIVE(mkdir) {
  ARGS(cstring, pathname, int, mode);
  int result = FILE_MKDIR_(current_dir(process), pathname, mode);
  return result < 0
    ? return_open_error(process, errno)
    : process->program()->null_object();
}

PRIMITIVE(mkdtemp) {
  ARGS(cstring, prefix);

  const int X_COUNT = 6;

  word prefix_len = strlen(prefix);
  word total_len = prefix_len + X_COUNT;
  Object* result = process->allocate_byte_array(total_len);
  if (result == null) ALLOCATION_FAILED;

  if (!process->should_allow_external_allocation(total_len + 1)) ALLOCATION_FAILED;
  char* mutable_buffer = unvoid_cast<char*>(malloc(total_len + 1));
  if (mutable_buffer == null) MALLOC_FAILED;
  AllocationManager allocation(process, mutable_buffer, total_len);

  memset(mutable_buffer, 'X', total_len);
  mutable_buffer[total_len] = '\0';
  memcpy(mutable_buffer, prefix, prefix_len);

  char* ok = mkdtemp(mutable_buffer);
  if (ok == null) {
    return return_open_error(process, errno);
  }
  ASSERT(ok == mutable_buffer);
  memcpy(ByteArray::Bytes(ByteArray::cast(result)).address(), mutable_buffer, total_len);
  return result;
}

PRIMITIVE(is_open_file) {
  ARGS(int, fd);
  int result = lseek(fd, 0, SEEK_CUR);
  if (result < 0) {
    if (errno == ESPIPE) return process->program()->false_object();
    if (errno == EBADF) INVALID_ARGUMENT;
    OTHER_ERROR;
  }
  return process->program()->true_object();
}

PRIMITIVE(realpath) {
  ARGS(cstring, filename);
#ifdef TOIT_FREERTOS
  String* result = process->allocate_string(filename);
  if (result == null) {
    ALLOCATION_FAILED;
  }
  return result;
#else
  char* c_result = realpath(filename, null);
  if (c_result == null) {
    if (errno == ENOMEM) MALLOC_FAILED;
    if (errno == ENOENT or errno == ENOTDIR) return process->program()->null_object();
    OTHER_ERROR;
  }
  String* result = process->allocate_string(c_result);
  if (result == null) {
    free(c_result);
    ALLOCATION_FAILED;
  }
  return result;
#endif // TOIT_FREERTOS
}

PRIMITIVE(cwd) {
#ifdef TOIT_DARWIN
  char cwd_path[PATH_MAX + 1];
  int status = fcntl(current_dir(process), F_GETPATH, &cwd_path);
  cwd_path[PATH_MAX] = '\0';
  if (status == -1) {
    if (errno == ENOMEM) MALLOC_FAILED;
    OTHER_ERROR;
  }
  String* result = process->allocate_string(cwd_path);
  if (result == null) ALLOCATION_FAILED;
  return result;
#else
  OTHER_ERROR;
#endif
}

}

#endif  // Linux and BSD.
