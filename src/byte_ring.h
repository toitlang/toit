// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#pragma once

#include <atomic>
#include <string.h>

#include "top.h"

namespace toit {

// A lock-free byte ring for one producer and one consumer, for example an
// ISR or driver task feeding a primitive. The producer calls free_space and
// push, the consumer calls available and pop. Each side's view is
// conservative: the other side can only make it larger.
//
// The indices run over [0, 2 * capacity), so head == tail means empty and
// a distance of capacity means full. Any capacity works and all of it is
// usable.
//
// The ring does not own its buffer.
class ByteRing {
 public:
  ByteRing() = default;
  ByteRing(uint8* buffer, word capacity) { init(buffer, capacity); }

  // Not thread safe: neither side may use the ring meanwhile.
  void init(uint8* buffer, word capacity) {
    // Indices reach 3 * capacity before wrapping, which must fit in a word.
    ASSERT(capacity > 0 && capacity <= (static_cast<word>(1) << 29));
    buffer_ = buffer;
    capacity_ = capacity;
    head_.store(0, std::memory_order_relaxed);
    tail_.store(0, std::memory_order_relaxed);
  }

  word capacity() const { return capacity_; }

  // Consumer side.
  word available() const {
    return distance(head_.load(std::memory_order_acquire), tail_.load(std::memory_order_relaxed));
  }

  // Producer side.
  word free_space() const {
    return capacity_ - distance(head_.load(std::memory_order_relaxed), tail_.load(std::memory_order_acquire));
  }

  // Producer side. Copies as much of data as fits and returns the number
  // of bytes copied.
  word push(const uint8* data, word length) {
    ASSERT(length >= 0);
    word head = head_.load(std::memory_order_relaxed);
    word tail = tail_.load(std::memory_order_acquire);
    word n = min(length, capacity_ - distance(head, tail));
    word at = position(head);
    word first = min(n, capacity_ - at);
    memcpy(buffer_ + at, data, first);
    memcpy(buffer_, data + first, n - first);
    head_.store(advance(head, n), std::memory_order_release);
    return n;
  }

  // Consumer side. Copies at most max bytes to 'to' and returns the number
  // of bytes copied.
  word pop(uint8* to, word max) {
    ASSERT(max >= 0);
    word head = head_.load(std::memory_order_acquire);
    word tail = tail_.load(std::memory_order_relaxed);
    word n = min(max, distance(head, tail));
    word at = position(tail);
    word first = min(n, capacity_ - at);
    memcpy(to, buffer_ + at, first);
    memcpy(to + first, buffer_, n - first);
    tail_.store(advance(tail, n), std::memory_order_release);
    return n;
  }

 private:
  uint8* buffer_ = null;
  word capacity_ = 0;
  std::atomic<word> head_{0};  // Written by the producer.
  std::atomic<word> tail_{0};  // Written by the consumer.

  static word min(word a, word b) { return a < b ? a : b; }

  word distance(word head, word tail) const {
    word result = head - tail;
    return result >= 0 ? result : result + 2 * capacity_;
  }

  word position(word index) const {
    return index < capacity_ ? index : index - capacity_;
  }

  word advance(word index, word n) const {
    index += n;
    return index < 2 * capacity_ ? index : index - 2 * capacity_;
  }
};

} // namespace toit
