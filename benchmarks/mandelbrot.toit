// Provenance: Written for this project from the description of the mandelbrot task in the
// Computer Language Benchmarks Game, https://benchmarksgame-team.pages.debian.net/.

main:
  size := 480
  sum := 0
  size.repeat: | y |
    ci := 2.0 * y / size - 1.0
    bits := 0
    size.repeat: | x |
      cr := 2.0 * x / size - 1.5
      zr := 0.0
      zi := 0.0
      i := 0
      while i < 50 and zr * zr + zi * zi <= 4.0:
        t := zr * zr - zi * zi + cr
        zi = 2.0 * zr * zi + ci
        zr = t
        i++
      bits = ((bits << 1) | (i == 50 ? 1 : 0)) & 0xff
      if x & 7 == 7: sum = (sum * 31 + bits) & 0xffffff
  print sum
