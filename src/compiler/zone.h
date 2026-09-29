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

#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <new>
#include <type_traits>
#include <utility>

#include "../top.h"

namespace toit {
namespace compiler {

// A compilation owns one zone. Nested zones may be used for shorter-lived work.
// The current zone is thread-local; clients of compiler helpers must establish a
// zone before allocating and must not retain its objects beyond its lifetime.
// Objects are destroyed in reverse construction order, before releasing storage.
// Destructors must not traverse other zone objects (which may already be dead).
class Zone {
 public:
  Zone() : previous_(current_) { current_ = this; }
  ~Zone() {
    ASSERT(current_ == this);
    while (cleanups_ != null) {
      Cleanup* cleanup = cleanups_;
      cleanups_ = cleanup->next;
      cleanup->destroy(cleanup->object);
    }
    while (chunks_ != null) {
      Chunk* chunk = chunks_;
      chunks_ = chunk->next;
      free(chunk);
    }
    current_ = previous_;
  }

  Zone(const Zone&) = delete;
  Zone& operator=(const Zone&) = delete;

  static Zone* current() {
    if (current_ == null) FATAL("Compiler allocation requires a zone");
    return current_;
  }

  void* allocate(size_t size) {
    constexpr size_t alignment = alignof(std::max_align_t);
    if (size > std::numeric_limits<size_t>::max() - alignment - sizeof(Chunk)) {
      FATAL("Compiler zone allocation too large");
    }
    size = (size + alignment - 1) & ~(alignment - 1);
    if (size == 0) size = alignment;
    if (chunks_ == null || chunks_->remaining < size) {
      size_t capacity = size > CHUNK_SIZE ? size : CHUNK_SIZE;
      auto chunk = static_cast<Chunk*>(malloc(sizeof(Chunk) + capacity));
      if (chunk == null) FATAL("Out of memory in compiler zone");
      chunk->next = chunks_;
      chunk->remaining = capacity;
      chunk->cursor = reinterpret_cast<char*>(chunk + 1);
      chunks_ = chunk;
    }
    void* result = chunks_->cursor;
    chunks_->cursor += size;
    chunks_->remaining -= size;
    return result;
  }

  template<typename T, typename... Args>
  T* construct(Args&&... args) {
    static_assert(alignof(T) <= alignof(std::max_align_t), "Over-aligned zone object");
    T* result = new (allocate(sizeof(T))) T(std::forward<Args>(args)...);
    if (!std::is_trivially_destructible<T>::value) {
      add_cleanup(result, [](void* object) { static_cast<T*>(object)->~T(); });
    }
    return result;
  }

  // Adopt allocations with an existing allocation/deallocation contract.
  template<typename T>
  T* own_array(T* array) {
    add_cleanup(array, [](void* object) { delete[] static_cast<T*>(object); });
    return array;
  }

  template<typename T>
  T* own_malloc(T* buffer) {
    if (buffer != null) {
      add_cleanup(const_cast<void*>(static_cast<const void*>(buffer)), free);
    }
    return buffer;
  }

  char* strdup(const char* str) {
    size_t size = strlen(str) + 1;
    auto result = static_cast<char*>(allocate(size));
    memcpy(result, str, size);
    return result;
  }

 private:
  struct alignas(std::max_align_t) Chunk {
    Chunk* next;
    size_t remaining;
    char* cursor;
  };
  struct Cleanup {
    Cleanup* next;
    void* object;
    void (*destroy)(void*);
  };

  static constexpr size_t CHUNK_SIZE = 64 * 1024;
  static thread_local Zone* current_;
  Zone* previous_;
  Chunk* chunks_ = null;
  Cleanup* cleanups_ = null;

  void add_cleanup(void* object, void (*destroy)(void*)) {
    auto cleanup = static_cast<Cleanup*>(allocate(sizeof(Cleanup)));
    *cleanup = {cleanups_, object, destroy};
    cleanups_ = cleanup;
  }
};

template<typename T, typename... Args>
T* zone_new(Args&&... args) {
  return Zone::current()->construct<T>(std::forward<Args>(args)...);
}

} // namespace toit::compiler
} // namespace toit
