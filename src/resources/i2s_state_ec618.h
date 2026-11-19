// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the license in the LICENSE file.

#pragma once

#include <stdint.h>

namespace toit {

// A DMA fault remains visible to every waiter until synchronous stop has
// quiesced both channels. Queued events from previous runs cannot revive it.
class I2sRunState {
 public:
  enum Phase { UNCONFIGURED, STOPPED, RUNNING, FAILED };

  Phase phase() const { return phase_; }
  bool active() const { return phase_ == RUNNING || phase_ == FAILED; }
  bool failed() const { return phase_ == FAILED; }
  uint32_t generation() const { return generation_; }

  bool configure() {
    if (active()) return false;
    phase_ = STOPPED;
    return true;
  }

  bool start(uint32_t generation) {
    if (phase_ != STOPPED) return false;
    generation_ = generation;
    phase_ = RUNNING;
    return true;
  }

  bool fail() {
    if (phase_ != RUNNING) return false;
    phase_ = FAILED;
    return true;
  }

  bool stop() {
    if (!active()) return false;
    phase_ = STOPPED;
    return true;
  }

  bool accepts(uint32_t generation) const {
    return active() && generation == generation_;
  }

 private:
  volatile Phase phase_ = UNCONFIGURED;
  uint32_t generation_ = 0;
};

}  // namespace toit
