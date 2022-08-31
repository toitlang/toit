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

#ifdef TOIT_WINDOWS

#include "windows.h"
#include "winbase.h"
#include <tchar.h>
#include <stdio.h>

#include "../objects.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
namespace toit {

const int kReadState = 1 << 0;
const int kErrorState = 1 << 1;
const int kWriteState = 1 << 2;

class HandleResource : public Resource {
public:
  TAG(IntResource);
  HandleResource(ResourceGroup* group, HANDLE handle)
      : Resource(group)
      , _handle(handle) {}

  HANDLE handle() { return _handle; }

  void close() {
    CloseHandle(_handle);
  }

  bool rts() const { return rts_; }
  bool dtr() const { return dtr_; }
  void set_rts(bool rts) { rts_ = rts; }
  void set_dtr(bool dtr) { dtr_ = dtr; }

private:
  HANDLE _handle;
  bool rts_ = false;
  bool dtr_ = false;
};

class UARTResourceGroup : public ResourceGroup {
public:
  TAG(UARTResourceGroup);
  explicit UARTResourceGroup(Process* process)
      : ResourceGroup(process, null) { }

  HandleResource* register_handle(HANDLE handle) {
    auto resource = _new HandleResource(this, handle);
    if (resource) register_resource(resource);
    return resource;
  }

private:
  uint32_t on_event(Resource* resource, word data, uint32_t state) {
    return state;
  }
};

MODULE_IMPLEMENTATION(uart, MODULE_UART);

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  auto resource_group = _new UARTResourceGroup(process);

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
  HANDLE handle = CreateFile(serial_name,
                             GENERIC_READ | GENERIC_WRITE,
                             0,      //  must be opened with exclusive-access
                             NULL,   //  default security attributes
                             OPEN_EXISTING, //  must use OPEN_EXISTING
                             0,      //  not overlapped I/O
                             NULL ); //  hTemplate must be NULL for comm devices

  if (handle == INVALID_HANDLE_VALUE) {
    return Primitive::os_error(errno, process);
  }

  DCB dcb;
  SecureZeroMemory(&dcb, sizeof(DCB));
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

  bool success = SetCommState(handle, &dcb);

  if (!success) {
    CloseHandle(handle);
    return Primitive::os_error(errno, process);
  }

  // Setup timeouts
  // Read never blocks
  // Write never times out
  COMMTIMEOUTS comm_timeouts;
  SecureZeroMemory(&comm_timeouts, sizeof(COMMTIMEOUTS));
  comm_timeouts.ReadIntervalTimeout = MAXDWORD;
  success = SetCommTimeouts(handle, &comm_timeouts);
  if (!success) {
    CloseHandle(handle);
    return Primitive::os_error(errno, process);
  }

  HandleResource* resource = resource_group->register_handle(handle);
  // We are running on Windows. As such we should never have malloc that fails.
  // Normally, we would need to clean up, if the allocation fails, but if that
  // happens on Windows, we are in big trouble anyway.
  if (!resource) MALLOC_FAILED;
  resource_proxy->set_external_address(resource);
  return resource_proxy;
}

PRIMITIVE(close) {
  ARGS(UARTResourceGroup, resource_group, HandleResource, uart_resource);
  resource_group->unregister_resource(uart_resource);
  uart_resource_proxy->clear_external_address();
  return process->program()->null_object();
}

PRIMITIVE(get_baud_rate) {
  ARGS(HandleResource, resource);
  HANDLE handle = resource->handle();
  DCB dcb;
  bool success = GetCommState(handle, &dcb);
  if (!success) {
    return Primitive::os_error(errno, process);
  }

  return Primitive::integer(dcb.BaudRate, process);
}

PRIMITIVE(set_baud_rate) {
  ARGS(HandleResource, resource, int, baud_rate);

  HANDLE handle = resource->handle();
  DCB dcb;
  bool success = GetCommState(handle, &dcb);
  if (!success) {
    return Primitive::os_error(errno, process);
  }

  dcb.BaudRate = baud_rate;
  success = SetCommState(handle, &dcb);
  if (!success) {
    return Primitive::os_error(errno, process);
  }

  return process->program()->null_object();
}

// Writes the data to the UART.
// Does not support break or wait
PRIMITIVE(write) {
  ARGS(HandleResource, resource, Blob, data, int, from, int, to, int, break_length, bool, wait);

  if (break_length > 0 || wait) INVALID_ARGUMENT;

  HANDLE handle = resource->handle();

  const uint8* tx = data.address();
  if (from < 0 || from > to || to > data.length()) OUT_OF_RANGE;
  tx += from;

  if (break_length < 0) OUT_OF_RANGE;
  DWORD written;
  bool success = WriteFile(handle, tx, to - from, &written, null);

  if (!success) {
    return Primitive::os_error(errno, process);
  }

  return Smi::from(written);
}

PRIMITIVE(wait_tx) {
  UNIMPLEMENTED_PRIMITIVE; // TODO, Use WaitEvent on EV_TXEMPTY
}

PRIMITIVE(read) {
  ARGS(HandleResource, resource);
  HANDLE handle = resource->handle();

  COMSTAT comm_stats;
  DWORD comm_errors;
  if (!ClearCommError(handle, &comm_errors, &comm_stats)) return Primitive::os_error(errno, process);

  if (comm_stats.cbInQue == 0) return process->program()->null_object();

  Error* error = null;
  ByteArray* data = process->allocate_byte_array(static_cast<int>(comm_stats.cbInQue), &error, /*force_external*/ true);
  if (data == null) return error;

  DWORD bytes_read;
  ByteArray::Bytes rx(data);
  bool success = ReadFile(handle, rx.address(), rx.length(), &bytes_read, null);
  if (!success) {
    return Primitive::os_error(errno, process);
  }

  return data;
}

const int CONTROL_FLAG_LE  = 1 << 0;            /* line enable */
const int CONTROL_FLAG_DTR = 1 << 1;            /* data terminal ready */
const int CONTROL_FLAG_RTS = 1 << 2;            /* request to send */
const int CONTROL_FLAG_ST  = 1 << 3;            /* secondary transmit */
const int CONTROL_FLAG_SR  = 1 << 4;            /* secondary receive */
const int CONTROL_FLAG_CTS = 1 << 5;            /* clear to send */
const int CONTROL_FLAG_CAR = 1 << 6;            /* carrier detect */
const int CONTROL_FLAG_RNG = 1 << 7;            /* ring */
const int CONTROL_FLAG_DSR = 1 << 8;            /* data set ready */

PRIMITIVE(set_control_flags) {
  ARGS(HandleResource, resource, int, flags);
  HANDLE handle = resource->handle();
  if ((flags & CONTROL_FLAG_DTR) && !resource->dtr()) {
    if (!EscapeCommFunction(handle, SETDTR)) return Primitive::os_error(errno, process);
  } else if (!(flags & CONTROL_FLAG_DTR) && resource->dtr()) {
    if (!EscapeCommFunction(handle, CLRDTR)) return Primitive::os_error(errno, process);
  }
  resource->set_dtr(flags & CONTROL_FLAG_DTR);

  if ((flags & CONTROL_FLAG_RTS) && !resource->rts()) {
    if (!EscapeCommFunction(handle, SETRTS)) return Primitive::os_error(errno, process);
  } else if (!(flags & CONTROL_FLAG_RTS) && resource->rts()){
    if (!EscapeCommFunction(handle, CLRRTS)) return Primitive::os_error(errno, process);
  }
  resource->set_rts(flags & CONTROL_FLAG_DTR);

  return process->program()->null_object();
}

PRIMITIVE(get_control_flags) {
  ARGS(HandleResource, resource);

  int flags = 0;
  if (resource->dtr()) flags |= CONTROL_FLAG_DTR;
  if (resource->rts()) flags |= CONTROL_FLAG_RTS;

  DWORD modem_stats;
  if (GetCommModemStatus(resource->handle(), &modem_stats)) {
    if (modem_stats & MS_CTS_ON) flags |= CONTROL_FLAG_CTS;
    if (modem_stats & MS_DSR_ON) flags |= CONTROL_FLAG_DSR;
    if (modem_stats & MS_RING_ON) flags |= CONTROL_FLAG_RNG;
    if (modem_stats & MS_RLSD_ON) flags |= CONTROL_FLAG_CAR;
  }


  return Smi::from(flags);
}


}
#endif