// Provenance: Ported to Toit from navier-stokes.js in the Octane benchmark suite,
// https://github.com/chromium/octane, including its checksum. The fluid solver
// is by Oliver Hunt. The original license follows.
//
// Copyright 2013 the V8 project authors. All rights reserved.
// Copyright 2009 Oliver Hunt <http://nerget.com>
// 
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use,
// copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following
// conditions:
// 
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.
// 
// Update 10/21/2013: fixed loop variables at line 119

class FluidField:
  width/int
  height/int
  row-size/int
  size/int
  iterations/int
  dt/float := 0.1
  dens/List
  dens-prev/List
  u/List
  u-prev/List
  v/List
  v-prev/List
  frames-till-adding-points := 0
  frames-between-adding-points := 5

  constructor .width .height .iterations:
    row-size = width + 2
    size = (width + 2) * (height + 2)
    dens = List size: 0.0
    dens-prev = List size: 0.0
    u = List size: 0.0
    u-prev = List size: 0.0
    v = List size: 0.0
    v-prev = List size: 0.0

  add-fields x/List s/List -> none:
    size.repeat: x[it] = (x[it] as float) + dt * (s[it] as float)

  set-bnd b/int x/List -> none:
    r := row-size
    for i := 1; i <= width; i++:
      x[i] = b == 2 ? -(x[i + r] as float) : x[i + r]
      x[i + (height + 1) * r] = b == 2 ? -(x[i + height * r] as float) : x[i + height * r]
    for j := 1; j <= height; j++:
      x[j * r] = b == 1 ? -(x[1 + j * r] as float) : x[1 + j * r]
      x[(width + 1) + j * r] = b == 1 ? -(x[width + j * r] as float) : x[width + j * r]
    max-edge := (height + 1) * r
    x[0] = 0.5 * ((x[1] as float) + (x[r] as float))
    x[max-edge] = 0.5 * ((x[1 + max-edge] as float) + (x[height * r] as float))
    x[width + 1] = 0.5 * ((x[width] as float) + (x[(width + 1) + r] as float))
    x[(width + 1) + max-edge] = 0.5 * ((x[width + max-edge] as float) + (x[(width + 1) + height * r] as float))

  copy-field x/List x0/List -> none:
    for j := 1; j <= height; j++:
      row := j * row-size
      for i := 1; i <= width; i++: x[row + i] = x0[row + i]

  lin-solve b/int x/List x0/List a/float c/float -> none:
    inv-c := 1.0 / c
    iterations.repeat:
      for j := 1; j <= height; j++:
        k := j * row-size
        last-x/float := x[k]
        k++
        for i := 1; i <= width; i++:
          last-x = ((x0[k] as float) + a * (last-x + (x[k + 1] as float) + (x[k - row-size] as float) + (x[k + row-size] as float))) * inv-c
          x[k] = last-x
          k++
      set-bnd b x

  advect b/int d/List d0/List u/List v/List -> none:
    wdt0 := dt * width
    hdt0 := dt * height
    wp5 := width + 0.5
    hp5 := height + 0.5
    for j := 1; j <= height; j++:
      pos := j * row-size
      for i := 1; i <= width; i++:
        pos++
        x/float := i - wdt0 * (u[pos] as float)
        y/float := j - hdt0 * (v[pos] as float)
        if x < 0.5: x = 0.5
        else if x > wp5: x = wp5
        i0 := x.to-int
        i1 := i0 + 1
        if y < 0.5: y = 0.5
        else if y > hp5: y = hp5
        j0 := y.to-int
        j1 := j0 + 1
        s1 := x - i0
        s0 := 1.0 - s1
        t1 := y - j0
        t0 := 1.0 - t1
        row1 := j0 * row-size
        row2 := j1 * row-size
        d[pos] = s0 * (t0 * (d0[i0 + row1] as float) + t1 * (d0[i0 + row2] as float)) + s1 * (t0 * (d0[i1 + row1] as float) + t1 * (d0[i1 + row2] as float))
    set-bnd b d

  project u/List v/List p/List div/List -> none:
    h := -0.5 / (width * height).to-float.sqrt
    for j := 1; j <= height; j++:
      row := j * row-size
      for i := 1; i <= width; i++:
        k := row + i
        div[k] = h * ((u[k + 1] as float) - (u[k - 1] as float) + (v[k + row-size] as float) - (v[k - row-size] as float))
        p[k] = 0.0
    set-bnd 0 div
    set-bnd 0 p
    lin-solve 0 p div 1.0 4.0
    w-scale := 0.5 * width
    h-scale := 0.5 * height
    for j := 1; j <= height; j++:
      row := j * row-size
      for i := 1; i <= width; i++:
        k := row + i
        u[k] = (u[k] as float) - w-scale * ((p[k + 1] as float) - (p[k - 1] as float))
        v[k] = (v[k] as float) - h-scale * ((p[k + row-size] as float) - (p[k - row-size] as float))
    set-bnd 1 u
    set-bnd 2 v

  dens-step x/List x0/List u/List v/List -> none:
    add-fields x x0
    copy-field x0 x
    set-bnd 0 x0
    advect 0 x x0 u v

  vel-step u/List v/List u0/List v0/List -> none:
    add-fields u u0
    add-fields v v0
    copy-field u0 u
    copy-field v0 v
    set-bnd 1 u0
    set-bnd 2 v0
    project u0 v0 u v
    copy-field u u0
    copy-field v v0
    advect 1 u u0 u0 v0
    advect 2 v v0 u0 v0
    project u v u0 v0

  set-point x/int y/int xv/int yv/int d/float -> none:
    k := (x + 1) + (y + 1) * row-size
    u-prev[k] = xv.to-float
    v-prev[k] = yv.to-float
    dens-prev[k] = d

  add-points -> none:
    n := 64
    for i := 1; i <= n; i++:
      set-point i i n n 5.0
      set-point i (n - i) -n -n 20.0
      set-point (128 - i) (n + i) -n -n 30.0

  prepare-frame -> none:
    if frames-till-adding-points == 0:
      add-points
      frames-till-adding-points = frames-between-adding-points
      frames-between-adding-points++
    else:
      frames-till-adding-points--

  update -> none:
    size.repeat:
      u-prev[it] = 0.0
      v-prev[it] = 0.0
      dens-prev[it] = 0.0
    prepare-frame
    vel-step u v u-prev v-prev
    dens-step dens dens-prev u v

main:
  solver := FluidField 128 128 20
  15.repeat: solver.update
  result := 0
  for i := 7000; i < 7100; i++:
    result += ((solver.dens[i] as float) * 10.0).to-int
  print result
  if result != 77: throw "checksum failed"
