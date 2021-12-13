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

#ifdef TOIT_WINDOWS

#define _FILE_OFFSET_BITS 64

#include "primitive_file.h"
#include "primitive.h"
#include "process.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

namespace toit {

MODULE_IMPLEMENTATION(file, MODULE_FILE)

class AutoCloser {
 public:
  explicit AutoCloser(int fd) : _fd(fd) {}
  ~AutoCloser() {
    if (_fd >= 0) {
      close(_fd);
    }
  }

  int clear() {
    int tmp = _fd;
    _fd = -1;
    return tmp;
  }

 private:
  int _fd;
};

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

PRIMITIVE(open) {
  ARGS(cstring, pathname, int, flags, int, mode);
  int os_flags = _O_BINARY;
  if ((flags & FILE_RDWR) == FILE_RDONLY) os_flags |= _O_RDONLY;
  else if ((flags & FILE_RDWR) == FILE_WRONLY) os_flags |= _O_WRONLY;
  else if ((flags & FILE_RDWR) == FILE_RDWR) os_flags |= _O_RDWR;
  else INVALID_ARGUMENT;
  if ((flags & FILE_APPEND) != 0) os_flags |= _O_APPEND;
  if ((flags & FILE_CREAT) != 0) os_flags |= _O_CREAT;
  if ((flags & FILE_TRUNC) != 0) os_flags |= _O_TRUNC;
  int fd = _open(pathname, os_flags, mode);
  AutoCloser closer(fd);
  if (fd < 0) return return_open_error(process, errno);
  struct stat statbuf;
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
    INVALID_ARGUMENT;
  }
  closer.clear();
  return Smi::from(fd);
}

class Directory {
 public:
  TAG(Directory);
  DIR* dir;
};

PRIMITIVE(opendir) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(readdir) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(closedir) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(read) {
  ARGS(int, fd);
  const int SIZE = 1000;
  uint8 buffer[SIZE];
  ssize_t buffer_fullness = 0;
  while (buffer_fullness < SIZE) {
    printf("trying to read: %d - %d\r\n", buffer + buffer_fullness, SIZE - buffer_fullness);
    ssize_t bytes_read = _read(fd, buffer + buffer_fullness, SIZE - buffer_fullness);
    printf("successful read: %d - errno: %d\r\n", bytes_read, errno);
    if (bytes_read < 0) {
      if (errno == EINTR) continue;
      if (errno == EINVAL || errno == EISDIR || errno == EBADF) INVALID_ARGUMENT;
    }
    buffer_fullness += bytes_read;
    if (bytes_read == 0) break;
  }
  if (buffer_fullness == 0) {
    printf("empty read, return null\r\n");
    return process->program()->null_object();
  }
  Error* error = null;
  printf("allocating byte array\r\n");
  Object* byte_array = process->allocate_byte_array(buffer_fullness, &error);
  printf("successful allocated\r\n");
  if (byte_array == null) {
    printf("trying lseek: %d\r\n", -buffer_fullness);
    _lseek(fd, -buffer_fullness, SEEK_CUR);
    printf("successful lseek\r\n");
    return error;
  }
  auto buf = ByteArray::Bytes(ByteArray::cast(byte_array)).address();
  printf("trying memcopy\r\n");
  memcpy(buf, buffer, buffer_fullness);
  printf("successful memcopy\r\n");
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
  struct stat statbuf;
  int result = stat(pathname, &statbuf);
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
  int result = unlink(pathname);
  if (result < 0) return return_open_error(process, errno);
  return process->program()->null_object();
}

PRIMITIVE(rmdir) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(rename) {
  ARGS(cstring, old_name, cstring, new_name);
  int result = rename(old_name, new_name);
  if (result < 0) return return_open_error(process, errno);
  return process->program()->null_object();
}

PRIMITIVE(chdir) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(mkdir) {
  ARGS(cstring, pathname, int, mode);
  USE(mode);
  int result = mkdir(pathname);
  return result < 0
    ? return_open_error(process, errno)
    : process->program()->null_object();
}

PRIMITIVE(mkdtemp) {
  UNIMPLEMENTED_PRIMITIVE;
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
  char* c_result = _fullpath(null, filename, MAXPATHLEN);
  if (c_result == null) {
    if (errno == ENOMEM) MALLOC_FAILED;
    if (errno == ENOENT or errno == ENOTDIR) return process->program()->null_object();
    OTHER_ERROR;
  }
  Error* error = null;
  String* result = process->allocate_string(c_result, &error);
  if (result == null) {
    free(c_result);
    return error;
  }
  return result;
}

PRIMITIVE(cwd) {
  UNIMPLEMENTED_PRIMITIVE;
}

}

#endif  // Linux and BSD.
