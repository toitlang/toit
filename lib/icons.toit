// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .font

class Icon:
  code_point_/int ::= ?
  font_/Font ::= ?

  constructor .code_point_ .font_:

  stringify -> string:
    return "$(%c code_point_)"

  /**
  Gets the pixel width of the icon.
  Note that when you actually draw the icon it may go a few pixels to the left
    of the origin or to the right of x origin + pixel_width.  See $icon_extent.
  */
  pixel_width -> int:
    return font_.pixel_width stringify

  /**
  Gets the bounding box of the icon.
  Returns [width, height, x-offset, y-offset].
  */
  icon_extent -> List:
    return font_.text_extent stringify
