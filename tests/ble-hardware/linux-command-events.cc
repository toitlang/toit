// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Optional Linux diagnostic. No controller commands or ACL capture. Ordinary
// command results need no capabilities; optional LE feature events require
// CAP_NET_RAW. The enclosing runner owns the adapter lease and peer selection.
#include <bluetooth/bluetooth.h>
#include <bluetooth/hci.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <poll.h>
#include <unistd.h>

#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>

struct Record {
  unsigned event, opcode, status, handle, detail;
};

static unsigned le16(const unsigned char* p) {
  return p[0] | (unsigned(p[1]) << 8);
}

static std::optional<Record> decode(const unsigned char* p, size_t size) {
  if (size < 3 || p[0] != HCI_EVENT_PKT || size != size_t(p[2]) + 3) return {};
  if (p[1] == EVT_CMD_STATUS && size == 7) {
    unsigned opcode = le16(p + 5);
    if (opcode != 0x2016 && opcode != 0x2019 && opcode != 0x0406) return {};
    return Record{p[1], opcode, p[3], 0xffff, 0};
  }
  if (p[1] == EVT_CMD_COMPLETE && size == 9) {
    unsigned opcode = le16(p + 4);
    if (opcode != 0x201a && opcode != 0x201b) return {};
    return Record{p[1], opcode, p[6], le16(p + 7), 0};
  }
  if ((p[1] == EVT_DISCONN_COMPLETE || p[1] == EVT_ENCRYPT_CHANGE) && size == 7) {
    return Record{p[1], 0, p[3], le16(p + 4), p[6]};
  }
  if (p[1] == EVT_LE_META_EVENT && size == 15 && p[3] == 4) {
    // LE Read Remote Features Complete: omit the feature payload itself.
    return Record{p[1], 0x2016, p[4], le16(p + 5), p[3]};
  }
  return {};
}

static int self_test() {
  unsigned checked = 0;
  for (unsigned status = 0; status < 256; status++) {
    for (unsigned opcode : {0x2016, 0x2019, 0x0406, 0x201a, 0x201b}) {
      bool complete = opcode == 0x201a || opcode == 0x201b;
      std::array<unsigned char, 9> packet{};
      packet[0] = 4;
      packet[1] = complete ? 14 : 15;
      packet[2] = complete ? 6 : 4;
      packet[complete ? 3 : 4] = 1;
      packet[complete ? 6 : 3] = status;
      packet[complete ? 4 : 5] = opcode & 255;
      packet[complete ? 5 : 6] = opcode >> 8;
      if (complete) { packet[7] = 0x34; packet[8] = 2; }
      size_t size = complete ? 9 : 7;
      auto r = decode(packet.data(), size);
      if (!r || r->status != status || r->opcode != opcode ||
          r->handle != (complete ? 0x234 : 0xffff)) return 1;
      for (size_t end = 0; end < size; end++) {
        if (decode(packet.data(), end)) return 1;
        auto truncated = packet;
        if (end >= 3) truncated[2] = end - 3;
        if (decode(truncated.data(), end)) return 1;
      }
      checked++;
    }
    for (unsigned event : {5, 8}) {
      unsigned char packet[] = {4, static_cast<unsigned char>(event), 4,
                               static_cast<unsigned char>(status), 0x34, 2, 0x13};
      auto r = decode(packet, sizeof(packet));
      if (!r || r->status != status || r->handle != 0x234 || r->detail != 0x13) return 1;
      checked++;
    }
  }
  // Arbitrary command returns and LE metadata (including key events) are omitted.
  for (unsigned opcode = 0; opcode < 65536; opcode++) {
    unsigned char packet[] = {4, 14, 6, 1, static_cast<unsigned char>(opcode),
                             static_cast<unsigned char>(opcode >> 8), 0, 0x34, 2};
    if (bool(decode(packet, sizeof(packet))) != (opcode == 0x201a || opcode == 0x201b)) return 1;
  }
  unsigned char key_event[] = {4, 0x3e, 4, 5, 0x34, 2, 42};
  if (decode(key_event, sizeof(key_event))) return 1;
  for (unsigned status = 0; status < 256; status++) {
    unsigned char packet[] = {4, 0x3e, 12, 4, static_cast<unsigned char>(status),
                             0x34, 2, 1, 2, 3, 4, 5, 6, 7, 8};
    auto r = decode(packet, sizeof(packet));
    if (!r || r->event != 0x3e || r->opcode != 0x2016 || r->status != status ||
        r->handle != 0x234 || r->detail != 4) return 1;
    for (size_t end = 0; end < sizeof(packet); end++) {
      if (decode(packet, end)) return 1;
    }
    for (unsigned subevent = 0; subevent < 256; subevent++) {
      packet[3] = subevent;
      if (bool(decode(packet, sizeof(packet))) != (subevent == 4)) return 1;
    }
    checked++;
  }
  std::printf("HCI_OBSERVER TEST checked=%u command-opcodes=65536\n", checked);
  return 0;
}

int main(int argc, char** argv) {
  if (argc == 2 && !std::strcmp(argv[1], "--self-test")) return self_test();
  bool probe = argc == 4 && !std::strcmp(argv[3], "--probe");
  bool features = argc == 4 && !std::strcmp(argv[3], "--features");
  if (argc != 3 && !probe && !features) {
    std::fprintf(stderr, "Usage: linux-command-events INDEX ADAPTER_ADDRESS [--probe|--features]\n");
    return 2;
  }
  char* end;
  long index = std::strtol(argv[1], &end, 10);
  if (!*argv[1] || *end || index < 0 || index >= HCI_DEV_NONE) return 2;
  unsigned bytes[6];
  int consumed = 0;
  if (std::strlen(argv[2]) != 17 || std::sscanf(argv[2], "%2x:%2x:%2x:%2x:%2x:%2x%n",
      bytes, bytes + 1, bytes + 2, bytes + 3, bytes + 4, bytes + 5, &consumed) != 6 || consumed != 17) return 2;
  int fd = socket(AF_BLUETOOTH, SOCK_RAW | SOCK_CLOEXEC | SOCK_NONBLOCK, BTPROTO_HCI);
  if (fd < 0) { std::perror("socket"); return 1; }
  struct Close { int fd; ~Close() { close(fd); } } close_fd{fd};
  hci_dev_info info{};
  info.dev_id = index;
  if (ioctl(fd, HCIGETDEVINFO, &info) < 0) { std::perror("controller info"); return 1; }
  for (unsigned i = 0; i < 6; i++) if (info.bdaddr.b[i] != bytes[5 - i]) return 1;
  hci_filter filter{};
  filter.type_mask = 1u << HCI_EVENT_PKT;
  for (unsigned event : {EVT_CMD_STATUS, EVT_CMD_COMPLETE, EVT_DISCONN_COMPLETE, EVT_ENCRYPT_CHANGE}) {
    filter.event_mask[event >> 5] |= 1u << (event & 31);
  }
  if (features) filter.event_mask[EVT_LE_META_EVENT >> 5] |= 1u << (EVT_LE_META_EVENT & 31);
  if (setsockopt(fd, SOL_HCI, HCI_FILTER, &filter, sizeof(filter)) < 0) { std::perror("filter"); return 1; }
  hci_filter actual{};
  socklen_t length = sizeof(actual);
  if (getsockopt(fd, SOL_HCI, HCI_FILTER, &actual, &length) < 0 || length != sizeof(actual) ||
      std::memcmp(&filter, &actual, sizeof(filter))) {
    std::fprintf(stderr, "Required event filter unavailable; --features requires CAP_NET_RAW.\n");
    return 1;
  }
  sockaddr_hci address{};
  address.hci_family = AF_BLUETOOTH;
  address.hci_dev = index;
  address.hci_channel = HCI_CHANNEL_RAW;
  if (bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) < 0) { std::perror("bind"); return 1; }
  setvbuf(stdout, nullptr, _IOLBF, 0);
  std::printf("HCI_OBSERVER READY adapter=%ld event-filter-verified=true\n", index);
  using Clock = std::chrono::steady_clock;
  auto deadline = Clock::now() + std::chrono::seconds(probe ? 1 : 20);
  unsigned selected = 0, received = 0, disconnected = 0;
  while (Clock::now() < deadline) {
    int remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count();
    pollfd ready{fd, POLLIN, 0};
    int result = poll(&ready, 1, remaining > 0 ? remaining : 1);
    if (result < 0) { std::perror("poll"); return 1; }
    if (!result) continue;
    unsigned char packet[260];
    ssize_t size = recv(fd, packet, sizeof(packet), MSG_TRUNC);
    if (size < 0 || size > ssize_t(sizeof(packet))) return 1;
    if (++received > 4096) return 1;
    auto record = decode(packet, size);
    if (!record) continue;
    if (++selected > 64) return 1;
    auto us = std::chrono::duration_cast<std::chrono::microseconds>(Clock::now().time_since_epoch()).count();
    std::printf("HCI_OBSERVER event=%u opcode=0x%04x status=0x%02x handle=%u detail=0x%02x us=%lld\n",
        record->event, record->opcode, record->status, record->handle, record->detail, static_cast<long long>(us));
    if (record->event == EVT_DISCONN_COMPLETE && disconnected++ == 0) {
      auto tail = Clock::now() + std::chrono::milliseconds(500);
      if (tail < deadline) deadline = tail;
    }
  }
  std::printf("HCI_OBSERVER COMPLETE selected=%u disconnected=%u\n", selected, disconnected);
  return probe || disconnected == 1 ? 0 : 1;
}
