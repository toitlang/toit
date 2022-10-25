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

#ifdef TOIT_POSIX

#include <fcntl.h>
#include <errno.h>
#include <termios.h>
#include <unistd.h>
#if defined(TOIT_LINUX)
 #include <linux/serial.h>
 #include <sys/epoll.h>
 #include "../event_sources/epoll_linux.h"
#elif defined(TOIT_BSD)
 #include "../event_sources/kqueue_bsd.h"
 #include <sys/event.h>
 #include <IOKit/serial/ioss.h>
#endif

#include <sys/file.h>
#include <sys/ioctl.h>

#include "../objects.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"

namespace toit {

static int baud_rate_to_int(speed_t speed) {
  switch (speed) {
    // B0 instructs the modem to hang up. We should never see this.
    case B0: return 0;
    case B50: return 50;
    case B75: return 75;
    case B110: return 110;
    case B134: return 134;
    case B150: return 150;
    case B200: return 200;
    case B300: return 300;
    case B600: return 600;
    case B1200: return 1200;
    case B1800: return 1800;
    case B2400: return 2400;
    case B4800: return 4800;
    case B9600: return 9600;
    case B19200: return 19200;
    case B38400: return 38400;
    case B57600: return 57600;
    case B115200: return 115200;
    case B230400: return 230400;
#if defined(TOIT_LINUX)
    case B460800: return 460800;
    case B576000: return 576000;
    case B921600: return 921600;
    case B1152000: return 1152000;
    case B1500000: return 1500000;
    case B2000000: return 2000000;
    case B2500000: return 2500000;
    case B3000000: return 3000000;
    case B3500000: return 3500000;
    case B4000000: return 4000000;
    default: return -1;
#elif defined(TOIT_DARWIN)
    default:
      return static_cast<int>(speed);
#endif
  }
}

static int int_to_baud_rate(int baud_rate, speed_t* speed, bool *arbitrary_baud_rate) {
  // TODO: On linux using gcc, it should be possible to just set the bit rate as an integer.
  *arbitrary_baud_rate = false;
  switch (baud_rate) {
    case 0: *speed = B0; return 0;
    case 50: *speed = B50; return 0;
    case 75: *speed = B75; return 0;
    case 110: *speed = B110; return 0;
    case 134: *speed = B134; return 0;
    case 150: *speed = B150; return 0;
    case 200: *speed = B200; return 0;
    case 300: *speed = B300; return 0;
    case 600: *speed = B600; return 0;
    case 1200: *speed = B1200; return 0;
    case 1800: *speed = B1800; return 0;
    case 2400: *speed = B2400; return 0;
    case 4800: *speed = B4800; return 0;
    case 9600: *speed = B9600; return 0;
    case 19200: *speed = B19200; return 0;
    case 38400: *speed = B38400; return 0;
    case 57600: *speed = B57600; return 0;
    case 115200: *speed = B115200; return 0;
    case 230400: *speed = B230400; return 0;
#if defined(TOIT_LINUX)
    case 460800: *speed = B460800; return 0;
    case 576000: *speed = B576000; return 0;
    case 921600: *speed = B921600; return 0;
    case 1152000: *speed = B1152000; return 0;
    case 1500000: *speed = B1500000; return 0;
    case 2000000: *speed = B2000000; return 0;
    case 2500000: *speed = B2500000; return 0;
    case 3000000: *speed = B3000000; return 0;
    case 3500000: *speed = B3500000; return 0;
    case 4000000: *speed = B4000000; return 0;
    default: return -1;
#elif defined(TOIT_DARWIN)
    default:
      *speed = baud_rate;
      *arbitrary_baud_rate = true;
      return 0;
#endif
  }
}

const int kReadState = 1 << 0;
const int kErrorState = 1 << 1;
const int kWriteState = 1 << 2;

class UARTResourceGroup : public ResourceGroup {
 public:
  TAG(UARTResourceGroup);
  UARTResourceGroup(Process* process, EventSource* event_source)
    : ResourceGroup(process, event_source){ }

  int create_uart(const char* path, speed_t speed, int data_bits, int stop_bits, int parity) {
    // We always set the close-on-exec flag otherwise we leak descriptors when we fork.
    // File descriptors that are intended for subprocesses have the flags cleared.
    int fd = open(path, O_CLOEXEC | O_RDWR | O_NONBLOCK | O_NOCTTY);
    if (fd < 0) return -1;
    if (!isatty(fd)) {
      // Doesn't seem to be a serial port.
      close(fd);
      return -2;
    }

    // Lock the device.
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) goto fail;

    // Helpful: https://blog.mbedded.ninja/programming/operating-systems/linux/linux-serial-ports-using-c-cpp/
    struct termios tty;
    if (tcgetattr(fd, &tty) != 0) goto fail;
    // Disable flow control.
    tty.c_cflag &= ~CRTSCTS;

    // Disable modem-specific signal lines (such as carrier detect).
    // Make it possible to read data.
    tty.c_cflag |= CREAD | CLOCAL;
    tty.c_lflag &= ~ICANON;
    // Disable all echo, erasure, new-line echo. Might not be necessary.
    tty.c_lflag &= ~ECHO;
    tty.c_lflag &= ~ECHOE;
    tty.c_lflag &= ~ECHONL;
    // Don't interpret INTR, QUIT and SUSP characters.
    tty.c_lflag &= ~ISIG;

    // Disable special handling of bytes on receive. Just give the raw data.
    tty.c_iflag &= ~(IGNBRK|BRKINT|PARMRK|ISTRIP|INLCR|IGNCR|ICRNL);

    // Disable software flow control.
    tty.c_iflag &= ~(IXON|IXOFF|IXANY);

    // Disable any special handling for the output.
    tty.c_oflag &= ~OPOST;
    tty.c_oflag &= ~ONLCR;

    // Don't block when reading.
    tty.c_cc[VTIME] = 0;
    tty.c_cc[VMIN] = 0;

    if (cfsetospeed(&tty, speed) != 0) goto fail;
    if (cfsetispeed(&tty, speed) != 0) goto fail;

    if (stop_bits == 1) {
      // 1 stop bit.
      tty.c_cflag &= ~CSTOPB;
    } else {
      // Linux doesn't distinguish between 1.5 and 2 stop bits.
      tty.c_cflag |= CSTOPB;
    }

    if (parity == 1) {
      // Disabled.
      tty.c_cflag &= ~PARENB;
    } else if (parity == 2) {
      // Even parity.
      tty.c_cflag |= PARENB;
      tty.c_cflag &= ~PARODD;
    } else {
      // Odd parity.
      tty.c_cflag |= PARENB;
      tty.c_cflag |= PARODD;
    }

    tcflag_t csize;
    if (data_bits == 5) {
      csize = CS5;
    } else if (data_bits == 6) {
      csize = CS6;
    } else if (data_bits == 7) {
      csize = CS7;
    } else {
      csize = CS8;
    }
    tty.c_cflag &= ~CSIZE;
    tty.c_cflag |= csize;

    if (tcsetattr(fd, TCSANOW, &tty) != 0) goto fail;

    if (tcflush(fd, TCIOFLUSH) != 0) goto fail;

    return fd;

    fail:
      int fail_errno = errno;
      close(fd);
      errno = fail_errno;
      return -1;
  }

  void close_uart(int id) {
    flock(id, LOCK_UN);
    // Do not close the file descriptor here.
    // Since the id is used in the epoll, the epoll-event source will do it for us.
    unregister_id(id);
  }

 private:
  uint32_t on_event(Resource* resource, word data, uint32_t state) {
#if defined(TOIT_LINUX)
    if (data & EPOLLIN) state |= kReadState;
    if (data & EPOLLERR) state |= kErrorState;
    if (data & EPOLLOUT) state |= kWriteState;
#elif defined(TOIT_BSD)
    auto event = reinterpret_cast<struct kevent*>(data);
    if (event->filter == EVFILT_READ) state |= kReadState;
    if (event->filter == EVFILT_WRITE) state |= kWriteState;
    if (event->filter == EVFILT_EXCEPT) state |= kErrorState;
#endif
    return state;
  }
};

// Defined in primitive_file_posix.cc.
extern Object* return_open_error(Process* process, int err);

MODULE_IMPLEMENTATION(uart, MODULE_UART);

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

#if defined(TOIT_LINUX)
  UARTResourceGroup* resource_group = _new UARTResourceGroup(process, EpollEventSource::instance());
#elif defined(TOIT_BSD)
  UARTResourceGroup* resource_group = _new UARTResourceGroup(process, KQueueEventSource::instance());
#endif
  if (!resource_group) MALLOC_FAILED;

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(create) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(create_path) {
  ARGS(UARTResourceGroup, resource_group, cstring, path, int, baud_rate, int, data_bits, int, stop_bits, int, parity);

  speed_t speed;
  bool arbitrary_baud_rate;
  if (int_to_baud_rate(baud_rate, &speed, &arbitrary_baud_rate) < 0) INVALID_ARGUMENT;

  if (data_bits < 5 || data_bits > 8) INVALID_ARGUMENT;
  if (stop_bits < 1 || stop_bits > 3) INVALID_ARGUMENT;
  if (parity < 1 || parity > 3) INVALID_ARGUMENT;

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) ALLOCATION_FAILED;

  int id = resource_group->create_uart(path, speed, data_bits, stop_bits, parity);
  if (id == -1) return Primitive::os_error(errno, process);
  if (id == -2) INVALID_ARGUMENT;

  IntResource* resource = resource_group->register_id(id);
  // We are running on Linux. As such we should never have malloc that fails.
  // Normally, we would need to clean up, if the allocation fails, but if that
  // happens on Linux, we are in big trouble anyway.
  if (!resource) MALLOC_FAILED;
  resource_proxy->set_external_address(resource);
  return resource_proxy;
}

PRIMITIVE(close) {
  ARGS(UARTResourceGroup, resource_group, IntResource, uart_resource);
  resource_group->close_uart(uart_resource->id());
  uart_resource_proxy->clear_external_address();
  return process->program()->null_object();
}

PRIMITIVE(get_baud_rate) {
  ARGS(IntResource, resource);
  int fd = resource->id();

  struct termios tty;
  if (tcgetattr(fd, &tty) < 0) {
    return Primitive::os_error(errno, process);
  }
  // We assume that the input and output speed are the same and only query the output speed.
  speed_t speed = cfgetospeed(&tty);
  int int_speed = baud_rate_to_int(speed);
  if (int_speed == -1) OTHER_ERROR;
  return Primitive::integer(int_speed, process);
}

PRIMITIVE(set_baud_rate) {
  ARGS(IntResource, resource, int, baud_rate);
  int fd = resource->id();

  speed_t speed;
  bool arbitrary_rate;
  int result = int_to_baud_rate(baud_rate, &speed, &arbitrary_rate);
  if (result != 0) INVALID_ARGUMENT;
  if (!arbitrary_rate) {
    // Use standard Posix/Linux line speed setup
    struct termios tty;
    if (tcgetattr(fd, &tty) != 0) return Primitive::os_error(errno, process);
    if (cfsetospeed(&tty, speed) != 0) return Primitive::os_error(errno, process);
    if (cfsetispeed(&tty, speed) != 0) return Primitive::os_error(errno, process);
    // TCSADRAIN: let the change happen once all output written to the fd has been transmitted.
    if (tcsetattr(fd, TCSADRAIN, &tty) != 0) return Primitive::os_error(errno, process);
  } else {
#ifdef TOIT_DARWIN
    if (ioctl(fd, IOSSIOSPEED, &speed) != 0) return Primitive::os_error(errno, process);
#else
    INVALID_ARGUMENT;
#endif

  }
  return process->program()->null_object();
}

// Writes the data to the UART.
// If wait is true, waits, unless the baud-rate is too low. If the function did
// not wait, returns the negative value of the written bytes.
PRIMITIVE(write) {
  ARGS(IntResource, resource, Blob, data, int, from, int, to, int, break_length, bool, wait);
  int fd = resource->id();

  const uint8* tx = data.address();
  if (from < 0 || from > to || to > data.length()) OUT_OF_RANGE;
  tx += from;

  if (break_length < 0) OUT_OF_RANGE;

  ssize_t written = write(fd, tx, to - from);
  if (written < 0) {
    if (errno != EAGAIN) return Primitive::os_error(errno, process);
    written = 0;
  }

  int baud_rate = 0;
  if (break_length > 0 || wait) {
    // If we have a break, or need to wait we need the current baud_rate.
    struct termios tty;
    if (tcgetattr(fd, &tty) != 0) return Primitive::os_error(errno, process);
    // We assume that the input and output speed are the same and only query the output speed.
    speed_t speed = cfgetospeed(&tty);
    baud_rate = baud_rate_to_int(speed);
  }

  if (break_length > 0) {
    // Toit (because of ESP32) defines the break-length as equal to the time it takes to write 1 bit.
    // Linux uses 'ms' instead. We need to get the baud-rate so we can convert from bit-duration to ms.
    int ms = break_length * 1000 / baud_rate;
    if (ms == 0) ms = 1;
    if (tcsendbreak(fd, ms) != 0) return Primitive::os_error(errno, process);
  }

  if (wait) {
    if (baud_rate < 100000) {
      return Smi::from(-written);
    }
    // TODO(florian): do we ever want to do a blocking wait on Linux?
    // Wait until the data has been drained.
    if (tcdrain(fd) != 0) return Primitive::os_error(errno, process);
  }

  return Smi::from(written);
}

PRIMITIVE(wait_tx) {
  ARGS(IntResource, resource);
  int fd = resource->id();

  // If we have a break, or need to wait we need the current baud_rate.
  struct termios tty;
  if (tcgetattr(fd, &tty) < 0) return Primitive::os_error(errno, process);
  // We assume that the input and output speed are the same and only query the output speed.
  speed_t speed = cfgetospeed(&tty);
  int baud_rate = baud_rate_to_int(speed);
  if (baud_rate > 100000) {
    // TODO(florian): do we ever want to do a blocking wait on Linux?

    // Just wait for the data to be flushed.
    if (!tcdrain(fd)) return Primitive::os_error(errno, process);
    return BOOL(true);
  }

  int queued;
  if (ioctl(fd, TIOCOUTQ, &queued) != 0) return Primitive::os_error(errno, process);
  return BOOL(queued == 0);
}

PRIMITIVE(read) {
  ARGS(IntResource, resource);
  int fd = resource->id();

  size_t available = 0;
  if (ioctl(fd, FIONREAD, &available) != 0) return Primitive::os_error(errno, process);
  if (available == 0) return process->program()->null_object();

  ByteArray* data = process->allocate_byte_array(available, /*force_external*/ true);
  if (data == null) ALLOCATION_FAILED;

  ByteArray::Bytes rx(data);
  int received = read(fd, rx.address(), rx.length());
  if (received < 0) {
    int read_errno = errno;
    if (read_errno == EAGAIN || read_errno == EWOULDBLOCK) {
      received = 0;
    } else {
      return Primitive::os_error(read_errno, process);
    }
  }

  if (received < static_cast<int>(available)) {
    return process->allocate_string_or_error("broken UART read");
  }

  return data;
}

PRIMITIVE(set_control_flags) {
  ARGS(IntResource, resource, int, flags);
  int fd = resource->id();

  if (ioctl(fd, TIOCMSET, &flags) != 0) return Primitive::os_error(errno, process);

  return process->program()->null_object();
}

PRIMITIVE(get_control_flags) {
  ARGS(IntResource, resource);
  int fd = resource->id();

  int flags;
  if (ioctl(fd, TIOCMGET, &flags) != 0) return Primitive::os_error(errno, process);

  return Smi::from(flags);
}

} // namespace toit

#endif // TOIT_LINUX
