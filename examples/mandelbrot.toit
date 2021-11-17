// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

MAX_PIXEL_VALUE ::= 255

main:
  mandelbrot 200 80 -0.6 0.0 0.015 500
  mandelbrot 200 80 -0.743030 0.126433 0.00003 5000

mandelbrot width height x_center y_center scale limit:
  pixels := List width:
    ByteArray height
  y_scale := scale * 2;
  for y := height - 1; y >= 0; y--:
    for x := 0; x < width; x++:
      pixels[x][y] = do_pixel
          (x - (width >> 1)) * scale + x_center
          (y - (height >> 1)) * y_scale + y_center
          limit
    if y & 1 == 0:
      print_line pixels width y

print_line pixels width y:
  line := ""
  for x := 0; x < width; x += 2:
    top_left     := (color pixels[x    ][y + 1]) ? 0 : 1
    top_right    := (color pixels[x + 1][y + 1]) ? 0 : 2
    bottom_left  := (color pixels[x    ][y    ]) ? 0 : 4
    bottom_right := (color pixels[x + 1][y    ]) ? 0 : 8
    index := top_left + top_right + bottom_left + bottom_right
    line += [" ", "▘", "▝", "▀", "▖", "▌", "▞", "▛", "▗", "▚", "▐", "▜", "▄", "▙", "▟", "█"][index]
  print line

magnitude x y:
  return x * x + y * y > 4.0

color iterations:
  return iterations != 0 and iterations != 2 and iterations != 4 and iterations != MAX_PIXEL_VALUE

do_pixel x y limit:
  i := 0.0
  j := 0.0
  limit.repeat:
    if magnitude i j: return it < MAX_PIXEL_VALUE ? it : MAX_PIXEL_VALUE - 1
    itemp := i * i - j * j + x
    j = 2 * i * j + y
    i = itemp
  return MAX_PIXEL_VALUE
