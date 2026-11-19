// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the license in the LICENSE file.

#pragma once

#include <atomic>
#include <stdint.h>

namespace toit {

// Completion notifications describe persistent resource state, not individual edges.
// Coalesce them by controller, retaining the latest generation even if the
// shared wake-up queue is full. Its consumer drains this mailbox after every
// queued event, so a full queue cannot discard the last/fatal notification.
template <unsigned Count>
class CompletionEventMailbox {
  static_assert(Count > 0 && Count <= 32, "Mailbox pending bits must fit in uint32_t");
 public:
  // Returns true when the caller should try to enqueue a wake-up token.
  bool publish(unsigned id, uint32_t generation) {
    generation_[id].store(generation, std::memory_order_release);
    uint32_t bit = 1u << id;
    return !(pending_.fetch_or(bit, std::memory_order_acq_rel) & bit);
  }

  bool take(unsigned id, uint32_t* generation) {
    uint32_t bit = 1u << id;
    if (!(pending_.fetch_and(~bit, std::memory_order_acq_rel) & bit)) return false;
    *generation = generation_[id].load(std::memory_order_acquire);
    return true;
  }

 private:
  std::atomic<uint32_t> generation_[Count] = {};
  std::atomic<uint32_t> pending_{0};
};

using I2sEventMailbox = CompletionEventMailbox<2>;

}  // namespace toit
