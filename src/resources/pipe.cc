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

#include "../top.h"

#if defined(TOIT_LINUX) || defined(TOIT_BSD)

#include <errno.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#ifdef TOIT_LINUX
#include <sys/epoll.h>
#endif

#ifdef TOIT_BSD
#include <sys/event.h>
#endif

#include "../objects.h"
#include "../objects_inline.h"
#include "../os.h"
#include "../primitive.h"
#include "../primitive_file.h"
#include "../process_group.h"
#include "../process.h"
#include "../resource.h"
#include "../vm.h"
#include "subprocess.h"

#include "../event_sources/epoll_linux.h"
#include "../event_sources/kqueue_bsd.h"
#include "../event_sources/subprocess.h"

namespace toit {

enum {
  PIPE_READ  = 1 << 0,
  PIPE_WRITE = 1 << 1,
  PIPE_CLOSE = 1 << 2,
  PIPE_ERROR = 1 << 3,
};

static bool mark_non_blocking(int fd) {
   int flags = fcntl(fd, F_GETFL, 0);
   if (flags == -1) return false;
   return fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1;
}

#ifdef TOIT_BSD
// MacOS does not have pipe2 which avoids a race condition where another thread
// forks after the pipe() call, but before we managed to set the O_CLOEXEC flag
// on the file descriptors.  We emulate pipe2 here, but with the unavoidable
// race.
static int pipe2_portable(int fds[2], int fd_flags) {
  int result = pipe(fds);
  if (result < 0) return result;
  for (int i = 0; i < 2; i++) {
    int old_flags = fcntl(fds[i], F_GETFD, 0);
    fcntl(fds[i], F_SETFD, old_flags | fd_flags);
  }
  return 0;
}
#endif

#ifdef TOIT_LINUX
static int pipe2_portable(int fds[2], int fd_flags) {
  int o_flags = 0;
  if ((fd_flags & FD_CLOEXEC) != 0) o_flags |= O_CLOEXEC;
  return pipe2(fds, o_flags);
}
#endif

class PipeResourceGroup : public ResourceGroup {
 public:
  TAG(PipeResourceGroup);
  PipeResourceGroup(Process* process, EventSource* event_source) : ResourceGroup(process, event_source) {}

  uint32_t on_event(Resource* resource, word data, uint32_t state) {
#ifdef TOIT_LINUX
    if (data & EPOLLIN) state |= PIPE_READ;
    if (data & EPOLLOUT) state |= PIPE_WRITE;
    if (data & EPOLLHUP) state |= PIPE_CLOSE;
    if (data & EPOLLERR) state |= PIPE_ERROR;
#endif
#ifdef TOIT_BSD
    struct kevent* event = reinterpret_cast<struct kevent*>(data);

    if (event->filter == EVFILT_READ) {
      state |= PIPE_READ;
      if (event->flags & EV_EOF) {
        if (event->fflags != 0) {
          state |= PIPE_ERROR;
        } else {
          state |= PIPE_CLOSE;
        }
      }
    }

    if (event->filter == EVFILT_WRITE) {
      state |= PIPE_WRITE;
      if (event->flags & EV_EOF && event->fflags != 0) {
        state |= PIPE_ERROR;
      }
    }
#endif
    return state;
  }

  bool is_control_fd(int fd) {
#ifdef TOIT_BSD
    return false;
#endif
#ifdef TOIT_LINUX
    EpollEventSource* epoll_event_source = EpollEventSource::instance();
    ASSERT(epoll_event_source == event_source());
    return epoll_event_source->is_control_fd(fd);
#endif
  }

 private:
};

MODULE_IMPLEMENTATION(pipe, MODULE_PIPE)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

#ifdef TOIT_LINUX
  PipeResourceGroup* resource_group = _new PipeResourceGroup(process, EpollEventSource::instance());
#endif
#ifdef TOIT_BSD
  PipeResourceGroup* resource_group = _new PipeResourceGroup(process, KQueueEventSource::instance());
#endif
  if (!resource_group) MALLOC_FAILED;

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(close) {
  ARGS(IntResource, fd_resource, PipeResourceGroup, resource_group);

  resource_group->unregister_resource(fd_resource);

  fd_resource_proxy->clear_external_address();

  return process->program()->null_object();
}

// Create a writable or readable pipe, as used for stdin/stdout/stderr of a child process.
// result[0]: Resource
// result[1]: file descriptor for child process.  dup2() can be used to make this fd 0, 1, or 2.
PRIMITIVE(create_pipe) {
  ARGS(PipeResourceGroup, resource_group, bool, in);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) ALLOCATION_FAILED;
  Array* array = process->object_heap()->allocate_array(2, Smi::zero());
  if (array == null) ALLOCATION_FAILED;

  int fds[2];
  int result = pipe2_portable(fds, FD_CLOEXEC);
  if (result < 0) {
    QUOTA_EXCEEDED;
  }
  int read = fds[0];
  int write = fds[1];

  if (!mark_non_blocking(in ? write : read)) {
    close(read);
    close(write);
    return Primitive::os_error(errno, process);
  }

  IntResource* resource = resource_group->register_id(in ? write : read);
  if (!resource) {
    close(read);
    close(write);
    MALLOC_FAILED;
  }
  resource_proxy->set_external_address(resource);

  array->at_put(0, resource_proxy);
  array->at_put(1, Smi::from(in ? read : write));

  return array;
}

PRIMITIVE(fd_to_pipe) {
  ARGS(PipeResourceGroup, resource_group, int, fd);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) ALLOCATION_FAILED;

  if (resource_group->is_control_fd(fd)) INVALID_ARGUMENT;

  if (!mark_non_blocking(fd)) {
    return Primitive::os_error(errno, process);
  }

  IntResource* resource = resource_group->register_id(fd);
  if (!resource) MALLOC_FAILED;
  resource_proxy->set_external_address(resource);

  return resource_proxy;
}

PRIMITIVE(is_a_tty) {
  ARGS(IntResource, fd_resource);
  if (isatty(fd_resource->id())) return process->program()->true_object();
  return process->program()->false_object();
}

PRIMITIVE(write) {
  ARGS(IntResource, fd_resource, Blob, data, int, from, int, to);
  int fd = fd_resource->id();

  if (from < 0 || from > to || to > data.length()) OUT_OF_BOUNDS;

  int written = write(fd, data.address() + from, to - from);
  if (written >= 0) {
    return Smi::from(written);
  }

  if (errno == EWOULDBLOCK) return Smi::from(0);
  return Primitive::os_error(errno, process);
}

PRIMITIVE(fd) {
  ARGS(IntResource, fd_resource);
  int fd = fd_resource->id();
  return Smi::from(fd);
}

PRIMITIVE(read) {
  ARGS(IntResource, fd_resource);
  int fd = fd_resource->id();

  int available = 0;
  if (ioctl(fd, FIONREAD, &available) == -1) {
    return Primitive::os_error(errno, process);
  }

  available = Utils::max(available, ByteArray::MIN_IO_BUFFER_SIZE);
  available = Utils::min(available, ByteArray::PREFERRED_IO_BUFFER_SIZE);

  Error* error = null;
  ByteArray* array = process->allocate_byte_array(available, &error);
  if (array == null) return error;

  int read = ::read(fd, ByteArray::Bytes(array).address(), available);
  if (read == -1) {
    Smi* would_block = Smi::from(-1);
    if (errno == EWOULDBLOCK) return would_block;
    return Primitive::os_error(errno, process);
  }
  if (read == 0) return process->program()->null_object();

  array->resize(process->program(), read);

  return array;
}

class Freer {
 public:
  explicit Freer(char** p) : _ptr(p) {}
  ~Freer() {
    free(_ptr);
  }

 private:
  char** _ptr;
};

// o can be an IntResource, a Smi or null (which returns -1).
// -2 is returned otherwise.
static int get_fd(Object* obj) {
  if (obj->is_smi()) {
    return Smi::cast(obj)->value();
  } else if (obj->is_byte_array()) {
    ByteArray* ba = ByteArray::cast(obj);
    if (!ba->has_external_address()) return -2;
    if (ba->external_tag() != IntResource::tag) return -2;
    return ba->as_external<IntResource>()->id();
  }
  return -2;
}

// Move the given fd to stdin/out/err or another known fd number, and remove
// the close-on-exec flag for the new process.  This function is only called
// after fork, but before exec.
static int dup_down(int from, int to) {
  if (from < 0) {
    // The subprocess inherits our stdxx handle, and no error is possible.
    return 0;
  }
  if (from == to) return 0;
  // Close any unrelated fds that happen to be already on the desired number.
  // This is after fork, so only happens in the child, and they would have been
  // closed on exec anyway.
  close(to);  // Ignore errors.
  if (dup2(from, to) < 0) return -1;
  if (close(from) < 0) return -1;
  int old_flags = fcntl(to, F_GETFL, 0);
  return fcntl(to, F_SETFL, old_flags & ~O_CLOEXEC);
}

// Forks and execs a program (optionally found using the PATH environment
// variable.  The given file descriptors should be open file descriptors.  They
// are attached to the stdin, stdout and stderr of the launched program, and
// are closed in the parent program.  If you pass -1 for any of these then the
// forked program inherits the stdin/out/err of this Toit program.
PRIMITIVE(fork) {
  ARGS(SubprocessResourceGroup, resource_group,
       bool, use_path,
       Object, in_obj,
       Object, out_obj,
       Object, err_obj,
       int, fd_3,
       int, fd_4,
       cstring, command,
       Array, args);
  if (args->length() > 1000000) OUT_OF_BOUNDS;
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  // We allocate memory for the IntResource early here so we can handle failure
  // and restart the primitive.  If we wait until after the fork, the
  // subprocess is already running and it's too late to GC-and-retry.
  AllocationManager resource_allocation(process);
  if (resource_allocation.alloc(sizeof(IntResource)) == null) {
    ALLOCATION_FAILED;
  }

  AllocationManager allocation(process);
  char** argv = reinterpret_cast<char**>(allocation.calloc(args->length() + 1, sizeof(char*)));
  if (argv == null) ALLOCATION_FAILED;
  for (word i = 0; i < args->length(); i++) {
    if (!args->at(i)->is_string()) {
      WRONG_TYPE;
    }
    argv[i] = String::cast(args->at(i))->as_cstr();
  }
  argv[args->length()] = null;

  int control_fds[2] = {-1, -1};

  int pipe_result = pipe2_portable(control_fds, FD_CLOEXEC);

  if (pipe_result < 0) {
    QUOTA_EXCEEDED;
  }

  int control_read = control_fds[0];
  int control_write = control_fds[1];

  int data_fds[5];
  data_fds[0] = get_fd(in_obj);
  data_fds[1] = get_fd(out_obj);
  data_fds[2] = get_fd(err_obj);
  data_fds[3] = fd_3;
  data_fds[4] = fd_4;
  int highest_child_fd = -1;
  for (int i = 4; i >= 0; i--) {
    if (data_fds[i] > 0) {
      if (highest_child_fd < 0) highest_child_fd = i;
      if (data_fds[i] < -1) WRONG_TYPE;
    }
  }

  int child_pid = fork();

  if (child_pid == -1) {
    close(control_read);
    close(control_write);
    if (errno == EAGAIN) QUOTA_EXCEEDED;
    if (errno == ENOMEM) MALLOC_FAILED;
    OTHER_ERROR;
  }

  if (child_pid != 0) {
    // Parent process.
    close(control_write);  // In the parent, close the child's end.
    int child_errno;
    const int child_errno_size = sizeof(child_errno);
    int control_status = read(control_read, &child_errno, child_errno_size);
    if (control_status < child_errno_size) {
      // Child process did a successful execvp call, closing the control pipe.
      // This is the success case, so we close the file descriptors that were
      // given to the child process.  (Harmlessly tries to close fd -1
      // sometimes.)
      for (int i = 0; i <= highest_child_fd; i++) close(data_fds[i]);
      close(control_read);
      // Use the preallocated memory here for the resource, so we can be sure
      // the allocation will not fail.
      IntResource* pid = new (resource_allocation.keep_result()) IntResource(resource_group, child_pid);
      proxy->set_external_address(pid);
      return proxy;
    }
    // Child failed to exec its program, and sent us the errno through the
    // control pipe.  Report the error as our own.
    return Primitive::os_error(child_errno, process);
  }

  // Child process.

  do {
    if (command == null) break;

    // Change the directory of the child process to match the Toit task's current directory.
    int current_directory_fd = current_dir(process);
    if (fchdir(current_directory_fd) < 0) break;

    // We want to move in, out, err, fd_3 and fd_4 to fds 0-4 so that they will be used
    // as stdin, stdout, stderr, 3 and 4 by the child process.  If one of those is already
    // < 5 then an awkward dance needs to be done to shuffle them around.
    bool need_shuffle = false;
    for (int i = 0; i <= highest_child_fd; i++) {
      if (0 <= data_fds[i] && data_fds[i] <= highest_child_fd && data_fds[i] != i) {
        need_shuffle = true;
        break;
      }
    }
    bool failed = false;
    if (need_shuffle) {
      int blocking_fds[4];
      for (int i = 0; i < highest_child_fd; i++) {
        blocking_fds[i] = open("/", O_RDONLY);
        if (blocking_fds[i] < 0) failed = true;
      }
      if (failed) break;

      // Now all the low fds are certainly taken, since open takes the lowest free fd.
      // Use dup to move them up to higher numbers.
      int old_fds[5];
      for (int i = 0; i <= highest_child_fd; i++) {
        old_fds[i] = data_fds[i];
        if (old_fds[i] >= 0) {
          data_fds[i] = dup(old_fds[i]);
          if (data_fds[i] < 0) {
            failed = true;
            break;
          }
        }
      }
      if (failed) break;

      // Now the data fds are all certainly high.  Close the copies.
      for (int i = 0; i <= highest_child_fd; i++) {
        if (old_fds[i] >= 0 && close(old_fds[i])) {
          failed = true;
          break;
        }
      }
      if (failed) break;
      for (int i = 0; i < highest_child_fd; i++) {
        if (close(blocking_fds[i] < 0)) {
          failed = true;
          break;
        }
      }
      if (failed) break;
    }

    for (int i = 0; i <= highest_child_fd; i++) {
      if (data_fds[i] != i && dup_down(data_fds[i], i)) {
        failed = true;
        break;
      }
    }
    if (failed) break;

    // Exec the actual program.  If this succeeds, then control_write is closed
    // automatically, and the parent is unblocked on its read.
    if (use_path) {
      execvp(command, argv);
    } else {
      execv(command, argv);
    }
    // We only get here if the exec failed.
  } while (false);
  // We get here either with a 'break' or because exec failed.

  // Notify parent process of the errno, so it can throw the right exception.
  int e = errno;
  int result = write(control_write, &e, sizeof(e));
  (void)(result); // Tell linter we are ignoring the result.

  // We get here when the fork-exec failed between the fork and exec, often
  // because the program we tried to exec does not exist.  This is an anomalous
  // exit for the VM (but the parent process VM is still running).
  // Don't use exit() here, because it will check for memory leaks with address
  // sanitizer, which is pointless.
  abort();

  return null;  // We never get here.
}

} // namespace toit

#endif // TOIT_LINUX or TOIT_BSD
