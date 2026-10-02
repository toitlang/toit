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

// A compilation owns one zone. The public `Compiler` entry points (`compile`,
// `analyze`, `language_server`) establish it; AST, IR, symbols, and source maps
// share its lifetime because later passes refer back to earlier ones.
// Results that outlive the compilation, such as the returned snapshot bundle,
// must not be allocated in the zone.
//
// Nested zones may be used for shorter-lived work, but only if all values they
// allocate die together.
// The current zone is thread-local; clients of compiler helpers (including tests)
// must establish a zone before allocating and must not retain its objects beyond
// its lifetime. There is no fallback zone.
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

  // Allocates uninitialized storage for an array. The caller must construct
  // every element before the zone is released.
  // Arrays of non-trivially destructible elements store their length in a
  // header, so the cleanup can destroy the elements in reverse order.
  template<typename T>
  T* allocate_array(size_t length) {
    static_assert(alignof(T) <= alignof(std::max_align_t), "Over-aligned zone array");
    constexpr size_t header = std::is_trivially_destructible<T>::value
        ? 0
        : alignof(std::max_align_t);
    if (length > (std::numeric_limits<size_t>::max() - header) / sizeof(T)) {
      FATAL("Compiler zone allocation too large");
    }
    char* storage = static_cast<char*>(allocate(header + length * sizeof(T)));
    if (header != 0) {
      *reinterpret_cast<size_t*>(storage) = length;
      add_cleanup(storage, [](void* storage) {
        size_t length = *static_cast<size_t*>(storage);
        T* elements = reinterpret_cast<T*>(static_cast<char*>(storage) + alignof(std::max_align_t));
        for (size_t i = length; i > 0; i--) elements[i - 1].~T();
      });
    }
    return reinterpret_cast<T*>(storage + header);
  }

  // Adopt allocations with an existing allocation/deallocation contract.
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
