// Copyright (C) 2018 Toitware ApS.
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

#include <functional>
#include <type_traits>

#include "top.h"
#include "os.h"

namespace toit {

class Process;

class Utils {
 public:
  template<typename T>
  static inline T min(T x, T y) {
    return x < y ? x : y;
  }

  template<typename T>
  static inline T max(T x, T y) {
    return x > y ? x : y;
  }

  template<typename T>
  static inline bool is_power_of_two(T x) {
    return (x & (x - 1)) == 0;
  }

  template<typename T>
  static inline bool is_aligned(T x, int n) {
    ASSERT(is_power_of_two(n));
    return ((x - static_cast<T>(0)) & (n - 1)) == 0;
  }

  template<typename T>
  static inline T round_down(T x, int n) {
    ASSERT(is_power_of_two(n));
    return (T)((uintptr_t)(x) & -n);
  }

  // Count leading zeros.  Returns the number of bits in T for a zero input.
  template<typename T>
  static inline int clz(T x) {
    if (x == 0) return sizeof(T) * BYTE_BIT_SIZE;
    typename std::make_unsigned<T>::type u = x;
    if (sizeof(T) == sizeof(long long)) {
      return __builtin_clzll(u);
    } else if (sizeof(T) == sizeof(long)) {
      return __builtin_clzl(u);
    } else {
      ASSERT(sizeof(T) <= sizeof(unsigned));
      return __builtin_clz(u) - (sizeof(int) - sizeof(T)) * BYTE_BIT_SIZE;
    }
  }

  // Count trailing zeros.  Returns the number of bits in T for a zero input.
  template<typename T>
  static inline int ctz(T x) {
    if (x == 0) return sizeof(T) * BYTE_BIT_SIZE;
    typename std::make_unsigned<T>::type u = x;
    if (sizeof(T) == sizeof(long long)) {
      return __builtin_ffsll(u) - 1;
    } else if (sizeof(T) == sizeof(long)) {
      return __builtin_ffsl(u) - 1;
    } else {
      ASSERT(sizeof(T) <= sizeof(unsigned));
      return __builtin_ffs(u) - 1;
    }
  }

  static const uint8 popcount_table[256];

  // Count ones in the binary representation.
  template<typename T>
  static inline int popcount(T x) {
    typename std::make_unsigned<T>::type u = x;
#ifdef __XTENSA__
    int result = 0;
    for (int i = 0; i < sizeof(u); i++) {
      uint8 b = u & 0xff;
      result += popcount_table[b];
      u >>= 8;
    }
    return result;
#else
    if (sizeof(T) == sizeof(long long)) {
      return __builtin_popcountll(u);
    } else if (sizeof(T) == sizeof(long)) {
      return __builtin_popcountl(u);
    } else {
      ASSERT(sizeof(T) <= sizeof(unsigned));
      return __builtin_popcount(u);
    }
#endif
  }

  template<typename T>
  static inline T address_at(T base, int byte_offset) {
    return reinterpret_cast<T>(((uword) base) + byte_offset);
  }

  template<typename T, typename S>
  static inline word address_distance(T first, S second) {
    return ((word) second) - ((word) first);
  }

  template<typename T>
  static inline T round_up(T x, int n) {
    return round_down(x + n - 1, n);
  }

  // Implementation is from "Hacker's Delight" by Henry S. Warren, Jr.,
  // figure 3-3, page 48, where the function is called clp2.
  template<typename T>
  static inline T round_up_to_power_of_two(T x) {
    x = x - 1;
    x = x | (x >> 1);
    x = x | (x >> 2);
    x = x | (x >> 4);
    x = x | (x >> 8);
    x = x | (x >> 16);
    return x + 1;
  }

  /**
  Sets `bit_size` contiguous bits to ones in an area starting at the `from`
    bit.
  Bits are numbered in little-endian order within a T.  Normally T would be
    uint32 or uword.
  `from` should be less than the bit-size of T.
  */
  template<typename T>
  static inline void mark_bits(T* data, int from, int bit_size) {
    set_or_clear_bits<T, true>(data, from, bit_size);
  }

  /**
  Sets bit_size contiguous bits to zeros in an area starting at the `from` bit.
  Bits are numbered in little-endian order within a T.  Normally T would be
    uint32 or uword.
  `from` should be less than the bit-size of T.
  */
  template<typename T>
  static inline void clear_bits(T* data, int from, int bit_size) {
    set_or_clear_bits<T, false>(data, from, bit_size);
  }

  // See `mark_bits` and `clear_bits`.
  template<typename T, bool set>
  static inline void set_or_clear_bits(T* data, int from, int bit_size) {
    static const int T_BITS = BYTE_BIT_SIZE * sizeof(T);
    static const T ALL_ONES = -1;
    static const T ONE = 1;
    if (bit_size + from >= T_BITS) {
      // Handle the first word of marking where some bits at the start of the
      // word are not set.
      if (set) {
        *data |= ALL_ONES << from;
      } else {
        *data &= (ONE << from) - 1;
      }
    } else {
      // This is the case where the marked area both starts and ends in the same
      // word.
      T mask = 1;
      mask = (mask << bit_size) - 1;
      if (set) {
        *data |= mask << from;
      } else {
        *data &= ~(mask << from);
      }
      return;
    }

    data++;
    ASSERT(bit_size + from >= T_BITS);
    for (bit_size -= T_BITS - from; bit_size >= T_BITS; bit_size -= T_BITS) {
      // Full bit_size where whole words are marked.
      if (set) {
        *data++ = ALL_ONES;
      } else {
        *data++ = 0;
      }
    }
    if (bit_size != 0) {
      // The last word where some bits near the end of the word are not marked.
      if (set) {
        *data |= (ONE << bit_size) - 1;
      } else {
        *data &= ALL_ONES << bit_size;
      }
    }
  }

  template<typename T>
  static inline uint16 read_unaligned_uint16(T* ptr) {
    uint16 result;
    memcpy(&result, ptr, sizeof(result));
    return result;
  }

  template<typename T>
  static inline uint16 read_unaligned_uint16_be(T* ptr) {
    uint16 le = read_unaligned_uint16(ptr);
    return (le >> 8) | (le << 8);
  }

  template<typename T>
  static inline void write_unaligned_uint16(T* ptr, uint16 value) {
    memcpy(ptr, &value, sizeof(value));
  }

  // This needs fixing if we ever port to a big-endian platform.
  template<typename T>
  static inline uint32 read_unaligned_uint32_le(T* ptr) {
    return read_unaligned_uint32(ptr);
  }

  template<typename T>
  static inline uint32 read_unaligned_uint32_be(T* ptr) {
    uint32 le = read_unaligned_uint32(ptr);
    return (le >> 24) | ((le >> 8) & 0xff00) | ((le << 8) & 0xff0000) | (le << 24);
  }

  template<typename T>
  static inline uint32 read_unaligned_uint32(T* ptr) {
    uint32 result;
    memcpy(&result, ptr, sizeof(result));
    return result;
  }

  // This needs fixing if we ever port to a big-endian platform.
  template<typename T>
  static inline void write_unaligned_uint32_le(T* ptr, uint32 value) {
    memcpy(ptr, &value, sizeof(value));
  }

  template<typename T>
  static inline void write_unaligned_uint32(T* ptr, uint32 value) {
    memcpy(ptr, &value, sizeof(value));
  }

  template<typename T>
  static inline word read_unaligned_word(T* ptr) {
    word result;
    memcpy(&result, ptr, sizeof(result));
    return result;
  }

  static uint32 crc32(uint32 crc, const uint8* ptr, size_t length);

  // Reverse the order of the bits in an 8 bit byte.
  static inline uint8 reverse_8(uint8 b) {
    return (REVERSE_NIBBLE[b & 0b1111] << 4) | REVERSE_NIBBLE[b >> 4];
  }

  // The maximum value that is ASCII.  ASCII characters are represented by
  // themselves in UTF-8.
  static const int MAX_ASCII = 0x7f;
  static const int MAX_TWO_BYTE_UNICODE = 0x7ff;
  static const int MAX_THREE_BYTE_UNICODE = 0xffff;
  static const int MAX_UNICODE = 0x10ffff;
  static const int MIN_SURROGATE = 0xd800;
  static const int MAX_SURROGATE = 0xdfff;
  // UTF-8 prefix bytes go from 0xc0 and up.
  static const int UTF_8_PREFIX = 0xc0;
  // UTF-8 bytes after the prefix bytes go from 0x80 to 0xbf.
  static const int UTF_8_PAYLOAD = 0x80;
  // Bytes after the prefix contain 6 bits of payload in the low 6 bits.
  static const int UTF_8_BITS_PER_BYTE = 6;
  static const int UTF_8_MASK = 0x3f;

  static bool is_utf_8_prefix(unsigned char c) {
    // Also returns true for some illegal prefix bytes for very long sequences that are no longer legal.
    return c >= UTF_8_PREFIX;
  }

  static word utf_16_to_8(const uint16* input, word length, uint8* output = null, word output_length = 0);
  static word utf_8_to_16(const uint8* input, word length, uint16* output = null, word output_length = 0);
#ifdef TOIT_WINDOWS
  static inline word utf_16_to_8(const wchar_t* input, word length, uint8* output, word output_length) {
    return utf_16_to_8(reinterpret_cast<const uint16*>(input), length, output, output_length);
  }
  static inline word utf_8_to_16(const uint8* input, word length, wchar_t* output, word output_length) {
    return utf_8_to_16(input, length, reinterpret_cast<uint16*>(output), output_length);
  }
  static inline word utf_16_to_8(const wchar_t* input, word length) {
    return utf_16_to_8(reinterpret_cast<const uint16*>(input), length, static_cast<uint8*>(null), 0);
  }
#endif
  // Note: Does malloc - not suitable for embedded.
  static bool utf_8_equals_utf_16(const uint8* input1, word length1, const uint16* input2, word length2);
  static uint16* create_new_environment(Process* process, uint16* previous_environment, Array* environment);

  // The number of leading ones in the prefix byte determines the length of a
  // UTF-8 sequence.
  static int bytes_in_utf_8_sequence(unsigned char prefix) {
    if (prefix <= MAX_ASCII) return 1;
    int count = 0;
    int mask = 0x80;
    while ((prefix & mask) != 0) {
      count++;
      mask >>= 1;
    }
    return count;
  }

  static int payload_from_prefix(unsigned char prefix) {
    int n_byte_sequence = bytes_in_utf_8_sequence(prefix);
    return prefix & ((1 << (7 - n_byte_sequence)) - 1);
  }

  static bool is_valid_utf_8(const uint8* buffer, int length);

 private:
  static const uint8 REVERSE_NIBBLE[16];
};

static inline void memcpy_reverse(void* dst, const void* src, size_t n) {
  for (size_t i = 0; i < n; ++i) {
    reinterpret_cast<uint8*>(dst)[n-1-i] = reinterpret_cast<const uint8*>(src)[i];
  }
}

// Use instead of a reinterpret_cast if the only thing you want to do is to
// convert a pointer to a signed type into a pointer to an unsigned type.
// Unlike reinterpret_cast this documents why you need the cast and doesn't let
// you accidentally do unrelated casts.
template<typename T>
inline typename std::make_unsigned<T>::type* unsigned_cast(T* t) {
  return reinterpret_cast<typename std::make_unsigned<T>::type*>(t);
}

// Use instead of a reinterpret_cast if the only thing you want to do is to
// convert a pointer to an unsigned type into a pointer to a signed type.
// Unlike reinterpret_cast this documents why you need the cast and doesn't let
// you accidentally do unrelated casts.
template<typename T>
inline typename std::make_signed<T>::type* signed_cast(T* t) {
  return reinterpret_cast<typename std::make_signed<T>::type*>(t);
}

// The type 'signed char*' is almost never what you need, if you want to
// cast an unsigned char* to a char* then use char_cast instead of signed_cast.
inline char* char_cast(unsigned char* t) {
  return reinterpret_cast<char*>(t);
}

inline const char* char_cast(const unsigned char* t) {
  return reinterpret_cast<const char*>(t);
}

inline char* char_cast(signed char* t) {
  return reinterpret_cast<char*>(t);
}

inline const char* char_cast(const signed char* t) {
  return reinterpret_cast<const char*>(t);
}

// Use instead of a reinterpret_cast if the only thing you want to do is to
// convert a void pointer to a different pointer.  Unlike reinterpret_cast this
// documents why you need the cast and doesn't let you accidentally do
// unrelated casts.
template<typename T>
inline T unvoid_cast(void* p) {
  return reinterpret_cast<T>(p);
}

// Use instead of a reinterpret_cast if the only thing you want to do is to
// convert a void pointer to a different pointer.  Unlike reinterpret_cast this
// documents why you need the cast and doesn't let you accidentally do
// unrelated casts.
template<typename T>
inline T unvoid_cast(const void* p) {
  return reinterpret_cast<T>(p);
}

// Use instead of a reinterpret_cast if the only thing you want to do is to
// convert a non-void pointer to a void pointer.  Unlike reinterpret_cast this
// documents why you need the cast and doesn't let you accidentally do
// unrelated casts.
template<typename T>
inline void* void_cast(T* p) {
  return reinterpret_cast<void*>(p);
}

// Use instead of a reinterpret_cast if the only thing you want to do is to
// convert a non-void pointer to a void pointer.  Unlike reinterpret_cast this
// documents why you need the cast and doesn't let you accidentally do
// unrelated casts.
template<typename T>
inline const void* void_cast(const T* p) {
  return reinterpret_cast<const void*>(p);
}

// Provide information about which version of the VM is running.
const char* vm_git_version();
const char* vm_git_info();
const char* vm_sdk_model();

// Code copied from https://en.cppreference.com/w/cpp/numeric/bit_cast
template <class To, class From>
typename std::enable_if<
  (sizeof(To) == sizeof(From)) &&
  std::is_trivially_copyable<From>::value &&
  std::is_trivial<To>::value,
  // this implementation requires that To is trivially default constructible
  To>::type
// constexpr support needs compiler magic
bit_cast(const From& src) noexcept {
  To dst;
  std::memcpy(&dst, &src, sizeof(To));
  return dst;
}

template<typename T>
class List {
 public:
  List() : data_(null), length_(0) {}
  List(T* data, int length) : data_(data), length_(length) {
    ASSERT(length >= 0);
  }

  // Mainly for use in passing a non-const List to something that expects a
  // const List.
  template <typename U>
  List(List<U> other) : data_(other.data_), length_(other.length_) {
    ASSERT(other.length_ >= 0);
  }

  T* data() const { return data_; }
  T*& data() { return data_; }
  int length() const { return length_; }
  bool is_empty() const { return length_ == 0; }

  T& operator[](int index) {
    ASSERT(index >= 0 && index < length_);
    return data_[index];
  }

  const T& operator[](int index) const {
    ASSERT(index >= 0 && index < length_);
    return data_[index];
  }

  void clear() {
    data_ = null;
    length_ = 0;
  }

  T* begin() { return data_; }
  const T* begin() const { return data_; }
  T* end() { return &data_[length_]; }
  const T* end() const { return &data_[length_]; }

  bool is_inside(const T* pointer) const {
    return (pointer >= begin() && pointer < end());
  }

  const List<T> sublist(int from, int to) const {
    ASSERT(0 <= from && from <= to && to <= length_);
    return List<T>(&data_[from], to - from);
  }

  T& first() {
    ASSERT(length_ > 0);
    return data_[0];
  }

  T& last() {
    ASSERT(length_ > 0);
    return data_[length_ - 1];
  }

  const T& first() const {
    ASSERT(length_ > 0);
    return data_[0];
  }

  const T& last() const {
    ASSERT(length_ > 0);
    return data_[length_ - 1];
  }

 private:
  T* data_;
  int length_;

  template <typename U>
  friend class List;
};

class Base64Encoder {
 public:
  Base64Encoder(bool url_mode = false) : rest(0), bit_count(0), url_mode(url_mode) {}

  static inline word output_size(word input_size, bool url_mode) {
    if (!url_mode) return ((input_size + 2) / 3) * 4;
    // Desired result:
    // 0 -> 0
    // 1 -> 2
    // 2 -> 3
    // 3 -> 4
    return (((input_size + 1) * 4) - 2) / 3;
  }

  void encode(const uint8* data, word size, const std::function<void (uint8 out_byte)>& f);
  void finish(const std::function<void (uint8 out_byte)>& f);

 private:
  uword rest;
  uword bit_count;
  bool url_mode;
};

extern void iram_safe_char_memcpy(char* dest, const char* src, size_t bytes);

// When using IRAM on the ESP32 we can only use the l32.i and s32.i instructions
// to access memory. This is not a constraint that can be communicated to the
// C++ compiler, so you must call this method, implemented in assembler.  The
// size is always measured in bytes and must be divisible by 4.  Addresses must
// also be divisible by 4.  As with memcpy, the areas should not overlap.
template
<typename T, typename U>
extern void iram_safe_memcpy(T* dest, const U* src, size_t bytes) {
  iram_safe_char_memcpy(reinterpret_cast<char*>(dest), reinterpret_cast<const char*>(src), bytes);
}

struct Defer {
  std::function<void()> fun;
  ~Defer() { fun(); }
};

template <typename T>
class DeferDelete {
 public:
  DeferDelete(T* object) : object_(object) {}
  ~DeferDelete() { delete object_; }
  void keep() { object_ = null; }

 private:
  T* object_;
};

class AsyncThread : public Thread {
 public:
  static void run_async(const std::function<void()> &func) {
    _new AsyncThread(func);
  }

 protected:
  explicit AsyncThread(std::function<void()> func) : Thread("async"), _func(std::move(func)) {
    spawn();
  }

  void entry() override {
    _func();
    delete this;
  }

 private:
  const std::function<void()> _func;
};


} // namespace toit
