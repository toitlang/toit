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
      : position_or_use_count_(-1)
      , first_uses_()
      , height_(-1) {}

  bool is_bound() const { return _has_position(); }

  int position() const {
    ASSERT(is_bound());
    return _decode_position(position_or_use_count_);
  }

  void bind(int position, int height) {
    ASSERT(!is_bound());
    position_or_use_count_ = _encode_position(position);
    ASSERT(is_bound());

    ASSERT(height_ == -1 || height_ == height);
    height_ = height;
    ASSERT(height_ >= 0);
  }

  int uses() const {
    ASSERT(!_has_position());
    return _decode_use_count(position_or_use_count_);
  }

  int use_at(int n) const {
    ASSERT(n >= 0 && n < uses());
    ASSERT(n < uses());
    int result = (n < _FIRST_USES_SIZE)
        ? first_uses_[n]
        : additional_uses_[n - _FIRST_USES_SIZE];
    return result;
  }

  void use(int position, int height);

 private:
  static const int _FIRST_USES_SIZE = 4;

  int position_or_use_count_;
  int first_uses_[_FIRST_USES_SIZE];

  std::vector<int> additional_uses_;

  // The height can be set at use-site or bind-site. The other side always
  // checks that the height agrees.
  int height_;

  bool _has_position() const { return position_or_use_count_ >= 0; }

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
      : position_(-relative_position) {}

  bool has_relative_position() const { return position_ <= 0; }
  bool has_absolute_position() const { return !has_relative_position(); }

  void make_absolute(int absolute_entry_bci) {
    ASSERT(has_relative_position());
    int relative_position = -position_;
    position_ = absolute_entry_bci + relative_position;
  }

  int absolute_position() const {
    ASSERT(has_absolute_position());
    return position_;
  }

 private:
  int position_;
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
      : relative_position_(relative_position)
      , absolute_uses_(absolute_uses) {}

  void free_absolute_uses() {
    for (auto use : absolute_uses_) { delete use; }
    absolute_uses_.clear();
  }

  int absolute_position(int absolute_entry_bci) {
    return absolute_entry_bci + relative_position_;

  }

  List<AbsoluteUse*> absolute_uses() const { return absolute_uses_; }

 private:
  int relative_position_;
  List<AbsoluteUse*> absolute_uses_;

  friend class ListBuilder<AbsoluteReference>;
  AbsoluteReference() {}
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
    absolute_uses_.push_back(result);
    return result;
  }

  bool has_absolute_uses() const { return !absolute_uses_.empty(); }

  AbsoluteReference build_absolute_reference() const {
    ASSERT(is_bound());
    return AbsoluteReference(position(),
                             ListBuilder<AbsoluteUse*>::build_from_vector(absolute_uses_));
  }

 private:
  std::vector<AbsoluteUse*> absolute_uses_;
};

} // namespace toit::compiler
} // namespace toit
