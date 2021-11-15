// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
See $(line_wrap text max_width [--compute_width] [--can_split] [--is_space]).
  Trims space (0x20) characters around wrap points.
*/
line_wrap text/string max_width/num [--compute_width] [--can_split] -> List:
  return line_wrap text max_width --compute_width=compute_width --can_split=can_split --is_space=:
    it == ' '

/**
Wraps a line of $text to a given $max_width, and returns the
  resulting lines, trimming whitespace characters around wrap points.
  The $compute_width block takes a string, a
  from-position and a to-position (non-inclusive) and returns the width.
  The $can_split block takes a string and a position, and returns true if we
  can split at that point.
  The $is_space block takes an integer code point and returns
  true if it should be trimmed.
*/
line_wrap text/string max_width/num [--compute_width] [--can_split] [--is_space] -> List:
  if text == "": return [ "" ]
  result := []
  last_cut := 0
  while last_cut != text.size:
    ok_place := last_cut
    for i := last_cut + 1; i <= text.size; i++:
      if i != text.size and not text[i]: continue  // Avoid the middle of UTF-8 sequences.
      pixel_width := compute_width.call text last_cut i
      if pixel_width <= max_width and can_split.call text i:
        ok_place = i
      if pixel_width > max_width:
        break
    if ok_place == last_cut:
      // Failed to find a place to split.  This could be because one word is
      // longer than the line width, in which case we will just cut it at the
      // width limit.  We will allow a single-character overlong line in order
      // to be sure to make progress.
      while ok_place < text.size:
        next_cut := ok_place + 1
        // Skip UTF-8.
        while next_cut < text.size and not text[next_cut]: next_cut++
        pixel_width := compute_width.call text last_cut next_cut
        if pixel_width > max_width and ok_place > last_cut:
          break
        ok_place = next_cut
    first_line := text.copy last_cut ok_place
    result.add
      trim_ first_line is_space
    // Trim leading spaces after automatic splits (and thus not at the start of
    // the un-wrapped string).
    while ok_place < text.size and is_space.call text[ok_place]: ok_place++
    last_cut = ok_place
  return result

trim_ text [is_space]:
  end := text.size
  while end > 0:
    if not is_space.call text[end - 1]: return text.copy 0 end
    end--
  return ""
