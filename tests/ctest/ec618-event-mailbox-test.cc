// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the license in tests/LICENSE.

#include <atomic>
#include <chrono>
#include <deque>
#include <stdio.h>
#include <stdlib.h>
#include <thread>
#include <vector>

#include "../../src/event_sources/mailbox_ec618.h"

using toit::Ec618EventMailbox;
using toit::Event;

#define CHECK(condition) do { \
  if (!(condition)) { \
    fprintf(stderr, "line %d: %s\n", __LINE__, #condition); \
    exit(1); \
  } \
} while (0)

static const Event::Type completions[] = {
  Event::i2c_type(0), Event::i2c_type(1), Event::spi_type(0), Event::spi_type(1),
  Event::one_wire_type(), Event::i2s_type(0), Event::i2s_type(1),
  Event::adc_type(0), Event::adc_type(1),
};

// Models the bounded transport around the production mailbox. A retained
// event's queue token is deliberately not its authoritative payload.
class Pump {
 public:
  Ec618EventMailbox mailbox;
  std::deque<Event> queue;
  std::vector<Event> delivered;
  unsigned dropped = 0;

  void publish(Event::Type type, word data) {
    if (!mailbox.publish(type, data)) return;
    if (queue.size() == 32) {
      dropped++;
      return;
    }
    queue.push_back({type, data});
  }

  void consume() {
    CHECK(!queue.empty());
    Event event = queue.front();
    queue.pop_front();
    if (!Ec618EventMailbox::retains(event.type)) delivered.push_back(event);
    mailbox.drain([&](Event::Type type, uint32_t data) {
      delivered.push_back({type, static_cast<word>(data)});
    });
  }
};

static void test_full_queue() {
  Pump pump;
  for (int i = 0; i < 32; i++) pump.publish(Event::gpio_type(0), i);
  for (auto type : completions) {
    pump.publish(type, 0x12340001);
    pump.publish(type, 0x56780001);  // Superseded transfer/generation.
  }
  for (unsigned id = 0; id < 3; id++) {
    for (unsigned kind = Event::UART_KIND_RX; kind <= Event::UART_KIND_BREAK; kind++) {
      for (int repeat = 0; repeat < 100; repeat++) pump.publish(Event::uart_type(id), kind);
    }
  }
  CHECK(pump.dropped == 12);  // Nine completions plus three UART wake tokens.
  pump.consume();
  CHECK(pump.delivered.size() == 22);  // GPIO, 12 UART kinds, nine completions.
  for (auto type : completions) {
    unsigned count = 0;
    for (auto event : pump.delivered) {
      if (event.type != type) continue;
      CHECK(event.data == 0x56780001);
      count++;
    }
    CHECK(count == 1);
  }
  for (unsigned id = 0; id < 3; id++) {
    unsigned kinds = 0;
    for (auto event : pump.delivered) {
      if (event.type == Event::uart_type(id)) kinds |= 1u << event.data;
    }
    CHECK(kinds == 15);  // RX, TX completion, error and break all survive.
  }
  while (!pump.queue.empty()) pump.consume();
  CHECK(pump.delivered.size() == 53);
  unsigned next_gpio = 0;
  for (auto event : pump.delivered) {
    if (event.type == Event::gpio_type(0)) CHECK(event.data == next_gpio++);
  }
  CHECK(next_gpio == 32);  // GPIO transitions retain order and multiplicity.
  CHECK(!Ec618EventMailbox::retains(Event::STOP));
  CHECK(!Ec618EventMailbox::retains(Event::none_type()));
  for (int pin = 0; pin < 32; pin++) CHECK(!Ec618EventMailbox::retains(Event::gpio_type(pin)));
}

static void test_stale_tokens_and_republish() {
  Pump pump;
  pump.publish(Event::one_wire_type(), 1);
  pump.publish(Event::one_wire_type(), 2);
  CHECK(pump.queue.size() == 1);
  pump.consume();
  CHECK(pump.delivered.size() == 1);
  CHECK(pump.delivered.back().data == 2);
  // A token left behind after another event drained the mailbox carries no
  // stale completion to dispatch into a reopened resource.
  pump.queue.push_back({Event::one_wire_type(), 1});
  pump.consume();
  CHECK(pump.delivered.size() == 1);
  pump.publish(Event::one_wire_type(), 3);
  pump.consume();
  CHECK(pump.delivered.size() == 2);
  CHECK(pump.delivered.back().data == 3);

  CHECK(pump.mailbox.publish(Event::UART_0, Event::UART_KIND_RX));
  pump.mailbox.drain([&](Event::Type type, uint32_t data) {
    CHECK(type == Event::UART_0 && data == Event::UART_KIND_RX);
    CHECK(pump.mailbox.publish(type, Event::UART_KIND_TX_DONE));
  });
  unsigned received = 0;
  pump.mailbox.drain([&](Event::Type type, uint32_t data) {
    CHECK(type == Event::UART_0 && data == Event::UART_KIND_TX_DONE);
    received++;
  });
  CHECK(received == 1);
}

static void test_concurrent_publish_and_drain() {
  Ec618EventMailbox mailbox;
  constexpr unsigned last = 100000;
  std::atomic<unsigned> done{0};
  std::thread producers[3];
  for (unsigned id = 0; id < 3; id++) {
    producers[id] = std::thread([&, id] {
      for (unsigned generation = 1; generation <= last; generation++) {
        for (unsigned i = id; i < 9; i += 3) mailbox.publish(completions[i], generation);
        for (unsigned kind = 0; kind < 4; kind++) mailbox.publish(Event::uart_type(id), kind);
      }
      done.fetch_add(1, std::memory_order_release);
    });
  }
  uint32_t seen[9] = {};
  unsigned uart_kinds[3] = {};
  auto consume = [&](Event::Type type, uint32_t data) {
    if (type >= Event::UART_0 && type <= Event::UART_2) {
      uart_kinds[type - Event::UART_0] |= 1u << data;
    } else {
      for (unsigned i = 0; i < 9; i++) {
        if (completions[i] != type) continue;
        CHECK(data >= seen[i]);
        seen[i] = data;
      }
    }
  };
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
  while (done.load(std::memory_order_acquire) != 3) {
    mailbox.drain(consume);
    CHECK(std::chrono::steady_clock::now() < deadline);
  }
  for (auto& producer : producers) producer.join();
  mailbox.drain(consume);
  for (auto value : seen) CHECK(value == last);
  for (auto value : uart_kinds) CHECK(value == 15);
}

int main() {
  toit::AllowThrowingNew allow;
  test_full_queue();
  test_stale_tokens_and_republish();
  test_concurrent_publish_and_drain();
  puts("EC618 peripheral completion delivery under queue saturation PASS");
}
