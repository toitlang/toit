// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.

#include "sha256.h"

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
#include <termios.h>
#include <unistd.h>
#endif

namespace {

const size_t kChunkSize = 4096;
const size_t kMaximumLineLength = 1024;
const std::chrono::seconds kControlTimeout(5);
const std::chrono::seconds kAckTimeout(10);
const std::chrono::seconds kCommitTimeout(30);
const std::chrono::seconds kDisconnectTimeout(15);
const std::chrono::seconds kReconnectTimeout(60);

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

std::string system_error(const std::string& operation) {
#ifdef _WIN32
  DWORD code = GetLastError();
  std::ostringstream result;
  result << operation << " failed (Windows error " << code << ")";
  return result.str();
#else
  return operation + " failed: " + strerror(errno);
#endif
}

int remaining_milliseconds(Deadline deadline) {
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
  explicit SerialPort(const std::string& path)
      : path_(path)
#ifdef _WIN32
      , handle_(INVALID_HANDLE_VALUE)
#else
      , descriptor_(-1)
#endif
  {
    open_port();
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
  void open_port() {
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
    configuration.BaudRate = CBR_115200;
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
    if (cfsetispeed(&configuration, B115200) != 0 ||
        cfsetospeed(&configuration, B115200) != 0 ||
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

struct DeviceInfo {
  uint64_t partition;
  bool trial;
  uint64_t slot_size;
};

std::vector<std::string> split_words(const std::string& line) {
  std::istringstream input(line);
  std::vector<std::string> result;
  std::string word;
  while (input >> word) result.push_back(word);
  return result;
}

bool parse_unsigned(const std::string& text, uint64_t* value) {
  if (text.empty()) return false;
  uint64_t result = 0;
  for (size_t i = 0; i < text.size(); i++) {
    if (text[i] < '0' || text[i] > '9') return false;
    uint64_t digit = static_cast<uint64_t>(text[i] - '0');
    if (result > (UINT64_MAX - digit) / 10) return false;
    result = result * 10 + digit;
  }
  *value = result;
  return true;
}

bool starts_with(const std::string& value, const char* prefix) {
  size_t length = strlen(prefix);
  return value.size() >= length && value.compare(0, length, prefix) == 0;
}

void reject_device_error(const std::string& line) {
  if (line == "TOIT-OTA ERROR" || starts_with(line, "TOIT-OTA ERROR ")) {
    throw Error("device rejected OTA request: " + line);
  }
}

DeviceInfo wait_for_info(SerialPort* port, Deadline deadline) {
  while (true) {
    std::string line = port->read_line(deadline);
    reject_device_error(line);
    if (!starts_with(line, "TOIT-OTA INFO ")) {
      if (!line.empty()) std::cerr << "device: " << line << "\n";
      continue;
    }
    std::vector<std::string> words = split_words(line);
    uint64_t version;
    uint64_t partition;
    uint64_t trial;
    uint64_t slot_size;
    if (words.size() != 6 || !parse_unsigned(words[2], &version) || version != 1 ||
        !parse_unsigned(words[3], &partition) || !parse_unsigned(words[4], &trial) ||
        trial > 1 || !parse_unsigned(words[5], &slot_size)) {
      throw Error("malformed INFO response: " + line);
    }
    DeviceInfo result = {partition, trial != 0, slot_size};
    return result;
  }
}

void wait_for_ready(SerialPort* port, Deadline deadline) {
  while (true) {
    std::string line = port->read_line(deadline);
    reject_device_error(line);
    if (!starts_with(line, "TOIT-OTA READY ")) {
      if (!line.empty()) std::cerr << "device: " << line << "\n";
      continue;
    }
    std::vector<std::string> words = split_words(line);
    uint64_t chunk_size;
    if (words.size() != 3 || !parse_unsigned(words[2], &chunk_size) ||
        chunk_size != kChunkSize) {
      throw Error("unsupported READY response: " + line);
    }
    return;
  }
}

void wait_for_ack(SerialPort* port, uint64_t expected, Deadline deadline) {
  while (true) {
    std::string line = port->read_line(deadline);
    reject_device_error(line);
    if (!starts_with(line, "TOIT-OTA ACK ")) {
      if (!line.empty()) std::cerr << "device: " << line << "\n";
      continue;
    }
    std::vector<std::string> words = split_words(line);
    uint64_t offset;
    if (words.size() != 3 || !parse_unsigned(words[2], &offset)) {
      throw Error("malformed ACK response: " + line);
    }
    if (offset != expected) {
      std::ostringstream message;
      message << "bad ACK offset: expected " << expected << ", received " << offset;
      throw Error(message.str());
    }
    return;
  }
}

void wait_for_exact(SerialPort* port, const char* expected, Deadline deadline) {
  while (true) {
    std::string line = port->read_line(deadline);
    reject_device_error(line);
    if (line == expected) return;
    if (!line.empty()) std::cerr << "device: " << line << "\n";
  }
}

std::string digest_file(std::ifstream* image, uint64_t* size) {
  image->seekg(0, std::ios::end);
  std::streamoff end = image->tellg();
  if (end < 0) throw Error("cannot determine image size");
  *size = static_cast<uint64_t>(end);
  if (*size == 0) throw Error("image is empty");
  image->seekg(0, std::ios::beg);

  Sha256 sha;
  uint8_t buffer[64 * 1024];
  while (*image) {
    image->read(reinterpret_cast<char*>(buffer), sizeof(buffer));
    std::streamsize count = image->gcount();
    if (count > 0) sha.update(buffer, static_cast<size_t>(count));
  }
  if (!image->eof()) throw Error("failed while reading image");
  image->clear();
  image->seekg(0, std::ios::beg);

  uint8_t digest[32];
  sha.finish(digest);
  std::ostringstream result;
  result << std::hex << std::setfill('0');
  for (size_t i = 0; i < sizeof(digest); i++) {
    result << std::setw(2) << static_cast<unsigned>(digest[i]);
  }
  return result.str();
}

void upload_image(SerialPort* port, std::ifstream* image, uint64_t image_size,
                  const std::string& digest) {
  std::ostringstream write_command;
  write_command << "TOIT-OTA WRITE " << image_size << " " << digest;
  port->write_line(write_command.str(), Clock::now() + kControlTimeout);
  wait_for_ready(port, Clock::now() + kControlTimeout);

  uint8_t buffer[kChunkSize];
  uint64_t offset = 0;
  while (offset < image_size) {
    size_t amount = static_cast<size_t>(
        std::min<uint64_t>(kChunkSize, image_size - offset));
    image->read(reinterpret_cast<char*>(buffer), amount);
    if (image->gcount() != static_cast<std::streamsize>(amount)) {
      throw Error("image changed or became unreadable during upload");
    }
    port->write_all(buffer, amount, Clock::now() + kControlTimeout);
    offset += amount;
    wait_for_ack(port, offset, Clock::now() + kAckTimeout);
    std::cerr << "Uploaded " << offset << "/" << image_size << " bytes\r" << std::flush;
  }
  std::cerr << "\n";
  wait_for_exact(port, "TOIT-OTA COMMITTED", Clock::now() + kCommitTimeout);
}

DeviceInfo request_info(SerialPort* port) {
  port->write_line("TOIT-OTA INFO", Clock::now() + kControlTimeout);
  return wait_for_info(port, Clock::now() + kControlTimeout);
}

void confirm_reboot(const std::string& path, uint64_t original_partition) {
  Deadline reconnect_deadline = Clock::now() + kReconnectTimeout;
  std::string last_error;
  while (remaining_milliseconds(reconnect_deadline) != 0) {
    try {
      std::unique_ptr<SerialPort> port(new SerialPort(path));
      DeviceInfo info = request_info(port.get());
      if (!info.trial) {
        if (info.partition == original_partition) {
          throw Error("device rolled back to the original partition");
        }
        std::cout << "OTA boot validated on partition " << info.partition << "\n";
        return;
      }
      last_error = "new partition is still in trial mode";
    } catch (const Error& error) {
      last_error = error.what();
      if (last_error == "device rolled back to the original partition") throw;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
  }
  throw Error("device did not return with a validated OTA image: " + last_error);
}

void usage(const char* executable) {
  std::cerr << "Usage: " << executable << " --port PATH [--no-reboot] IMAGE.bin\n";
}

int run(int argc, char** argv) {
  std::string port_path;
  std::string image_path;
  bool reboot = true;
  for (int i = 1; i < argc; i++) {
    std::string argument = argv[i];
    if (argument == "--port") {
      if (++i == argc || port_path.size() != 0) {
        usage(argv[0]);
        return 2;
      }
      port_path = argv[i];
    } else if (argument == "--no-reboot") {
      reboot = false;
    } else if (argument == "--help" || argument == "-h") {
      usage(argv[0]);
      return 0;
    } else if (!argument.empty() && argument[0] == '-') {
      throw Error("unknown option: " + argument);
    } else if (image_path.empty()) {
      image_path = argument;
    } else {
      throw Error("multiple image paths provided");
    }
  }
  if (port_path.empty() || image_path.empty()) {
    usage(argv[0]);
    return 2;
  }

  std::ifstream image(image_path.c_str(), std::ios::binary);
  if (!image) throw Error("cannot open image: " + image_path);
  uint64_t image_size;
  std::string digest = digest_file(&image, &image_size);
  std::cout << "Image: " << image_size << " bytes, SHA-256 " << digest << "\n";

  SerialPort port(port_path);
  DeviceInfo before = request_info(&port);
  if (image_size > before.slot_size) {
    std::ostringstream message;
    message << "image is " << image_size << " bytes, but OTA slot is only "
            << before.slot_size << " bytes";
    throw Error(message.str());
  }
  std::cout << "Device: partition " << before.partition
            << (before.trial ? " (trial)" : "")
            << ", slot size " << before.slot_size << " bytes\n";

  upload_image(&port, &image, image_size, digest);
  std::cout << "OTA image committed\n";
  if (!reboot) return 0;

  port.write_line("TOIT-OTA REBOOT", Clock::now() + kControlTimeout);
  wait_for_exact(&port, "TOIT-OTA REBOOTING", Clock::now() + kControlTimeout);
  port.wait_for_disconnect(Clock::now() + kDisconnectTimeout);
  port.close_port();
  confirm_reboot(port_path, before.partition);
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  try {
    return run(argc, argv);
  } catch (const Error& error) {
    std::cerr << "ota-upload: " << error.what() << "\n";
    return 1;
  } catch (const std::exception& error) {
    std::cerr << "ota-upload: unexpected error: " << error.what() << "\n";
    return 1;
  }
}
