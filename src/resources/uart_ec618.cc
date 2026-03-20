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

#include "../top.h"

#ifdef TOIT_EC618

#include "../event_sources/uart_ec618.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"

extern "C" {
  #include "Driver_USART.h"
  extern ARM_DRIVER_USART *UsartPrintHandle;
}

namespace toit {

// Circular buffer for UART receive data.
static const int NUM_SEGMENTS = 4;
static const int SEGMENT_SIZE = 1024;
static uint8 uart_buffer[NUM_SEGMENTS][SEGMENT_SIZE];
static volatile int write_segment = 0;
static volatile int write_offset = 0;
static volatile int read_segment = 0;
static volatile bool overflow = false;
static volatile bool uart_initialized = false;

// Called from bsp_custom.c (the PLAT UART ISR callback).
extern "C" void toit_uart_event(uint32_t event_flags, const uint8_t* data, int length) {
  if (!uart_initialized) return;
  if (length <= 0) return;

  int seg = write_segment;
  int off = write_offset;
  for (int i = 0; i < length; i++) {
    uart_buffer[seg][off++] = data[i];
    if (off >= SEGMENT_SIZE) {
      off = 0;
      seg = (seg + 1) % NUM_SEGMENTS;
      if (seg == read_segment) {
        // Overflow: advance read pointer.
        overflow = true;
        read_segment = (read_segment + 1) % NUM_SEGMENTS;
      }
    }
  }
  write_segment = seg;
  write_offset = off;

  // Notify the event source.
  UartQcx216EventSource::send_event_from_isr(Event::UART, 0);
}

class UartQcx216ResourceGroup : public ResourceGroup {
 public:
  TAG(UartQcx216ResourceGroup);
  explicit UartQcx216ResourceGroup(Process* process, EventSource* event_source)
    : ResourceGroup(process, event_source) {}
};

class UartQcx216Resource : public EventResource {
 public:
  TAG(UartQcx216Resource);
  UartQcx216Resource(ResourceGroup* group)
    : EventResource(group, Event::UART) {}
};

MODULE_IMPLEMENTATION(uart_ec618, MODULE_UART_EC618)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  UartQcx216EventSource* event_source = UartQcx216EventSource::instance();
  if (event_source == null) FAIL(ALREADY_CLOSED);

  UartQcx216ResourceGroup* group = _new UartQcx216ResourceGroup(process, event_source);
  if (group == null) FAIL(MALLOC_FAILED);

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(create) {
  ARGS(UartQcx216ResourceGroup, group);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  UartQcx216Resource* resource = _new UartQcx216Resource(group);
  if (resource == null) FAIL(MALLOC_FAILED);

  group->register_resource(resource);
  uart_initialized = true;
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(close) {
  ARGS(UartQcx216ResourceGroup, group, UartQcx216Resource, resource);
  uart_initialized = false;
  group->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(read) {
  ARGS(UartQcx216Resource, resource);
  USE(resource);

  int rseg = read_segment;
  int wseg = write_segment;
  int woff = write_offset;

  if (rseg == wseg && woff == 0 && !overflow) {
    // No data available.
    return process->null_object();
  }

  // Calculate available bytes.
  int available = 0;
  if (rseg == wseg) {
    available = woff;
  } else {
    // Bytes in read segment (from 0 to end).
    available = SEGMENT_SIZE;
    // Full segments between read and write.
    int seg = (rseg + 1) % NUM_SEGMENTS;
    while (seg != wseg) {
      available += SEGMENT_SIZE;
      seg = (seg + 1) % NUM_SEGMENTS;
    }
    available += woff;
  }

  if (available <= 0) return process->null_object();

  ByteArray* result = process->object_heap()->allocate_internal_byte_array(available);
  if (result == null) FAIL(ALLOCATION_FAILED);
  ByteArray::Bytes bytes(result);
  uint8* dest = bytes.address();

  int copied = 0;
  while (copied < available) {
    int seg = read_segment;
    int start = (seg == rseg && rseg == wseg) ? 0 : 0;
    int end = (seg == wseg) ? woff : SEGMENT_SIZE;
    int n = end - start;
    if (n > available - copied) n = available - copied;
    memcpy(dest + copied, uart_buffer[seg] + start, n);
    copied += n;
    if (end >= SEGMENT_SIZE) {
      read_segment = (seg + 1) % NUM_SEGMENTS;
    } else {
      break;
    }
  }

  overflow = false;
  return result;
}

}  // namespace toit

#endif  // TOIT_EC618
