// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Hamming code.

See https://en.wikipedia.org/wiki/Hamming_code
*/

ONE_COUNT_ ::= [0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4, 1, 2, 2, 3, 2, 3, 3, 4, 2, 3, 3, 4, 3, 4, 4, 5]

count_ones_ x:
  total := 0
  while x > 0:
    total += ONE_COUNT_[x & 0x1f]
    x >>= 5
  return total

/**
Encodes an 11-bit integer as a 16-bit integer with error correction bits.

Use $fix_16_11 to check for errors and get the number back.
*/
encode_16_11 in:
  assert: in < (1 << 11)
  assert: in >= 0
  spaced_out := ((in & 1) << 2) | ((in & 0xe) << 3) | ((in & 0x7f0) << 4)
  p1 := (count_ones_ in & 0x55b) & 1
  p2 := (count_ones_ in & 0x66d) & 1
  p4 := (count_ones_ in & 0x78e) & 1
  p8 := (count_ones_ in & 0x7f0) & 1
  p_all := ((count_ones_ in) + p1 + p2 + p4 + p8) & 1
  return spaced_out | p1 | (p2 << 1) | (p4 << 3) | (p8 << 7) | (p_all << 15)

/**
Checks the given $in for possible errors.

Detects up to 2-bits error and corrects all 1-bit errors.

The $in is a 16-bit number with possible errors.

Returns the corrected 11-bit number if there was no error or error correction
  was possible.
Returns null otherwise.
*/
fix_16_11 in:
  p1 := (count_ones_ in & 0x5555) & 1
  p2 := (count_ones_ in & 0x6666) & 1
  p4 := (count_ones_ in & 0x7878) & 1
  p8 := (count_ones_ in & 0x7f80) & 1
  p_all := (count_ones_ in) & 1
  parity_sum := p1 + p2 + p4 + p8
  // Check for no errors, or only an error in the parity-all bit.
  if parity_sum == 0:
    return extract_11_ in
  // Check for one of the parity bits being in error, but everything else is OK.
  if parity_sum == 1 and p_all == 1:
    return extract_11_ in
  // Check for one correctable error.
  if p_all == 1:
    error_position := p1 + (p2 << 1) + (p4 << 2) + (p8 << 3) - 1
    wrong_bit := 1 << error_position
    return extract_11_ in ^ wrong_bit
  // Two bit errors.  We can't correct this.
  return null

extract_11_ in:
  return ((in & 4) >> 2) | ((in & 0x70) >> 3) | ((in & 0x7f00) >> 4)
