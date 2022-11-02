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

#include "../top.h"

#ifdef TOIT_WINDOWS

#include "windows.h"
#include "winbase.h"
#include <tchar.h>
#include <cstdio>

#include "../objects.h"
#include "../objects_inline.h"

#include "../event_sources/event_win.h"

#include "error_win.h"

namespace toit {

const int kReadState = 1 << 0;
const int kErrorState = 1 << 1;
const int kWriteState = 1 << 2;

const int READ_BUFFER_SIZE = 1 << 16;

class UARTResource : public WindowsResource {
public:
  TAG(UARTResource);
  UARTResource(ResourceGroup* group, HANDLE uart, HANDLE read_event, HANDLE write_event, HANDLE error_event)
      : WindowsResource(group)
      , uart_(uart) {
    read_overlapped_.hEvent = read_event;
    write_overlapped_.hEvent = write_event;
    comm_events_overlapped_.hEvent = error_event;

    set_state(kWriteState);

    if (!issue_read_request()) {
      error_code_ = GetLastError();
    }

    if (!issue_comm_events_request()) {
      error_code_ = GetLastError();
    }
  }

  ~UARTResource() override {
    if (write_buffer_) free(write_buffer_);
  }

  HANDLE uart() { return uart_; }
  bool rts() const { return rts_; }
  bool dtr() const { return dtr_; }
  void set_rts(bool rts) { rts_ = rts; }
  void set_dtr(bool dtr) { dtr_ = dtr; }
  char* read_buffer() { return read_data_; }
  DWORD read_count() const { return read_count_; }
  bool ready_for_write() const { return write_ready_; }
  bool ready_for_read() const { return read_ready_ != 0; }
  bool has_error() const { return error_code_ != ERROR_SUCCESS; }
  DWORD error_code() const { return error_code_; }

  void do_close() override {
    CloseHandle(read_overlapped_.hEvent);
    CloseHandle(write_overlapped_.hEvent);
    CloseHandle(uart_);
  }

  std::vector<HANDLE> events() override {
    return std::vector<HANDLE>({
                                   read_overlapped_.hEvent,
                                   write_overlapped_.hEvent,
                                   comm_events_overlapped_.hEvent
    });
  }

  bool issue_comm_events_request() {
    bool succeeded = WaitCommEvent(uart_, &event_mask_, &comm_events_overlapped_);
    if (!succeeded && GetLastError() != ERROR_IO_PENDING) {
      return false;
    }
    return true;
  }

  bool issue_read_request() {
    read_ready_ = false;
    read_count_ = 0;
    bool success = ReadFile(uart_, read_data_, READ_BUFFER_SIZE, &read_count_, &read_overlapped_);
    if (!success && WSAGetLastError() != ERROR_IO_PENDING) {
      return false;
    }
    return true;
  }

  bool receive_read_response() {
    bool overlapped_result = GetOverlappedResult(uart_, &read_overlapped_, &read_count_, false);
    return overlapped_result;
  }

  bool send(const uint8* buffer, int length) {
    if (write_buffer_ != null) free(write_buffer_);

    write_ready_ = false;

    // We need to copy the buffer out to a long-lived heap object
    write_buffer_ = static_cast<char*>(malloc(length));
    memcpy(write_buffer_, buffer, length);

    DWORD tmp;
    bool send_result = WriteFile(uart_, buffer, length, &tmp, &write_overlapped_);
    if (!send_result && WSAGetLastError() != ERROR_IO_PENDING) {
      return false;
    }

    return true;
  }

  uint32_t on_event(HANDLE event, uint32_t state) override {
    if (event == read_overlapped_.hEvent) {
      read_ready_ = true;
      state |= kReadState;
    } else if (event == write_overlapped_.hEvent) {
      write_ready_ = true;
      state |= kWriteState;
    } else if (event == comm_events_overlapped_.hEvent) {
      DWORD tmp;
      bool succeeded = GetOverlappedResult(uart_, &comm_events_overlapped_, &tmp, false);
      if (!succeeded) {
        error_code_ = GetLastError();
      } else {
        if (event_mask_ & EV_ERR) state |= kErrorState;
        /* TODO(mikkel): Handle EV_TXEMPTY and EV_BREAK */

        if (!issue_comm_events_request()) {
          error_code_ = GetLastError();
        }
      }
    }
    return state;
  }

 private:
  HANDLE uart_;
  bool rts_ = false;
  bool dtr_ = false;

  char read_data_[READ_BUFFER_SIZE]{};
  OVERLAPPED read_overlapped_{};
  DWORD read_count_ = 0;
  bool read_ready_ = false;

  OVERLAPPED write_overlapped_{};
  char* write_buffer_ = null;
  bool write_ready_ = true;

  OVERLAPPED comm_events_overlapped_{};
  DWORD event_mask_ = 0;

  DWORD error_code_ = ERROR_SUCCESS;
};

class UARTResourceGroup : public ResourceGroup {
public:
  TAG(UARTResourceGroup);
  explicit UARTResourceGroup(Process* process, EventSource* event_source)
      : ResourceGroup(process, event_source) { }

private:
  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
    return reinterpret_cast<WindowsResource*>(resource)->on_event(
        reinterpret_cast<HANDLE>(data),
        state);
  }
};

MODULE_IMPLEMENTATION(uart, MODULE_UART);

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  auto resource_group = _new UARTResourceGroup(process, WindowsEventSource::instance());

  if (!WindowsEventSource::instance()->use()) {
    resource_group->tear_down();
    WINDOWS_ERROR;
  }

  if (!resource_group) MALLOC_FAILED;

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(create) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(create_path) {
  ARGS(UARTResourceGroup, resource_group, cstring, path, int, baud_rate, int, data_bits, int, stop_bits, int, parity);

  if (data_bits < 5 || data_bits > 8) INVALID_ARGUMENT;
  if (stop_bits < 1 || stop_bits > 3) INVALID_ARGUMENT;
  if (parity < 1 || parity > 3) INVALID_ARGUMENT;
  if (baud_rate <= 0) INVALID_ARGUMENT;
  if (strlen(path) > 5) INVALID_ARGUMENT; // Support up to COM99

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) ALLOCATION_FAILED;

  char serial_name[10];
  sprintf(serial_name,R"(\\.\%s)", path);
  HANDLE uart = CreateFile(serial_name,
                           GENERIC_READ | GENERIC_WRITE,
                           0,      //  must be opened with exclusive-access
                           NULL,   //  default security attributes
                           OPEN_EXISTING, //  must use OPEN_EXISTING
                           FILE_FLAG_OVERLAPPED,      //   overlapped I/O
                           NULL ); //  hTemplate must be NULL for comm devices

  if (uart == INVALID_HANDLE_VALUE) WINDOWS_ERROR;

  DCB dcb{};
  dcb.DCBlength = sizeof(DCB);
  dcb.fBinary = true;
  dcb.BaudRate = baud_rate;

  if (stop_bits == 1) {
    dcb.StopBits = ONESTOPBIT;
  } else if (stop_bits == 2) {
    dcb.StopBits = ONE5STOPBITS;
  } else {
    dcb.StopBits = TWOSTOPBITS;
  }

  dcb.ByteSize = data_bits;

  if (parity == 1) {
    dcb.fParity = false;
  } else if (parity == 2) {
    dcb.fParity = true;
    dcb.Parity = EVENPARITY;
  } else {
    dcb.fParity = true;
    dcb.Parity = ODDPARITY;
  }

  bool success = SetCommState(uart, &dcb);

  if (!success) {
    close_handle_keep_errno(uart);
    WINDOWS_ERROR;
  }

  // Setup timeouts
  // Read never blocks
  // Write never times out
  COMMTIMEOUTS comm_timeouts{};
  comm_timeouts.ReadIntervalTimeout = MAXDWORD;
  success = SetCommTimeouts(uart, &comm_timeouts);
  if (!success) {
    close_handle_keep_errno(uart);
    WINDOWS_ERROR;
  }

  // Setup Mask
  success = SetCommMask(uart, EV_ERR | EV_RXCHAR | EV_TXEMPTY);
  if (!success) {
    close_handle_keep_errno(uart);
    WINDOWS_ERROR;
  }

  HANDLE read_event = CreateEvent(NULL, true, false, NULL);
  if (read_event == INVALID_HANDLE_VALUE) {
    close_handle_keep_errno(uart);
    WINDOWS_ERROR;
  }

  HANDLE write_event = CreateEvent(NULL, true, false, NULL);
  if (write_event == INVALID_HANDLE_VALUE) {
    close_handle_keep_errno(uart);
    close_handle_keep_errno(read_event);
    WINDOWS_ERROR;
  }

  HANDLE error_event = CreateEvent(NULL, true, false, NULL);
  if (error_event == INVALID_HANDLE_VALUE) {
    close_handle_keep_errno(uart);
    close_handle_keep_errno(read_event);
    close_handle_keep_errno(write_event);
    WINDOWS_ERROR;
  }

  auto uart_resource = _new UARTResource(resource_group, uart, read_event, write_event, error_event);
  if (!uart_resource) {
    close_handle_keep_errno(uart);
    close_handle_keep_errno(read_event);
    close_handle_keep_errno(write_event);
    close_handle_keep_errno(error_event);
    MALLOC_FAILED;
  }

  resource_group->register_resource(uart_resource);

  resource_proxy->set_external_address(uart_resource);

  return resource_proxy;
}

PRIMITIVE(close) {
  ARGS(UARTResourceGroup, resource_group, UARTResource, uart_resource);
  resource_group->unregister_resource(uart_resource);
  uart_resource_proxy->clear_external_address();
  return process->program()->null_object();
}

PRIMITIVE(get_baud_rate) {
  ARGS(UARTResource, uart_resource);
  DCB dcb;

  bool success = GetCommState(uart_resource->uart(), &dcb);
  if (!success) WINDOWS_ERROR;

  return Primitive::integer(dcb.BaudRate, process);
}

PRIMITIVE(set_baud_rate) {
  ARGS(UARTResource, uart_resource, int, baud_rate);
  DCB dcb{};
  bool success = GetCommState(uart_resource->uart(), &dcb);
  if (!success) WINDOWS_ERROR;

  dcb.BaudRate = baud_rate;
  success = SetCommState(uart_resource->uart(), &dcb);
  if (!success) WINDOWS_ERROR;

  return process->program()->null_object();
}

// Writes the data to the UART.
// Does not support break or wait
PRIMITIVE(write) {
  ARGS(UARTResource, uart_resource, Blob, data, int, from, int, to, int, break_length, bool, wait);
  if (break_length > 0 || wait) INVALID_ARGUMENT;

  const uint8* tx = data.address();
  if (from < 0 || from > to || to > data.length()) OUT_OF_RANGE;
  tx += from;

  if (break_length < 0) OUT_OF_RANGE;

  if (uart_resource->has_error()) return windows_error(process, uart_resource->error_code());

  if (!uart_resource->ready_for_write()) return Smi::from(0);

  if (!uart_resource->send(tx, to - from)) WINDOWS_ERROR;

  return Smi::from(to - from);
}

PRIMITIVE(wait_tx) {
  UNIMPLEMENTED_PRIMITIVE; // TODO(mikkel), Use WaitEvent on EV_TXEMPTY
}

PRIMITIVE(read) {
  ARGS(UARTResource, uart_resource);

  if (uart_resource->has_error()) return windows_error(process, uart_resource->error_code());

  if (!uart_resource->ready_for_read()) return process->program()->null_object();

  if (!uart_resource->receive_read_response()) WINDOWS_ERROR;

  ByteArray* array = process->allocate_byte_array(static_cast<int>(uart_resource->read_count()));
  if (array == null) ALLOCATION_FAILED;

  memcpy(ByteArray::Bytes(array).address(), uart_resource->read_buffer(), uart_resource->read_count());

  if (!uart_resource->issue_read_request())  WINDOWS_ERROR;

  return array;
}

const int CONTROL_FLAG_DTR = 1 << 1;            /* data terminal ready */
const int CONTROL_FLAG_RTS = 1 << 2;            /* request to send */
const int CONTROL_FLAG_CTS = 1 << 5;            /* clear to send */
const int CONTROL_FLAG_CAR = 1 << 6;            /* carrier detect */
const int CONTROL_FLAG_RNG = 1 << 7;            /* ring */
const int CONTROL_FLAG_DSR = 1 << 8;            /* data set ready */

PRIMITIVE(set_control_flags) {
  ARGS(UARTResource, uart_resource, int, flags);
  HANDLE uart = uart_resource->uart();

  if ((flags & CONTROL_FLAG_DTR) && !uart_resource->dtr()) {
    if (!EscapeCommFunction(uart, SETDTR)) return Primitive::os_error(errno, process);
  } else if (!(flags & CONTROL_FLAG_DTR) && uart_resource->dtr()) {
    if (!EscapeCommFunction(uart, CLRDTR)) return Primitive::os_error(errno, process);
  }
  uart_resource->set_dtr((flags & CONTROL_FLAG_DTR) != 0);

  if ((flags & CONTROL_FLAG_RTS) && !uart_resource->rts()) {
    if (!EscapeCommFunction(uart, SETRTS)) return Primitive::os_error(errno, process);
  } else if (!(flags & CONTROL_FLAG_RTS) && uart_resource->rts()){
    if (!EscapeCommFunction(uart, CLRRTS)) return Primitive::os_error(errno, process);
  }
  uart_resource->set_rts((flags & CONTROL_FLAG_RTS) != 0);

  return process->program()->null_object();
}

PRIMITIVE(get_control_flags) {
  ARGS(UARTResource, uart_resource);

  int flags = 0;
  if (uart_resource->dtr()) flags |= CONTROL_FLAG_DTR;
  if (uart_resource->rts()) flags |= CONTROL_FLAG_RTS;

  DWORD modem_stats;
  if (GetCommModemStatus(uart_resource->uart(), &modem_stats)) {
    if (modem_stats & MS_CTS_ON) flags |= CONTROL_FLAG_CTS;
    if (modem_stats & MS_DSR_ON) flags |= CONTROL_FLAG_DSR;
    if (modem_stats & MS_RING_ON) flags |= CONTROL_FLAG_RNG;
    if (modem_stats & MS_RLSD_ON) flags |= CONTROL_FLAG_CAR;
  }

  return Smi::from(flags);
}

}
#endif
