// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "../../pico/serial.h"

namespace {
using namespace pico_tools;
class ProtocolError : public Error {
 public:
  explicit ProtocolError(const std::string& message) : Error(message) {}
};
const uint32_t kCapacity = 0xf0000;
const uint32_t kAddress = 0x10020000;
const size_t kSector = 4096;

class Trace {
 public:
  explicit Trace(bool enabled) : enabled_(enabled), start_(Clock::now()) {}

  void log(const std::string& message) const {
    if (!enabled_) return;
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start_);
    std::cerr << "rp2040-ota-upload: +" << elapsed.count() << "ms " << message << std::endl;
  }

 private:
  bool enabled_;
  Deadline start_;
};

uint32_t crc32(const uint8_t* bytes, size_t length) {
  uint32_t crc = UINT32_MAX;
  while (length--) {
    crc ^= *bytes++;
    for (int bit = 0; bit < 8; bit++) crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1)));
  }
  return ~crc;
}
uint32_t word(const std::vector<uint8_t>& bytes, size_t at) {
  return uint32_t(bytes[at]) | (uint32_t(bytes[at + 1]) << 8) |
      (uint32_t(bytes[at + 2]) << 16) | (uint32_t(bytes[at + 3]) << 24);
}
uint32_t number(const std::string& text, unsigned base = 10) {
  if (text.empty()) throw ProtocolError("missing number");
  uint64_t result = 0;
  for (char ch : text) {
    unsigned digit = ch >= '0' && ch <= '9' ? ch - '0' :
        ch >= 'a' && ch <= 'f' ? ch - 'a' + 10 : ch >= 'A' && ch <= 'F' ? ch - 'A' + 10 : 99;
    if (digit >= base) throw ProtocolError("invalid number: " + text);
    result = result * base + digit;
    if (result > UINT32_MAX) throw ProtocolError("number exceeds uint32: " + text);
  }
  return static_cast<uint32_t>(result);
}
std::string hex(uint32_t value) {
  std::ostringstream stream;
  stream << std::hex << std::setfill('0') << std::setw(8) << value;
  return stream.str();
}
std::vector<std::string> words(const std::string& line) {
  std::istringstream stream(line);
  std::vector<std::string> result;
  std::string word;
  while (stream >> word) result.push_back(word);
  return result;
}
bool starts(const std::string& line, const std::string& prefix) { return line.compare(0, prefix.size(), prefix) == 0; }
struct Installed {
  std::string id;
  uint32_t version, size, crc;
};
bool installed(const std::string& line, Installed* info) {
  if (!starts(line, "RP2040-UPDATER ")) return false;
  auto fields = words(line);
  if (fields.size() != 6 || fields[1] != "1" || !starts(fields[2], "id=") ||
      !starts(fields[3], "app=") || !starts(fields[4], "size=") || !starts(fields[5], "crc=")) {
    throw ProtocolError("malformed installed-image response");
  }
  info->id = fields[2].substr(3);
  info->version = number(fields[3].substr(4));
  info->size = number(fields[4].substr(5));
  info->crc = number(fields[5].substr(4), 16);
  return true;
}
void expect(SerialPort& port, const std::string& expected) {
  auto deadline = Clock::now() + std::chrono::seconds(10);
  while (true) {
    std::string line;
    try {
      line = port.read_line(deadline);
    } catch (const TimeoutError&) {
      throw TimeoutError("timed out waiting for '" + expected + "'");
    }
    if (line == expected) return;
    if (starts(line, "ERR ") || starts(line, "OK ") || starts(line, "READY ")) {
      throw Error("expected '" + expected + "', received '" + line + "'");
    }
  }
}
std::unique_ptr<SerialPort> connect(const std::string& path, std::string* id, uint32_t* version,
                                  const Trace& trace) {
  auto deadline = Clock::now() + std::chrono::seconds(30);
  while (Clock::now() < deadline) {
    try {
      // 1200 baud is a USB control request, not input consumed by the app.
      // The recovery loader ignores the baud rate. Wait for its heartbeat
      // before sending any bytes, so application stdin stays untouched.
      trace.log("opening serial port and requesting recovery at 1200 baud");
      std::unique_ptr<SerialPort> port(new SerialPort(path, true));
      trace.log("serial configured; waiting for recovery heartbeat");
      auto attempt = Clock::now() + std::chrono::seconds(2);
      bool ready = false;
      bool have_info = false;
      Installed info;
      std::string ready_id;
      try {
        while (!ready || !have_info) {
          std::string line = port->read_line(attempt);
          // A previous connection can leave READY queued in the device. Only
          // accept it after observing the heartbeat and issuing our hello.
          if (have_info && starts(line, "READY ")) {
            auto fields = words(line);
            if (fields.size() != 5 || fields[1] != "RP2040" || fields[2] != "1" ||
                number(fields[3]) != kCapacity) throw ProtocolError("unsupported recovery protocol");
            ready_id = fields[4];
            if (ready_id.size() != 16 || ready_id.find_first_not_of("0123456789abcdefABCDEF") != std::string::npos) {
              throw ProtocolError("invalid board identity");
            }
            ready = true;
            trace.log("received recovery READY");
          }
          if (installed(line, &info)) {
            if (!have_info) {
              trace.log("received recovery heartbeat; sending hello");
              port->write_line("hello", Clock::now() + std::chrono::seconds(1));
            }
            have_info = true;
          }
        }
      } catch (const TimeoutError&) {
        trace.log(std::string("recovery handshake timed out: heartbeat=") +
                  (have_info ? "yes" : "no") + " ready=" + (ready ? "yes" : "no"));
        continue;
      }
      if (ready_id != info.id || (!id->empty() && *id != ready_id)) throw ProtocolError("board identity changed");
      *id = ready_id;
      *version = info.version;
      trace.log("recovery identity verified; installed version " + std::to_string(info.version));
      return port;
    } catch (const ProtocolError&) {
      throw;
    } catch (const Error& error) {
      // The serial path may disappear temporarily while the board reboots.
      trace.log(error.what());
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  throw Error("recovery unavailable on the selected serial port");
}
void verify(const std::string& path, const std::string& id, uint32_t version, uint32_t size, uint32_t crc,
            const Trace& trace) {
  auto deadline = Clock::now() + std::chrono::seconds(60);
  while (Clock::now() < deadline) {
    try {
      SerialPort port(path);
      while (Clock::now() < deadline) {
        Installed info;
        if (!installed(port.read_line(deadline), &info)) continue;
        if (info.id != id) throw ProtocolError("board identity changed");
        if (info.version == version && info.size == size && info.crc == crc) {
          trace.log("installed version, size and CRC verified after reboot");
          return;
        }
        throw ProtocolError("installed image does not match the committed update");
      }
    } catch (const ProtocolError&) {
      throw;
    } catch (const Error& error) {
      // Reopen the same path after USB re-enumeration.
      trace.log(error.what());
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  throw Error("committed update was not verified after reboot");
}
int run(int argc, char** argv) {
  std::string path, filename, id;
  uint32_t version = 0;
  bool explicit_version = false;
  bool verbose = false;
  for (int i = 1; i < argc; i++) {
    std::string arg(argv[i]);
    if (arg == "--help" || arg == "-h") {
      std::cout << "Usage: rp2040-ota-upload --port PATH [--id BOARD_ID] [--version NUMBER] [--verbose] IMAGE.bin\n";
      return 0;
    }
    if (arg == "--verbose") {
      verbose = true;
      continue;
    }
    if (arg == "--port" || arg == "--id" || arg == "--version") {
      if (++i == argc) throw Error("missing value for " + arg);
      if (arg == "--port") path = argv[i];
      else if (arg == "--id") id = argv[i];
      else { version = number(argv[i]); explicit_version = true; }
    } else if (!arg.empty() && arg[0] != '-' && filename.empty()) filename = arg;
    else throw Error("unexpected argument: " + arg);
  }
  if (path.empty() || filename.empty()) throw Error("--port and IMAGE.bin are required");
  std::ifstream file(filename.c_str(), std::ios::binary | std::ios::ate);
  if (!file) throw Error("cannot open image");
  auto length = file.tellg();
  if (length < 264 || length > kCapacity) throw Error("invalid image size");
  std::vector<uint8_t> bytes(static_cast<size_t>(length));
  file.seekg(0);
  if (!file.read(reinterpret_cast<char*>(bytes.data()), bytes.size())) throw Error("cannot read image");
  uint32_t stack = word(bytes, 256), entry = word(bytes, 260);
  if (stack <= 0x20000000 || stack > 0x20042000 || (stack & 7) || !(entry & 1) ||
      entry < kAddress + 264 || entry >= kAddress + bytes.size()) throw Error("invalid application vectors");
  uint32_t previous;
  Trace trace(verbose);
  auto port = connect(path, &id, &previous, trace);
  if (!explicit_version) {
    if (previous == UINT32_MAX) throw Error("version exhausted; choose --version explicitly");
    version = previous + 1;
  }
  uint32_t crc = crc32(bytes.data(), bytes.size());
  trace.log("sending begin for version " + std::to_string(version));
  port->write_line("begin " + std::to_string(bytes.size()) + " " + hex(crc) + " " + std::to_string(version),
      Clock::now() + std::chrono::seconds(5));
  expect(*port, "OK begin");
  trace.log("begin acknowledged");
  for (size_t offset = 0; offset < bytes.size(); offset += kSector) {
    size_t count = std::min(kSector, bytes.size() - offset);
    trace.log("requesting block at offset " + std::to_string(offset));
    port->write_line("block " + std::to_string(offset) + " " + std::to_string(count) + " " +
        hex(crc32(bytes.data() + offset, count)), Clock::now() + std::chrono::seconds(5));
    expect(*port, "READY block");
    trace.log("block ready; writing " + std::to_string(count) + " bytes");
    port->write_all(bytes.data() + offset, count, Clock::now() + std::chrono::seconds(5));
    trace.log("block written; waiting for acknowledgement");
    expect(*port, "OK block " + std::to_string(offset + count));
  }
  trace.log("all blocks acknowledged; sending commit");
  port->write_line("commit", Clock::now() + std::chrono::seconds(5));
  expect(*port, "OK commit");
  trace.log("commit acknowledged; waiting for verified reboot");
  port.reset();
  verify(path, id, version, bytes.size(), crc, trace);
  std::cout << "RP2040 " << id << ": installed version " << version << ", " << bytes.size()
            << " bytes, CRC32 " << hex(crc) << "\n";
  return 0;
}
}  // namespace
int main(int argc, char** argv) {
  try { return run(argc, argv); }
  catch (const std::exception& error) { std::cerr << "rp2040-ota-upload: " << error.what() << "\n"; return 1; }
}
