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

#ifdef TOIT_LINUX

#include "../primitive.h"
#include "../objects_inline.h"
#include "../process.h"

#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/spi/spidev.h>

#include "../event_sources/spi_linux.h"

namespace toit {

enum {
  kTransferDone = 1 << 0,
};

// Defined in primitive_file_non_win.cc.
extern Object* return_open_error(Process* process, int err);

class SpiResourceGroup : public ResourceGroup {
 public:
  TAG(SpiResourceGroup);
  explicit SpiResourceGroup(Process* process)
    : ResourceGroup(process, SpiEventSource::instance()) {}

 protected:
  void on_unregister_resource(Resource* resource) override;

  uint32 on_event(Resource* resource, word data, uint32_t state) override {
    USE(resource);
    state |= data;
    return state;
  }
};


class SpiResource : public Resource {
 public:
  TAG(SpiResource);
  SpiResource(ResourceGroup* group);
  ~SpiResource();

  int fd() { return fd_; }
  void set_fd(int fd) {
    ASSERT(fd_ == -1);
    fd_ = fd;
  }

  int error() const { return error_; }
  void set_error(int error) { error_ = error; }

  uint8* buffer() { return buffer_; }

  Object* transfer_start(Blob data, int from, int length,
                         bool is_read,
                         int delay_usecs,
                         bool cs_change,
                         Process* process);

  Object* transfer_finish(bool was_read, Process* process);

 private:
  int fd_ = -1;
  int error_ = 0;
  AsyncEventThread* thread_ = null;
  int buffer_size_ = 0;
  uint8* buffer_ = null;
};

void SpiResourceGroup::on_unregister_resource(Resource* resource) {
  int fd = static_cast<SpiResource*>(resource)->fd();
  int result = EINTR;
  while (result == EINTR) {
    result = close(fd);
  }
}

SpiResource::SpiResource(ResourceGroup* group) : Resource(group) {}

SpiResource::~SpiResource() {
  if (thread_ != null) {
    delete thread_;
  }
  if (fd_ >= 0) {
    close(fd_);
  }
  if (buffer_ != null) {
    free(buffer_);
  }
}

Object* SpiResource::transfer_start(Blob data, int from, int length,
                                    bool is_read,
                                    int delay_usecs,
                                    bool cs_change,
                                    Process* process) {
  bool successfully_dispatched = false;
  if (buffer_ != null) FAIL(INVALID_STATE);
  if (length <= 0 || delay_usecs < 0 || delay_usecs > 0xffff) FAIL(OUT_OF_BOUNDS);
  if (from < 0 || from + length > data.length()) FAIL(OUT_OF_BOUNDS);

  // Since we are returning to the user, we can't hold onto the data and need to copy it.
  // TODO(florian): allow to neuter incoming external byte arrays.
  uint8* buffer = unvoid_cast<uint8*>(malloc(length));
  if (buffer == null) FAIL(MALLOC_FAILED);
  Defer free_buffer{ [&] { if (!successfully_dispatched) free(buffer); } };

  memcpy(buffer, data.address() + from, length);

  auto tx_address = buffer;
  // Reuse the same buffer for reading.
  auto rx_address = is_read ? buffer : null;

  auto xfer = unvoid_cast<struct spi_ioc_transfer*>(calloc(1, sizeof(struct spi_ioc_transfer)));
  if (xfer == null) FAIL(MALLOC_FAILED);
  Defer free_xfer{ [&] { if (!successfully_dispatched) free(xfer); } };

  xfer->tx_buf = reinterpret_cast<uint64>(tx_address);
  xfer->rx_buf = reinterpret_cast<uint64>(rx_address);
  xfer->len = length;
  xfer->delay_usecs = delay_usecs;
  // TODO(florian): this is probably inverted.
  // See: https://github.com/beagleboard/kernel/issues/85
  xfer->cs_change = cs_change ? 0x01 : 0x00;

  if (thread_ == null) {
    thread_ = _new AsyncEventThread("SPI", SpiEventSource::instance());
    if (thread_ == null) FAIL(MALLOC_FAILED);
    thread_->start();
  }

  buffer_ = buffer;
  buffer_size_ = length;
  successfully_dispatched = thread_->run(this, [xfer](Resource* resource) {
    auto spi = static_cast<SpiResource*>(resource);
    int fd = spi->fd();
    int ret = ioctl(fd, SPI_IOC_MESSAGE(1), xfer);
    spi->set_error(ret == -1 ? errno : 0);
    free(xfer);
    return kTransferDone;
  });

  if (!successfully_dispatched) FAIL(INVALID_STATE);
  // False means that the Toit side needs to asynchronously wait for us.
  return BOOL(false);
}

Object* SpiResource::transfer_finish(bool was_read, Process* process) {
  if (buffer_ == null) FAIL(INVALID_STATE);
  if (error_ != 0) {
    free(buffer_);
    buffer_ = null;
    return Primitive::os_error(error_, process);
  }
  if (!was_read) {
    free(buffer_);
    buffer_ = null;
    return process->null_object();
  }
  auto result_buffer = buffer_;
  int buffer_size = buffer_size_;
  buffer_ = null;
  buffer_size_ = 0;
  bool dispose, clear_content;
  return process->object_heap()->allocate_external_byte_array(buffer_size,
                                                              result_buffer,
                                                              dispose=true,
                                                              clear_content=false);
}

MODULE_IMPLEMENTATION(spi_linux, MODULE_SPI_LINUX);

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto group = _new SpiResourceGroup(process);
  if (group == null) FAIL(MALLOC_FAILED);

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(open) {
  ARGS(SpiResourceGroup, group, cstring, pathname, int, frequency, int, mode);
  if (frequency <= 0) FAIL(INVALID_ARGUMENT);
  if (mode < 0 || mode > 3) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  // We allocate the resource as early as possible, as the allocation might fail.
  // However, until the file descriptor is set, the resource is not safe to use.
  auto unsafe_resource = _new SpiResource(group);
  if (unsafe_resource == NULL) FAIL(MALLOC_FAILED);

  // We always set the close-on-exec flag otherwise we leak descriptors when we fork.
  // File descriptors that are intended for subprocesses have the flags cleared.
  int fd = open(pathname, O_CLOEXEC | O_RDWR);
  if (fd < 0) return return_open_error(process, errno);
  // "WR"ite the max speed and mode.
  int ret = ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, &frequency);
  if (ret < 0) {
    close(fd);
    return Primitive::os_error(errno, process);
  }
  uint8 mode_byte;
  switch (mode) {
    case 0: mode_byte = SPI_MODE_0; break;
    case 1: mode_byte = SPI_MODE_1; break;
    case 2: mode_byte = SPI_MODE_2; break;
    case 3: mode_byte = SPI_MODE_3; break;
    default: UNREACHABLE();
  }
  ret = ioctl(fd, SPI_IOC_WR_MODE, &mode_byte);
  if (ret < 0) {
    close(fd);
    return Primitive::os_error(errno, process);
  }

  unsafe_resource->set_fd(fd);
  auto resource = unsafe_resource;

  group->register_resource(resource);
  proxy->set_external_address(resource);

  return proxy;
}

PRIMITIVE(close) {
  ARGS(SpiResource, resource);
  resource->resource_group()->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(transfer_start) {
  ARGS(SpiResource, resource, Blob, data, int, from, int, length, bool, is_read, int, delay_usecs, bool, cs_change);

  return resource->transfer_start(data, from, length, is_read, delay_usecs, cs_change, process);
}

PRIMITIVE(transfer_finish) {
  ARGS(SpiResource, resource, bool, was_read);
  return resource->transfer_finish(was_read, process);
}

}  // namespace toit

#endif
