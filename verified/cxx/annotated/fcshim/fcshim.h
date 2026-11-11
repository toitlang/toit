// Copyright (C) 2026 Toit contributors.
//
// Force-included (-include) before the VM's headers when they are parsed by
// frama-clang: completes the few parts of frama-clang's own minimal libc++
// (share/frama-clang/libc++) that src/top.h, src/utils.h and src/objects.h
// use and it only declares. Nothing here is verified; it only lets the
// front end read the real headers.
#pragma once
#include <cstddef>
#include <cstring>
#include <new>
#include <type_traits>
#include <functional>

namespace std {
using ::memcpy;
using ::memmove;
using ::memset;

struct nothrow_t { explicit nothrow_t() = default; };
extern const nothrow_t nothrow;

template <> struct make_unsigned<char> { typedef unsigned char type; };
template <> struct make_unsigned<signed char> { typedef unsigned char type; };
template <> struct make_unsigned<unsigned char> { typedef unsigned char type; };
template <> struct make_unsigned<const char> { typedef const unsigned char type; };
template <> struct make_unsigned<const unsigned char> { typedef const unsigned char type; };
template <> struct make_unsigned<short> { typedef unsigned short type; };
template <> struct make_unsigned<unsigned short> { typedef unsigned short type; };
template <> struct make_unsigned<int> { typedef unsigned int type; };
template <> struct make_unsigned<unsigned int> { typedef unsigned int type; };
template <> struct make_unsigned<long> { typedef unsigned long type; };
template <> struct make_unsigned<unsigned long> { typedef unsigned long type; };
template <> struct make_unsigned<long long> { typedef unsigned long long type; };
template <> struct make_unsigned<unsigned long long> { typedef unsigned long long type; };

template <class T> struct is_trivially_copyable
    : integral_constant<bool, __is_trivially_copyable(T)> { };
template <class T> struct is_trivial
    : integral_constant<bool, __is_trivial(T)> { };

// A stand-in with the interface utils.h uses (construction from a callable,
// call): enough to parse, not a model of std::function.
template <class R, class... A> class function<R(A...)> {
 public:
  function() { }
  template <class F> function(F) { }
  R operator()(A...) const;
  explicit operator bool() const { return true; }
};
}  // namespace std

void* operator new(std::size_t size, const std::nothrow_t&) noexcept;
void* operator new[](std::size_t size, const std::nothrow_t&) noexcept;
