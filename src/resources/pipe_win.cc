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

#if defined(TOIT_WINDOWS)

#include <fcntl.h>
#include <sys/types.h>
#include <windows.h>

#include "../error_win.h"
#include "../objects.h"
#include "../objects_inline.h"
#include "../primitive_file.h"
#include "subprocess.h"
#include "../vm.h"

namespace toit {

enum {
  PIPE_READ  = 1 << 0,
  PIPE_WRITE = 1 << 1,
  PIPE_CLOSE = 1 << 2,
  PIPE_ERROR = 1 << 3,
};

static const int READ_BUFFER_SIZE = 1 << 16;

class PipeResourceGroup : public ResourceGroup {
 public:
  TAG(PipeResourceGroup);
  PipeResourceGroup(Process* process, EventSource* event_source) : ResourceGroup(process, event_source) {}

  bool is_standard_piped(int fd) const {
    if (!(0 <= fd && fd <= 2)) return false;
    return (standard_pipes_ & (1 << fd)) != 0;
  }

  void set_standard_piped(int fd) {
    if (0 <= fd && fd <= 2) {
      standard_pipes_ |= (1 << fd);
    }
  }
  volatile long& pipe_serial_number() { return pipe_serial_number_; }
 protected:
  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
    return reinterpret_cast<WindowsResource*>(resource)->on_event(
        reinterpret_cast<HANDLE>(data),
        state);
  }

 private:
  word standard_pipes_ = 0;
  volatile long pipe_serial_number_ = 0;
};

class HandlePipeResource : public WindowsResource {
 public:
  TAG(PipeResource);
  HandlePipeResource(ResourceGroup* resource_group, HANDLE handle, HANDLE event)
  : WindowsResource(resource_group), handle_(handle) {
    overlapped_.hEvent = event;
  }

  HANDLE handle() { return handle_; }

  std::vector<HANDLE> events() override {
    return std::vector<HANDLE>( { overlapped_.hEvent } );
  }

  void do_close() override {
    CloseHandle(overlapped_.hEvent);
    CloseHandle(handle_);
  }

  OVERLAPPED* overlapped() { return &overlapped_; }
 private:
  HANDLE handle_;
  OVERLAPPED overlapped_{};
};

class ReadPipeResource : public HandlePipeResource {
 public:
  ReadPipeResource(ResourceGroup* resource_group, HANDLE handle, HANDLE event)
    : HandlePipeResource(resource_group, handle, event) {
    issue_read_request();
  }

  uint32_t on_event(HANDLE event, uint32_t state) override {
    read_ready_ = true;
    return state | PIPE_READ;
  }

  bool issue_read_request() {
    read_ready_ = false;
    read_count_ = 0;
    bool success = ReadFile(handle(), read_data_, READ_BUFFER_SIZE, &read_count_, overlapped());
    if (!success && WSAGetLastError() != ERROR_IO_PENDING) {
      return false;
    }
    return true;
  }

  bool receive_read_response() {
    bool overlapped_result = GetOverlappedResult(handle(), overlapped(), &read_count_, false);
    return overlapped_result;
  }

  DWORD read_count() const { return read_count_; }
  bool read_ready() const { return read_ready_; }
  char* read_buffer() { return read_data_; }
  void set_pipe_ended(bool pipe_ended) { pipe_ended_ = pipe_ended; }
  bool pipe_ended() const { return pipe_ended_; }
 private:
  char read_data_[READ_BUFFER_SIZE]{};
  DWORD read_count_ = 0;
  bool read_ready_ = false;
  bool pipe_ended_ = false;
};

class WritePipeResource : public HandlePipeResource {
 public:
  WritePipeResource(ResourceGroup* resource_group, HANDLE handle, HANDLE event)
    : HandlePipeResource(resource_group, handle, event) {
    set_state(PIPE_WRITE);
    //overlapped()->Pointer = this;
  }

  ~WritePipeResource() override {
    if (write_buffer_ != null) free(write_buffer_);
  }

  uint32_t on_event(HANDLE event, uint32_t state) override {
    write_ready_ = true;
    return state | PIPE_WRITE;
  }

  bool ready_for_write() const { return write_ready_; }


  bool send(const uint8* buffer, word length) {
    if (write_buffer_ != null) free(write_buffer_);

    write_ready_ = false;

    // We need to copy the buffer out to a long-lived heap object.
    write_buffer_ = static_cast<char*>(malloc(length));
    memcpy(write_buffer_, buffer, length);

    DWORD tmp;
    bool send_result = WriteFile(handle(), write_buffer_, length, &tmp, overlapped());
    if (!send_result && WSAGetLastError() != ERROR_IO_PENDING) {
      return false;
    }
    return true;
  }

 private:
  char* write_buffer_ = null;
  bool write_ready_ = true;
};

MODULE_IMPLEMENTATION(pipe, MODULE_PIPE)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto resource_group = _new PipeResourceGroup(process, WindowsEventSource::instance());
  if (!resource_group) FAIL(MALLOC_FAILED);

  if (!WindowsEventSource::instance()->use()) {
    resource_group->tear_down();
    WINDOWS_ERROR;
  }

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(close) {
  ARGS(Resource, fd_resource, PipeResourceGroup, resource_group);

  resource_group->unregister_resource(fd_resource);

  fd_resource_proxy->clear_external_address();

  return process->null_object();
}

// Create a writable or readable pipe, as used for stdin/stdout/stderr of a child process.
// result[0]: Resource
// result[1]: file descriptor for child process.
PRIMITIVE(create_pipe) {
  ARGS(PipeResourceGroup, resource_group, bool, input);
  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) FAIL(ALLOCATION_FAILED);
  Array* array = process->object_heap()->allocate_array(2, Smi::zero());
  if (array == null) FAIL(ALLOCATION_FAILED);

  HANDLE event = CreateEvent(NULL, true, false, NULL);
  if (event == INVALID_HANDLE_VALUE) WINDOWS_ERROR;

  char pipe_name_buffer[MAX_PATH];
  snprintf(pipe_name_buffer,
           MAX_PATH,
           R"(\\.\Pipe\Toit.%08lx.%08lx)",
           GetCurrentProcessId(),
           InterlockedIncrement(&resource_group->pipe_serial_number())
  );

  SECURITY_ATTRIBUTES security_attributes;

  // Set the bInheritHandle flag so pipe handles are inherited.
  security_attributes.nLength = sizeof(SECURITY_ATTRIBUTES);
  security_attributes.bInheritHandle = input;
  security_attributes.lpSecurityDescriptor = NULL;

  // 'input' is from the point of view of the child process.
  int read_overlap_flag = input ? 0 : FILE_FLAG_OVERLAPPED;
  int write_overlap_flag = input ? FILE_FLAG_OVERLAPPED : 0;

  HANDLE read = CreateNamedPipe(
      pipe_name_buffer,
      PIPE_ACCESS_INBOUND | read_overlap_flag,
      PIPE_TYPE_BYTE | PIPE_WAIT,
      1,             // Number of pipes.
      8192,          // Out buffer size.
      8192,          // In buffer size..
      0,             // Default timeout (50 ms).
      &security_attributes
  );

  if (read == INVALID_HANDLE_VALUE) {
    close_handle_keep_errno(event);
    WINDOWS_ERROR;
  }

  security_attributes.bInheritHandle = !input;

  HANDLE write = CreateFileA(
      pipe_name_buffer,
      GENERIC_WRITE,
      0,                         // No sharing
      &security_attributes,
      OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL | write_overlap_flag,
      NULL                       // Template file
  );

  if (write == INVALID_HANDLE_VALUE) {
    close_handle_keep_errno(event);
    close_handle_keep_errno(read);
    WINDOWS_ERROR;
  }

  HandlePipeResource* pipe_resource;
  if (input) pipe_resource = _new WritePipeResource(resource_group, write, event);
  else pipe_resource = _new ReadPipeResource(resource_group, read, event);

  if (!pipe_resource) {
    CloseHandle(read);
    CloseHandle(write);
    CloseHandle(event);
    FAIL(MALLOC_FAILED);
  }

  resource_group->register_resource(pipe_resource);

  resource_proxy->set_external_address(pipe_resource);

  array->at_put(0, resource_proxy);
  // Windows handles are actually limited to 24 bit so this should work
  // OK.
  array->at_put(1, Smi::from(reinterpret_cast<word>(input ? read : write)));

  return array;
}

class CopyPipeState {
 public:
  CopyPipeState(HANDLE from, HANDLE to) : from_(from), to_(to) {}

  ~CopyPipeState() {
    CloseHandle(from_);
    CloseHandle(to_);
  }

  DWORD copy_loop() {
    char buffer[4096];
    DWORD read_count;
    DWORD write_count;
    while (ReadFile(from_, buffer, sizeof(buffer), &read_count, NULL) && read_count > 0) {
      if (!WriteFile(to_, buffer, read_count, &write_count, NULL)) {
        return 1;
      }
    }
    return 0;
  }

 private:
  HANDLE from_;
  HANDLE to_;
};

static DWORD __attribute__((stdcall)) copy_pipe_thread(void* data) {
  auto state = reinterpret_cast<CopyPipeState*>(data);
  DWORD result = state->copy_loop();
  delete state;
  return result;
}

PRIMITIVE(fd_to_pipe) {
  ARGS(PipeResourceGroup, resource_group, int, fd);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) FAIL(ALLOCATION_FAILED);

  // We have no way to detect the direction of the file descriptor, so
  // we assume they are used in the traditional directions: 0 - stdin,
  // 1 - stdout, 2 - stderr.
  if (fd < 0 || fd > 2) FAIL(INVALID_ARGUMENT);

  // Check if the standard handle has already been made a pipe. The overlapped
  // IO does not support multiple clients.
  if (resource_group->is_standard_piped(fd)) FAIL(INVALID_ARGUMENT);

  HANDLE event = CreateEvent(NULL, true, false, NULL);
  if (event == INVALID_HANDLE_VALUE) WINDOWS_ERROR;
  HandlePipeResource* pipe_resource;

  HANDLE handle = reinterpret_cast<HANDLE>(_get_osfhandle(fd));
  if (handle == INVALID_HANDLE_VALUE) WINDOWS_ERROR;
  int type = GetFileType(handle);
  if (type != FILE_TYPE_PIPE && type != FILE_TYPE_CHAR) {
    FAIL(INVALID_ARGUMENT);  // Ceci n'est pas une pipe.
  }

  bool for_writing = fd != 0;  // Stdin vs stdout or stderr.

  // If the pipe was in overlapped mode we could just make a PipeResource with
  // _new WritePipeResource(resource_group, handle, event) or _new
  // ReadPipeResource(resource_group, handle, event).  This is what our parent
  // process has done if it is a Toit process.  But it is not normal to give a
  // child process stdio pipes in overlapped mode, and it's really hard to
  // detect it even if it happened (see
  // https://microsoft.public.win32.programmer.kernel.narkive.com/VYscuhWn/was-handle-opened-using-file-flag-overlapped
  // or https://archive.vn/wip/bmGhS), so we assume the pipes are in
  // non-overlapped (synchronous) mode.

  // Our pipe is not in overlapped mode, and unfortunately Windows has
  // no way to switch to overlapped mode.  So we create a new pipe,
  // and copy the data from the old pipe to the new pipe in a separate
  // thread.
  int read_overlap_flag = for_writing ? 0 : FILE_FLAG_OVERLAPPED;
  int write_overlap_flag = for_writing ? FILE_FLAG_OVERLAPPED : 0;

  char pipe_name_buffer[MAX_PATH];
  snprintf(pipe_name_buffer,
           MAX_PATH,
           R"(\\.\Pipe\Toit.%08lx.%08lx)",
           GetCurrentProcessId(),
           InterlockedIncrement(&resource_group->pipe_serial_number())
  );
  HANDLE read = CreateNamedPipe(
      pipe_name_buffer,
      PIPE_ACCESS_INBOUND | read_overlap_flag,
      PIPE_TYPE_BYTE | PIPE_WAIT,
      1,             // Number of pipes.
      8192,          // Out buffer size.
      8192,          // In buffer size.
      0,             // Default timeout (50 ms).
      NULL           // Security attributes.
  );
  if (read == INVALID_HANDLE_VALUE) {
    close_handle_keep_errno(event);
    WINDOWS_ERROR;
  }
  HANDLE write = CreateFileA(
      pipe_name_buffer,
      GENERIC_WRITE,
      0,                         // No sharing.
      NULL,                      // Security attributes.
      OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL | write_overlap_flag,
      NULL                       // Template file.
  );
  if (write == INVALID_HANDLE_VALUE) {
    close_handle_keep_errno(event);
    close_handle_keep_errno(read);
    WINDOWS_ERROR;
  }
  CopyPipeState* state = for_writing
      ? _new CopyPipeState(read, handle)
      : _new CopyPipeState(handle, write);
  ASSERT(state);  // Can't fail on host platforms.
  HANDLE thread = CreateThread(NULL, 0, copy_pipe_thread, state, 0, NULL);
  if (thread == NULL) {
    close_handle_keep_errno(event);
    close_handle_keep_errno(read);
    close_handle_keep_errno(write);
    delete state;
    WINDOWS_ERROR;
  }
  if (for_writing) {
    pipe_resource = _new WritePipeResource(resource_group, write, event);
  } else {
    pipe_resource = _new ReadPipeResource(resource_group, read, event);
  }

  ASSERT(pipe_resource);  // Can't fail on host platforms.

  resource_group->set_standard_piped(fd);

  resource_proxy->set_external_address(pipe_resource);
  resource_group->register_resource(pipe_resource);

  return resource_proxy;
}

PRIMITIVE(is_a_tty) {
  ARGS(Resource, resource);
  auto pipe_resource = reinterpret_cast<HandlePipeResource*>(resource);

  DWORD tmp;
  const BOOL success = GetConsoleMode(pipe_resource->handle(), &tmp);
  return BOOL(success);
}

PRIMITIVE(fd) {
  ARGS(Resource, resource);
  auto handle_resource = reinterpret_cast<HandlePipeResource*>(resource);

  return Smi::from(reinterpret_cast<word>(handle_resource->handle()));
}


PRIMITIVE(write) {
  ARGS(WritePipeResource, pipe_resource, Blob, data, int, from, int, to);

  const uint8* tx = data.address();
  if (from < 0 || from > to || to > data.length()) FAIL(OUT_OF_RANGE);
  tx += from;

  if (!pipe_resource->ready_for_write()) return Smi::from(0);

  if (!pipe_resource->send(tx, to - from)) WINDOWS_ERROR;

  return Smi::from(to - from);
}

PRIMITIVE(read) {
  ARGS(ReadPipeResource, read_resource);

  if (read_resource->pipe_ended()) return process->null_object();
  if (!read_resource->read_ready()) return Smi::from(-1);

  ByteArray* array = process->allocate_byte_array(READ_BUFFER_SIZE, true);
  if (array == null) FAIL(ALLOCATION_FAILED);

  if (!read_resource->receive_read_response()) {
    if (GetLastError() == ERROR_BROKEN_PIPE) return process->null_object();
    WINDOWS_ERROR;
  }

  // A read count of 0 means EOF
  if (read_resource->read_count() == 0) return process->null_object();

  array->resize_external(process, read_resource->read_count());

  memcpy(ByteArray::Bytes(array).address(), read_resource->read_buffer(), read_resource->read_count());

  if (!read_resource->issue_read_request()) {
    if (GetLastError() != ERROR_BROKEN_PIPE) WINDOWS_ERROR;
    read_resource->set_pipe_ended(true);
  }

  return array;
}

HANDLE handle_from_object(Object* object, DWORD std_handle) {
  if (is_smi(object)) {
    int fd = static_cast<int>(Smi::value(object));
    if (fd == -1) return GetStdHandle(std_handle);
    return reinterpret_cast<HANDLE>(fd);
  } else if (is_byte_array(object)) {
    ByteArray* array = ByteArray::cast(object);
    if (!array->has_external_address()) return INVALID_HANDLE_VALUE;
    if (array->external_tag() != IntResource::tag) return INVALID_HANDLE_VALUE;
    return reinterpret_cast<HANDLE>(array->as_external<IntResource>()->id());
  }
  return INVALID_HANDLE_VALUE;
}

bool is_inherited(Object* object) {
  return is_smi(object) && static_cast<int>(Smi::value(object)) == -1;
}
const int MAX_COMMAND_LINE_LENGTH = 32768;

// Forks and execs a program (optionally found using the PATH environment
// variable.  The given file descriptors should be open file descriptors.  They
// are attached to the stdin, stdout and stderr of the launched program, and
// are closed in the parent program.  If you pass -1 for any of these then the
// forked program inherits the stdin/out/err of this Toit program.
static Object* fork_helper(
    Process* process,
    SubprocessResourceGroup* resource_group,
    bool use_path,
    Object* in_object,
    Object* out_object,
    Object* err_object,
    int fd_3,
    int fd_4,
    Array* arguments,
    Object* environment_object) {
  if (arguments->length() > 1000000) FAIL(OUT_OF_BOUNDS);

  Object* null_object = process->null_object();
  Array* environment = null;
  if (environment_object != null_object) {
    if (!is_array(environment_object)) FAIL(INVALID_ARGUMENT);
    environment = Array::cast(environment_object);

    // Validate environment array.
    if (environment->length() >= 0x100000 || (environment->length() & 1) != 0) FAIL(OUT_OF_BOUNDS);
    for (int i = 0; i < environment->length(); i++) {
      Blob blob;
      Object* element = environment->at(i);
      bool is_key = (i & 1) == 0;
      if (!is_key && element == process->null_object()) continue;
      if (!element->byte_content(process->program(), &blob, STRINGS_ONLY)) FAIL(WRONG_OBJECT_TYPE);
      if (blob.length() == 0) FAIL(INVALID_ARGUMENT);
      const uint8* str = blob.address();
      if (is_key && memchr(str, '=', blob.length()) != null) FAIL(INVALID_ARGUMENT);  // Key can't contain "=".
    }
  }

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  // FD_3 and FD_4 is not supported on Windows.
  if (fd_3 != -1 || fd_4 != -1) FAIL(INVALID_ARGUMENT);

  // Clearing environment not supported on windows, yet.
  if (!use_path) FAIL(INVALID_ARGUMENT);

  WideCharAllocationManager allocation(process);
  auto command_line = allocation.wcs_alloc(MAX_COMMAND_LINE_LENGTH + 1);

  int pos = 0;
  for (int i = 0; i < arguments->length(); i++) {
    const wchar_t* format = (i != arguments->length() - 1) ? L"%ls " : L"%ls";
    Blob argument;
    if (!arguments->at(i)->byte_content(process->program(), &argument, STRINGS_ONLY)) {
      FAIL(WRONG_OBJECT_TYPE);
    }
    WideCharAllocationManager allocation(process);
    auto utf_16_argument = allocation.to_wcs(&argument);

    if (pos + wcslen(utf_16_argument) + wcslen(format) - 3 >= MAX_COMMAND_LINE_LENGTH) FAIL(OUT_OF_BOUNDS);
    pos += snwprintf(command_line + pos, MAX_COMMAND_LINE_LENGTH - pos, format, utf_16_argument);
  }

  // We allocate memory for the SubprocessResource early here so we can handle failure
  // and restart the primitive.  If we wait until after the fork, the
  // subprocess is already running, and it is too late to GC-and-retry.
  AllocationManager resource_allocation(process);
  if (resource_allocation.alloc(sizeof(SubprocessResource)) == null) {
    FAIL(ALLOCATION_FAILED);
  }

  PROCESS_INFORMATION process_information{};
  STARTUPINFOW startup_info{};

  startup_info.cb = sizeof(STARTUPINFOW);
  startup_info.hStdInput = handle_from_object(in_object, STD_INPUT_HANDLE);
  startup_info.hStdOutput = handle_from_object(out_object, STD_OUTPUT_HANDLE);
  startup_info.hStdError = handle_from_object(err_object, STD_ERROR_HANDLE);
  startup_info.dwFlags |= STARTF_USESTDHANDLES;

  const wchar_t* current_directory = current_dir(process);

  wchar_t* new_environment = NULL;
  if (environment) {
    uint16* old_environment = reinterpret_cast<uint16*>(GetEnvironmentStringsW());
    new_environment = reinterpret_cast<wchar_t*>(Utils::create_new_environment(process, old_environment, environment));
    FreeEnvironmentStringsW(reinterpret_cast<wchar_t*>(old_environment));
  }

  if (!CreateProcessW(NULL,
                      command_line,
                      NULL,
                      NULL,
                      TRUE,  // inherit handles.
                      CREATE_UNICODE_ENVIRONMENT,     // creation flags
                      new_environment,
                      current_directory,
                      &startup_info,
                      &process_information)) {
    if (new_environment) free(new_environment);
    WINDOWS_ERROR;
  }

  if (new_environment) free(new_environment);

  // Release any handles that are pipes and are parsed down to the child
  if (GetFileType(startup_info.hStdInput) == FILE_TYPE_PIPE && !is_inherited(in_object))
    CloseHandle(startup_info.hStdInput);
  if (GetFileType(startup_info.hStdOutput) == FILE_TYPE_PIPE && !is_inherited(out_object))
    CloseHandle(startup_info.hStdOutput);
  if (GetFileType(startup_info.hStdError) == FILE_TYPE_PIPE && !is_inherited(err_object))
    CloseHandle(startup_info.hStdError);

  if (!process_information.hProcess) {
    // We are running on Wine, and we have started a Linux executable,
    // which means we can't track when it terminates.  But we already
    // started the process.  We don't want to define yet another C++-thrown
    // exception for this marginal case, so we throw one of the standard
    // exceptions here, but also print a warning on stderr.
    fprintf(stderr, "Error: Running a Linux executable from Wine is not supported: '%ls'\n", command_line);
    FAIL(INVALID_ARGUMENT);
  }

  auto subprocess = new (resource_allocation.keep_result()) SubprocessResource(resource_group, process_information.hProcess);
  proxy->set_external_address(subprocess);

  resource_group->register_resource(subprocess);

  return proxy;
}

PRIMITIVE(fork) {
  ARGS(SubprocessResourceGroup, resource_group,
       bool, use_path,
       Object, in_obj,
       Object, out_obj,
       Object, err_obj,
       int, fd_3,
       int, fd_4,
       CStringBlob, command,
       Array, args);
  USE(command);  // Not used on Windows.
  return fork_helper(process, resource_group, use_path, in_obj, out_obj, err_obj,
                     fd_3, fd_4, args, process->null_object());
}

PRIMITIVE(fork2) {
  ARGS(SubprocessResourceGroup, resource_group,
       bool, use_path,
       Object, in_obj,
       Object, out_obj,
       Object, err_obj,
       int, fd_3,
       int, fd_4,
       CStringBlob, command,
       Array, args,
       Object, environment_object);
  USE(command);  // Not used on Windows.
  return fork_helper(process, resource_group, use_path, in_obj, out_obj, err_obj,
                     fd_3, fd_4, args, environment_object);
}

} // namespace toit

#endif // TOIT_LINUX or TOIT_BSD
