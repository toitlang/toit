// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <algorithm>
#include <chrono>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#else
#include <fcntl.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/file.h>
#include <termios.h>
#include <unistd.h>
#endif

namespace pico_tools {
const size_t kMaximumLineLength = 1024;
typedef std::chrono::steady_clock Clock;
typedef Clock::time_point Deadline;

class Error : public std::runtime_error {
 public:
  explicit Error(const std::string& message) : std::runtime_error(message) {}
};

class TimeoutError : public Error {
 public:
  explicit TimeoutError(const std::string& message) : Error(message) {}
};

inline std::string system_error(const std::string& operation) {
#ifdef _WIN32
  DWORD code = GetLastError();
  std::ostringstream result;
  result << operation << " failed (Windows error " << code << ")";
  return result.str();
#else
  return operation + " failed: " + strerror(errno);
#endif
}

inline int remaining_milliseconds(Deadline deadline) {
  Clock::duration remaining = deadline - Clock::now();
  if (remaining <= Clock::duration::zero()) return 0;
  int64_t milliseconds =
      std::chrono::duration_cast<std::chrono::milliseconds>(remaining).count();
  if (milliseconds < 1) return 1;
  if (milliseconds > INT32_MAX) return INT32_MAX;
  return static_cast<int>(milliseconds);
}

class SerialPort {
 public:
  explicit SerialPort(const std::string& path, bool recovery_baud = false)
      : path_(path)
#ifdef _WIN32
      , handle_(INVALID_HANDLE_VALUE)
#else
      , descriptor_(-1)
#endif
  {
    try { open_port(recovery_baud); } catch (...) { close_port(); throw; }
  }

  ~SerialPort() { close_port(); }

  void close_port() {
#ifdef _WIN32
    if (handle_ != INVALID_HANDLE_VALUE) {
      CloseHandle(handle_);
      handle_ = INVALID_HANDLE_VALUE;
    }
#else
    if (descriptor_ >= 0) {
      close(descriptor_);
      descriptor_ = -1;
    }
#endif
  }

  void write_all(const uint8_t* data, size_t length, Deadline deadline) {
    size_t offset = 0;
    while (offset < length) {
      if (remaining_milliseconds(deadline) == 0) throw TimeoutError("serial write timed out");
#ifdef _WIN32
      DWORD written = 0;
      DWORD amount = static_cast<DWORD>(
          std::min<size_t>(length - offset, static_cast<size_t>(UINT32_MAX)));
      if (!WriteFile(handle_, data + offset, amount, &written, NULL)) {
        throw Error(system_error("serial write"));
      }
      if (written == 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
        continue;
      }
      offset += written;
#else
      struct pollfd event = {descriptor_, POLLOUT, 0};
      int result;
      do {
        result = poll(&event, 1, remaining_milliseconds(deadline));
      } while (result < 0 && errno == EINTR);
      if (result == 0) throw TimeoutError("serial write timed out");
      if (result < 0) throw Error(system_error("poll for serial write"));
      if ((event.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
        throw Error("serial device disconnected while writing");
      }
      ssize_t written = write(descriptor_, data + offset, length - offset);
      if (written < 0 && (errno == EINTR || errno == EAGAIN)) continue;
      if (written < 0) throw Error(system_error("serial write"));
      if (written == 0) continue;
      offset += static_cast<size_t>(written);
#endif
    }
  }

  void write_line(const std::string& line, Deadline deadline) {
    std::string framed = line + "\n";
    write_all(reinterpret_cast<const uint8_t*>(framed.data()), framed.size(), deadline);
  }

  std::string read_line(Deadline deadline) {
    while (true) {
      size_t newline = input_.find('\n');
      if (newline != std::string::npos) {
        if (newline > kMaximumLineLength) throw Error("device sent an overlong protocol line");
        std::string line = input_.substr(0, newline);
        input_.erase(0, newline + 1);
        if (!line.empty() && line[line.size() - 1] == '\r') line.resize(line.size() - 1);
        return line;
      }
      if (input_.size() > kMaximumLineLength) {
        throw Error("device sent an overlong protocol line");
      }
      uint8_t buffer[256];
      size_t received = read_some(buffer, sizeof(buffer), deadline);
      input_.append(reinterpret_cast<const char*>(buffer), received);
    }
  }

  void wait_for_disconnect(Deadline deadline) {
    input_.clear();
    while (remaining_milliseconds(deadline) != 0) {
      uint8_t buffer[256];
      try {
        read_some(buffer, sizeof(buffer), deadline);
      } catch (const TimeoutError&) {
        break;
      } catch (const Error&) {
        return;
      }
    }
    throw Error("USB serial device did not disconnect after reboot request");
  }

 private:
  void open_port(bool recovery_baud) {
#ifdef _WIN32
    std::string device = path_;
    if (device.size() >= 4 && device.compare(0, 3, "COM") == 0 &&
        device.compare(0, 4, "\\\\.\\") != 0) {
      device = "\\\\.\\" + device;
    }
    handle_ = CreateFileA(device.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
                          NULL, OPEN_EXISTING, 0, NULL);
    if (handle_ == INVALID_HANDLE_VALUE) throw Error(system_error("open " + path_));
    DCB configuration = {};
    configuration.DCBlength = sizeof(configuration);
    if (!GetCommState(handle_, &configuration)) throw Error(system_error("GetCommState"));
    configuration.BaudRate = recovery_baud ? CBR_1200 : CBR_115200;
    configuration.ByteSize = 8;
    configuration.Parity = NOPARITY;
    configuration.StopBits = ONESTOPBIT;
    configuration.fBinary = TRUE;
    configuration.fOutxCtsFlow = FALSE;
    configuration.fOutxDsrFlow = FALSE;
    configuration.fDtrControl = DTR_CONTROL_ENABLE;
    configuration.fDsrSensitivity = FALSE;
    configuration.fOutX = FALSE;
    configuration.fInX = FALSE;
    configuration.fRtsControl = RTS_CONTROL_DISABLE;
    if (!SetCommState(handle_, &configuration)) throw Error(system_error("SetCommState"));
    if (!EscapeCommFunction(handle_, SETDTR)) throw Error(system_error("assert DTR"));
    COMMTIMEOUTS timeouts = {};
    timeouts.ReadIntervalTimeout = MAXDWORD;
    if (!SetCommTimeouts(handle_, &timeouts)) throw Error(system_error("SetCommTimeouts"));
    PurgeComm(handle_, PURGE_RXCLEAR | PURGE_TXCLEAR);
#else
    descriptor_ = open(path_.c_str(), O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC);
    if (descriptor_ < 0) throw Error(system_error("open " + path_));
    if (flock(descriptor_, LOCK_EX | LOCK_NB) != 0) throw Error(system_error("lock " + path_));
    struct termios configuration;
    if (tcgetattr(descriptor_, &configuration) != 0) {
      int saved_errno = errno;
      close_port();
      errno = saved_errno;
      throw Error(system_error("tcgetattr " + path_));
    }
    cfmakeraw(&configuration);
    configuration.c_cflag |= CLOCAL | CREAD;
    configuration.c_cflag &= ~CSIZE;
    configuration.c_cflag |= CS8;
    configuration.c_cflag &= ~(PARENB | CSTOPB);
#ifdef CRTSCTS
    configuration.c_cflag &= ~CRTSCTS;
#endif
    speed_t speed = recovery_baud ? B1200 : B115200;
    if (cfsetispeed(&configuration, speed) != 0 ||
        cfsetospeed(&configuration, speed) != 0 ||
        tcsetattr(descriptor_, TCSANOW, &configuration) != 0) {
      int saved_errno = errno;
      close_port();
      errno = saved_errno;
      throw Error(system_error("configure " + path_));
    }
#if defined(TIOCMGET) && defined(TIOCMBIS) && defined(TIOCM_DTR)
    int modem_bits;
    if (ioctl(descriptor_, TIOCMGET, &modem_bits) == 0) {
      if ((modem_bits & TIOCM_DTR) == 0) {
        int dtr = TIOCM_DTR;
        if (ioctl(descriptor_, TIOCMBIS, &dtr) != 0 &&
            errno != ENOTTY && errno != EINVAL && errno != ENOSYS) {
          int saved_errno = errno;
          close_port();
          errno = saved_errno;
          throw Error(system_error("assert DTR on " + path_));
        }
      }
    } else if (errno != ENOTTY && errno != EINVAL && errno != ENOSYS) {
      int saved_errno = errno;
      close_port();
      errno = saved_errno;
      throw Error(system_error("read modem state on " + path_));
    }
#endif
    tcflush(descriptor_, TCIFLUSH);
#endif
  }

  size_t read_some(uint8_t* destination, size_t capacity, Deadline deadline) {
    while (remaining_milliseconds(deadline) != 0) {
#ifdef _WIN32
      DWORD received = 0;
      if (!ReadFile(handle_, destination, static_cast<DWORD>(capacity), &received, NULL)) {
        throw Error(system_error("serial read"));
      }
      if (received != 0) return received;
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
#else
      struct pollfd event = {descriptor_, POLLIN, 0};
      int result;
      do {
        result = poll(&event, 1, remaining_milliseconds(deadline));
      } while (result < 0 && errno == EINTR);
      if (result == 0) break;
      if (result < 0) throw Error(system_error("poll for serial read"));
      if ((event.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
        throw Error("serial device disconnected while reading");
      }
      ssize_t received = read(descriptor_, destination, capacity);
      if (received < 0 && (errno == EINTR || errno == EAGAIN)) continue;
      if (received < 0) throw Error(system_error("serial read"));
      if (received == 0) throw Error("serial device disconnected while reading");
      return static_cast<size_t>(received);
#endif
    }
    throw TimeoutError("serial response timed out");
  }

  std::string path_;
  std::string input_;
#ifdef _WIN32
  HANDLE handle_;
#else
  int descriptor_;
#endif
};

}  // namespace pico_tools
