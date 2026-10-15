// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include "../../../src/resources/ble_hci_queue.h"
#include <algorithm>
#include <cstdlib>
#include <deque>
#include <vector>

using namespace toit::ble_hci;

static void require(bool condition) { if (!condition) abort(); }

// Operations: 0 = push, 1 = receive, 2 = allocation failure, 3 = null push.
// Push has a little-endian two-byte length followed by bytes (null push has no
// payload). Truncated input ends the sequence. The reference owns independent
// packet copies and tracks terminal failure, reserve drops and retry ordering.
extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  PacketQueue<8, 1029> queue;
  std::deque<std::vector<uint8_t>> expected;
  QueueFault fault = QueueFault::none;
  unsigned drops = 0;
  unsigned peak = 0;
  size_t position = 0;
  while (position < size) {
    unsigned operation = data[position++] % 4;
    if (operation == 0 || operation == 3) {
      if (size - position < 2) break;
      unsigned length = data[position] | (unsigned(data[position + 1]) << 8);
      position += 2;
      if (operation == 0 && size - position < length) break;
      // Allocate exactly the supplied size so ASan sees overreads, including
      // short event/ACL headers. The callback input is overwritten after push.
      std::vector<uint8_t> packet;
      if (operation == 0) {
        packet.assign(data + position, data + position + length);
        position += length;
      }
      const uint8_t* bytes = operation == 3 ? nullptr : packet.data();
      QueuePush result = queue.push(bytes, length);
      QueuePush wanted = QueuePush::failed;
      if (fault == QueueFault::none) {
        if (length > 1029) fault = QueueFault::oversized_packet;
        else {
          bool valid = false;
          if (operation == 0 && length > 0) {
            switch (packet[0]) {
              case 4:
                valid = length >= 3 && unsigned(packet[2]) == length - 3;
                break;
              case 2:
                valid = length >= 5 && (unsigned(packet[4]) * 256 + packet[3]) == length - 5;
                break;
            }
          }
          if (!valid) fault = QueueFault::invalid_packet;
          else if (packet[0] == 4 && length >= 4 && packet[1] == 0x3e &&
                   (packet[3] == 2 || packet[3] == 13) && expected.size() >= 6) {
            drops++;
            wanted = QueuePush::scan_dropped;
          } else if (expected.size() == 8) fault = QueueFault::overflow;
          else {
            wanted = QueuePush::accepted;
            expected.push_back(packet);
            peak = std::max(peak, unsigned(expected.size()));
          }
        }
      }
      require(result == wanted);
      std::fill(packet.begin(), packet.end(), 0xcc);
    } else {
      bool allocated = false;
      std::vector<uint8_t> output;
      auto result = queue.receive([&](unsigned length) -> uint8_t* {
        require(fault == QueueFault::none && !expected.empty());
        require(!allocated && length == expected.front().size());
        allocated = true;
        if (operation == 2) return nullptr;
        output.resize(length);
        return output.data();
      });
      if (fault != QueueFault::none) {
        require(result == QueueReceive::failed && !allocated);
      } else if (expected.empty()) {
        require(result == QueueReceive::empty && !allocated);
      } else if (operation == 2) {
        require(result == QueueReceive::allocation_failed && allocated);
      } else {
        require(result == QueueReceive::ready && output == expected.front());
        expected.pop_front();
      }
    }
    require(queue.fault() == fault);
    require(queue.queued() == expected.size());
    require(queue.scan_drops() == drops);
    require(queue.high_water() == peak);
  }
  return 0;
}
