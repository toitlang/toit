// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.

#include "sha256.h"

#include "../../pico/serial.h"

namespace {
using namespace pico_tools;

const size_t kChunkSize = 4096;
const std::chrono::seconds kControlTimeout(5);
const std::chrono::seconds kAckTimeout(10);
const std::chrono::seconds kCommitTimeout(30);
const std::chrono::seconds kDisconnectTimeout(15);
const std::chrono::seconds kReconnectTimeout(60);

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
