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
#include "../process.h"

#include <fcntl.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/spi/spidev.h>

namespace toit {

// Defined in primitive_file_posix.cc.
extern Object* return_open_error(Process* process, int err);

MODULE_IMPLEMENTATION(spi_linux, MODULE_SPI_LINUX);

PRIMITIVE(open) {
  ARGS(cstring, pathname);
  // We always set the close-on-exec flag otherwise we leak descriptors when we fork.
  // File descriptors that are intended for subprocesses have the flags cleared.
  int fd = open(pathname, O_CLOEXEC | O_RDWR);
  if (fd < 0) return return_open_error(process, errno);
  return Smi::from(fd);
}

PRIMITIVE(transfer) {
  ARGS(int, fd, int, length, Object, tx, int, from_tx, Object, rx, int, from_rx, int, delay_usecs, bool, cs_change);

  Object* null_object = process->program()->null_object();
  if (length <= 0 || delay_usecs < 0 || delay_usecs > 0xffff) OUT_OF_BOUNDS;
  if (fd < 0) INVALID_ARGUMENT;

  const uint8* tx_address = null;
  if (tx != null_object) {
    Blob tx_blob;
    if (!tx->byte_content(process->program(), &tx_blob, STRINGS_OR_BYTE_ARRAYS)) WRONG_TYPE;
    int to_tx = from_tx + length;
    if (from_tx < 0 || to_tx > tx_blob.length()) OUT_OF_BOUNDS;
    tx_address = tx_blob.address() + from_tx;
  }

  uint8* rx_address = null;
  if (rx != null_object) {
    Error* error = null;
    MutableBlob rx_blob;
    if (!rx->mutable_byte_content(process, &rx_blob, &error)) {
      return error;
    }
    int to_rx = from_rx + length;
    if (from_rx < 0 || to_rx > rx_blob.length()) OUT_OF_BOUNDS;
    rx_address = rx_blob.address() + from_rx;
  }

  if (tx_address == null && rx_address == null) INVALID_ARGUMENT;

  struct spi_ioc_transfer xfer;
  memset(&xfer, 0, sizeof(xfer));

  xfer.tx_buf = reinterpret_cast<uint64>(tx_address);
  xfer.rx_buf = reinterpret_cast<uint64>(rx_address);
  xfer.len = length;
  xfer.delay_usecs = delay_usecs;
  xfer.cs_change = cs_change ? 0x01 : 0x00;

  int result = ioctl(fd, SPI_IOC_MESSAGE(1), &xfer);
  return Smi::from(result);
}

}  // namespace toit

#endif
