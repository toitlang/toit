// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import i2s

// A prime period distinguishes the EC618's 64-frame DMA boundaries from a
// restart/replay. Each channel is unique within the cycle, including at 8 bits.
PERIOD ::= 251
// Clock-start training is separate from the measured sequence. Frame sync may
// be acquired after the first training frame in either clock role; no pattern
// frame may go missing. Eight frames reject loss beyond that boundary.
TRAINING-FRAMES ::= 8

pattern bits/int --slots/int=i2s.Bus.SLOTS-STEREO-BOTH --inverted/bool=false -> ByteArray:
  if not [8, 16, 24, 32].contains bits: throw "INVALID_ARGUMENT"
  if not 0 <= slots <= i2s.Bus.SLOTS-MONO-RIGHT:
    throw "INVALID_ARGUMENT"
  bytes := bits / 8
  channels := slots <= i2s.Bus.SLOTS-STEREO-RIGHT ? 2 : 1
  return ByteArray (PERIOD * channels * bytes): |offset/int|
    frame := offset / (channels * bytes)
    right := slots == i2s.Bus.SLOTS-MONO-RIGHT or (channels == 2 and (offset / bytes) % 2 == 1)
    value := right
        ? 0xe3ba9876 ^ (((frame * 73 + 19) % PERIOD) * 0x01010101)
        : 0x81234567 ^ (frame * 0x01010101)
    ((value >> (8 * (offset % bytes))) & 0xff) ^ (inverted ? 0xff : 0)

// Expected physical stereo frames, independently of the sender's compact
// buffer layout. Inactive slots remain zero even for inverted test data.
wire-pattern bits/int slots/int --inverted/bool=false -> ByteArray:
  if not 0 <= slots <= i2s.Bus.SLOTS-MONO-RIGHT: throw "INVALID_ARGUMENT"
  stereo := pattern bits --inverted=inverted
  sample-bytes := bits / 8
  return ByteArray stereo.size: |offset/int|
    right := (offset / sample-bytes) % 2 == 1
    if right and [i2s.Bus.SLOTS-STEREO-LEFT, i2s.Bus.SLOTS-MONO-LEFT].contains slots:
      continue.ByteArray 0
    if not right and [i2s.Bus.SLOTS-STEREO-RIGHT, i2s.Bus.SLOTS-MONO-RIGHT].contains slots:
      continue.ByteArray 0
    source := right and slots == i2s.Bus.SLOTS-MONO-BOTH ? offset - sample-bytes : offset
    stereo[source]

/**
Checks complete compact frames against the continuous source sequence.

Never resynchronizes after selecting the initial phase. Stores 16 copies of
  the expected 251-frame cycle to amortize comparison overhead during streaming.
*/
class SequenceVerifier:
  expected_/ByteArray
  frame-size_/int
  position_/int := -1
  checked-bytes/int := 0

  constructor bits/int --slots/int=i2s.Bus.SLOTS-STEREO-BOTH --inverted/bool=false
      --start-frame/int?=null --wire-slots/int?=null:
    expected_ = wire-slots == null
        ? (pattern bits --slots=slots --inverted=inverted)
        : (wire-pattern bits wire-slots --inverted=inverted)
    frame-size_ = expected_.size / PERIOD
    // Keep the same periodic byte sequence, but compare larger contiguous
    // spans per primitive instead of splitting every read at 251 frames.
    cycle := expected_
    expected_ = ByteArray (cycle.size * 16)
    16.repeat: expected_.replace (it * cycle.size) cycle
    if start-frame != null:
      if not 0 <= start-frame < PERIOD: throw "INVALID_ARGUMENT"
      position_ = start-frame * frame-size_

  accept buffer/ByteArray count/int -> none:
    if count <= 0 or count > buffer.size or count % frame-size_ != 0:
      throw "Invalid I2S read length: $count"
    if position_ < 0:
      // The receiver may start at any source frame, but every following byte
      // must be contiguous. Never resynchronize after a mismatch.
      PERIOD.repeat: |frame/int|
        start := frame * frame-size_
        if buffer[..frame-size_] == expected_[start..start + frame-size_]:
          position_ = start
      if position_ < 0: throw "Invalid initial I2S frame: $(buffer[..frame-size_])"
    offset := 0
    while offset < count:
      n := min (count - offset) (expected_.size - position_)
      if buffer[offset..offset + n] != expected_[position_..position_ + n]:
        delta := 0
        while delta < n and buffer[offset + delta] == expected_[position_ + delta]: delta++
        actual := buffer[offset + delta..min count (offset + delta + 16)]
        wanted := expected_[position_ + delta..min expected_.size (position_ + delta + 16)]
        throw "I2S sequence mismatch at byte $(checked-bytes + offset + delta), phase=$(position_ + delta), expected=$wanted actual=$actual"
      offset += n
      position_ = (position_ + n) % expected_.size
    checked-bytes += count

/**
Checks bounded startup training followed by sequence frame zero onward.

The optional first-frame and extra-training allowances are for explicitly
  bounded peer startup behavior. Using them does not qualify first-frame fidelity.
  Payload always starts at frame zero and every payload byte is checked.
*/
class TrainingSequenceVerifier:
  sequence_/SequenceVerifier
  zero_/ByteArray
  minimum_/int
  maximum_/int
  allow-partial-first_/bool
  started_/bool := false
  training-frames/int := 0
  initial-frame/ByteArray? := null

  constructor bits/int --slots/int=i2s.Bus.SLOTS-STEREO-BOTH
      --inverted/bool=false --wire-slots/int?=null
      --allow-partial-first/bool=false --startup-extra/int=0
      --minimum-training/int=(TRAINING-FRAMES - 1):
    if not 0 <= minimum-training <= TRAINING-FRAMES: throw "INVALID_ARGUMENT"
    if not 0 <= startup-extra <= 1: throw "INVALID_ARGUMENT"
    minimum_ = minimum-training
    maximum_ = TRAINING-FRAMES + startup-extra
    allow-partial-first_ = allow-partial-first
    zero_ = ByteArray (bits / 8 * (wire-slots != null or slots == i2s.Bus.SLOTS-STEREO-BOTH ? 2 : 1))
    sequence_ = SequenceVerifier bits --slots=slots --start-frame=0
        --wire-slots=wire-slots
        --inverted=inverted

  checked-bytes -> int: return sequence_.checked-bytes

  accept buffer/ByteArray count/int -> none:
    if count <= 0 or count > buffer.size or count % zero_.size != 0:
      throw "Invalid I2S training read length: $count"
    offset := 0
    while not started_ and offset < count:
      // Sustained-only qualification may ignore exactly the first physical
      // frame. It still requires bounded zero training and payload frame zero.
      if allow-partial-first_ and not initial-frame:
        initial-frame = buffer[..zero_.size].copy
        // A partial nonzero frame precedes the training; it is not one of
        // the zero frames. Count a complete zero first frame normally.
        if initial-frame == zero_: training-frames++
        offset += zero_.size
        continue
      if buffer[offset..offset + zero_.size] == zero_:
        training-frames++
        if training-frames > maximum_: throw "Extra I2S training frame"
        offset += zero_.size
      else:
        if training-frames < minimum_: throw "Missing I2S training frames: $training-frames"
        started_ = true
    if offset < count:
      data := buffer[offset..count]
      sequence_.accept data data.size

  finish -> none:
    if not started_ or checked-bytes == 0: throw "Missing I2S pattern sequence"
