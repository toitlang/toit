// Provenance: Written for this project from the description of the n-body task in the
// Computer Language Benchmarks Game, https://benchmarksgame-team.pages.debian.net/.

class Body:
  x/float := ?
  y/float := ?
  z/float := ?
  vx/float := ?
  vy/float := ?
  vz/float := ?
  m/float := ?
  constructor .x .y .z .vx .vy .vz .m:

advance bodies/List dt/float:
  n := bodies.size
  for i := 0; i < n; i++:
    a/Body := bodies[i]
    for j := i + 1; j < n; j++:
      b/Body := bodies[j]
      dx := a.x - b.x
      dy := a.y - b.y
      dz := a.z - b.z
      d2 := dx * dx + dy * dy + dz * dz
      mag := dt / (d2 * d2.sqrt)
      a.vx -= dx * b.m * mag
      a.vy -= dy * b.m * mag
      a.vz -= dz * b.m * mag
      b.vx += dx * a.m * mag
      b.vy += dy * a.m * mag
      b.vz += dz * a.m * mag
  bodies.do: | b/Body |
    b.x += dt * b.vx
    b.y += dt * b.vy
    b.z += dt * b.vz

main:
  bodies := [
    Body 0.0 0.0 0.0 0.0 0.0 0.0 39.47,
    Body 4.84 -1.16 -0.10 0.61 2.81 -0.02 0.037,
    Body 8.34 4.12 -0.40 -1.01 1.82 0.008 0.011,
    Body 12.89 -15.11 -0.22 1.08 0.86 -0.01 0.0017,
    Body 15.37 -25.91 0.17 0.97 0.59 -0.03 0.002,
  ]
  100000.repeat: advance bodies 0.01
  print (bodies[0] as Body).x
