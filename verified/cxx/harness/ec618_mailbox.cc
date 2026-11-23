// Copyright (C) 2026 Toit contributors.
#include "prelude.h"
#include <atomic>
#define private public
#include "event_sources/mailbox_ec618.h"
#undef private

using namespace toit;

// The ten completion slots include the unused hole at index two.
// Build an independent expected state and check the full drain, including
// unrelated entries present before the publication.
static uint32_t uart[3], generations[10], pending;
static void observe(Event::Type type, uint32_t data) {
  if (type >= Event::UART_0 && type <= Event::UART_2) {
    unsigned id = type - Event::UART_0;
    CXXV_ASSERT(data < 4, "UART dispatch has a valid kind");
    uint32_t bit = 1u << data;
    CXXV_ASSERT((uart[id] & bit) != 0, "dispatch each pending UART kind once on its port");
    uart[id] &= ~bit;
  } else {
    unsigned id = type - (Event::GPIO_NUM_0 + 32);
    CXXV_ASSERT(id < 10 && id != 2, "dispatch only valid completion controllers");
    uint32_t bit = 1u << id;
    CXXV_ASSERT((pending & bit) != 0 && generations[id] == data, "deliver the latest pending generation once");
    pending &= ~bit;
  }
}

int main() {
  Ec618EventMailbox box;
  bool fresh = nondet_bool();
  for (unsigned id = 0; id < 3; ++id) {
    if (!fresh) {
      uart[id] = nondet_uint() & 15u;
      box.uart_[id].store(uart[id]);
    }
  }
  if (!fresh) {
    pending = nondet_uint() & 0x3fbu;
    box.completions_.pending_.store(pending);
    for (unsigned id = 0; id < 10; ++id) {
      generations[id] = nondet_uint();
      box.completions_.generation_[id].store(generations[id]);
    }
  }

  Event::Type type = static_cast<Event::Type>(nondet_uint());
  word value = nondet_word();
  bool serial = type >= Event::UART_0 && type <= Event::UART_2;
  unsigned slot = type - (Event::GPIO_NUM_0 + 32);
  bool completion = slot < 10 && slot != 2;
  CXXV_ASSERT(box.retains(type) == (serial || completion), "classify every 32-bit event type");
  bool wake = true;
  if (serial) {
    CXXV_ASSUME(value >= 0 && value < 4);
    unsigned id = type - Event::UART_0;
    wake = uart[id] == 0;
    uart[id] |= 1u << value;
  } else if (completion) {
    uint32_t bit = 1u << slot;
    wake = (pending & bit) == 0;
    pending |= bit;
    generations[slot] = static_cast<uint32_t>(value);
  }
  bool requested = box.publish(type, value);
  CXXV_ASSERT(requested == wake, "request a wake on first retained publication or every direct event");
  // Compare before draining too, so this transition composes with another
  // publish when a full queue prevents enqueuing a wake token.
  for (unsigned id = 0; id < 3; ++id) {
    CXXV_ASSERT(box.uart_[id].load() == uart[id], "publication preserves unrelated UART kinds");
  }
  CXXV_ASSERT(box.completions_.pending_.load() == pending, "completion pending set matches publication");
  for (unsigned id = 0; id < 10; ++id) {
    CXXV_ASSERT(box.completions_.generation_[id].load() == generations[id], "only selected generation changes");
  }
  box.drain(observe);
  CXXV_ASSERT(!(uart[0] | uart[1] | uart[2] | pending), "all prior and new retained events delivered");
  box.drain(observe);
}
