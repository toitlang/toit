// Copyright (C) 2020 Toitware ApS.
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

#include <vector>

#include "../top.h"

#include "ast.h"
#include "list.h"

namespace toit {
namespace compiler {

class Label {
 public:
  Label()
      : _position_or_use_count(-1)
      , _first_uses()
      , _height(-1) { }

  bool is_bound() const { return _has_position(); }

  int position() const {
    ASSERT(is_bound());
    return _decode_position(_position_or_use_count);
  }

  void bind(int position, int height) {
    ASSERT(!is_bound());
    _position_or_use_count = _encode_position(position);
    ASSERT(is_bound());

    ASSERT(_height == -1 || _height == height);
    _height = height;
    ASSERT(_height >= 0);
  }

  int uses() const {
    ASSERT(!_has_position());
    return _decode_use_count(_position_or_use_count);
  }

  int use_at(int n) const {
    ASSERT(n >= 0 && n < uses());
    ASSERT(n < uses());
    int result = (n < _FIRST_USES_SIZE)
        ? _first_uses[n]
        : _additional_uses[n - _FIRST_USES_SIZE];
    return result;
  }

  void use(int position, int height);

 private:
  static const int _FIRST_USES_SIZE = 4;

  int _position_or_use_count;
  int _first_uses[_FIRST_USES_SIZE];

  std::vector<int> _additional_uses;

  // The height can be set at use-site or bind-site. The other side always
  // checks that the height agrees.
  int _height;

  bool _has_position() const { return _position_or_use_count >= 0; }

  static int _encode_position(int position) { return position; }
  static int _encode_use_count(int use_count) { return -use_count - 1; }
  static int _decode_position(int encoded_position) {
    ASSERT(encoded_position >= 0);
    return encoded_position;
  }
  static int _decode_use_count(int encoded_use_count) {
    ASSERT(encoded_use_count < 0);
    return -encoded_use_count - 1;
  }
};

/// Absolute uses are uses that need the absolute position of a label.
///
/// The `AbsoluteUse` class works together with `AbsoluteLabel`s.
/// The use points to the location within the bytestream, where
///   an absolute reference is needed.
///
/// An absolute-use instance starts out with a position relative to the
///   beginning of the bytestream. It is later updated to an absolute
///   position (in the whole bytestream) when the surrounding method
///   is finalized.
///
/// Later, when the surrounding method of the label is finalized,
///   all locations of the label's absolute uses (which must now be
///   absolute) are updated.
///
/// An absolute use thus goes through 3 states:
///   1. with a position that is relative to the surrounding
///   2. with a global position
///   3. used to update the bytes with an absolute position.
class AbsoluteUse {
 public:
  AbsoluteUse(int relative_position)
      : _position(-relative_position) { }

  bool has_relative_position() const { return _position <= 0; }
  bool has_absolute_position() const { return !has_relative_position(); }

  void make_absolute(int absolute_entry_bci) {
    ASSERT(has_relative_position());
    int relative_position = -_position;
    _position = absolute_entry_bci + relative_position;
  }

  int absolute_position() const {
    ASSERT(has_absolute_position());
    return _position;
  }

 private:
  int _position;
};

/// Represents a pointer into the code.
///
/// The reference has a position relative to the beginning of the current function.
/// The reference has a list of all absolute uses of this reference.
///
/// Note that the reference never has an absolute position, as we immediately
///   update all uses, as soon as we know the absolute position.
class AbsoluteReference {
 public:
  AbsoluteReference(int relative_position,
                    List<AbsoluteUse*> absolute_uses)
      : _relative_position(relative_position)
      , _absolute_uses(absolute_uses) { }

  void free_absolute_uses() {
    for (auto use : _absolute_uses) { delete use; }
    _absolute_uses.clear();
  }

  int absolute_position(int absolute_entry_bci) {
    return absolute_entry_bci + _relative_position;

  }

  List<AbsoluteUse*> absolute_uses() const { return _absolute_uses; }

 private:
  int _relative_position;
  List<AbsoluteUse*> _absolute_uses;

  friend class ListBuilder<AbsoluteReference>;
  AbsoluteReference() { }
};

/// Represents a label that can be used as a target for a non-local branch.
///
/// The absolute-label extends the "normal" Label class, which is thus
///   eventually bound to a relative (to the surrounding function) position.
///
/// Once bound, we extract an `AbsoluteReference` out of the label (since we
///   don't need the remaining fields anymore). These references are collected
///   until the function is finalized. At that point the relative position of the
///   reference can be converted to an absolute position.
/// The absolute position is then used to fix all uses.
class AbsoluteLabel : public Label {
 public:
  AbsoluteUse* use_absolute(int relative_position) {
    auto result = _new AbsoluteUse(relative_position);
    _absolute_uses.push_back(result);
    return result;
  }

  bool has_absolute_uses() const { return !_absolute_uses.empty(); }

  AbsoluteReference build_absolute_reference() const {
    ASSERT(is_bound());
    return AbsoluteReference(position(),
                             ListBuilder<AbsoluteUse*>::build_from_vector(_absolute_uses));
  }

 private:
  std::vector<AbsoluteUse*> _absolute_uses;
};

} // namespace toit::compiler
} // namespace toit
