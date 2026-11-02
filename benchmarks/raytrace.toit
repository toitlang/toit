// Provenance: Written for this project. Not a port: it is inspired by raytrace.js
// in the Octane suite (https://github.com/chromium/octane) and shares no code with it.

class Vec:
  x/float
  y/float
  z/float
  constructor .x .y .z:
  operator + o/Vec -> Vec: return Vec (x + o.x) (y + o.y) (z + o.z)
  operator - o/Vec -> Vec: return Vec (x - o.x) (y - o.y) (z - o.z)
  scale s/float -> Vec: return Vec (x * s) (y * s) (z * s)
  dot o/Vec -> float: return x * o.x + y * o.y + z * o.z
  length -> float: return (dot this).sqrt
  normal -> Vec: return scale (1.0 / length)

class Ray:
  origin/Vec
  direction/Vec
  constructor .origin .direction:

class Hit:
  distance/float
  shape/Shape
  constructor .distance .shape:

abstract class Shape:
  color/Vec
  reflection/float
  constructor .color .reflection:
  abstract intersect ray/Ray -> float?
  abstract normal-at p/Vec -> Vec

class Sphere extends Shape:
  center/Vec
  radius/float
  constructor .center .radius color/Vec reflection/float:
    super color reflection
  intersect ray/Ray -> float?:
    oc := ray.origin - center
    b := oc.dot ray.direction
    c := (oc.dot oc) - radius * radius
    d := b * b - c
    if d <= 0.0: return null
    t := -b - d.sqrt
    return t > 0.0001 ? t : null
  normal-at p/Vec -> Vec: return (p - center).normal

class Plane extends Shape:
  n/Vec
  d/float
  constructor .n .d color/Vec reflection/float:
    super color reflection
  intersect ray/Ray -> float?:
    denom := n.dot ray.direction
    if denom > -0.0001 and denom < 0.0001: return null
    t := -((n.dot ray.origin) + d) / denom
    return t > 0.0001 ? t : null
  normal-at p/Vec -> Vec: return n

closest shapes/List ray/Ray -> Hit?:
  best/Hit? := null
  shapes.do: | shape/Shape |
    t := shape.intersect ray
    if t and (not best or t < best.distance): best = Hit t shape
  return best

trace shapes/List ray/Ray light/Vec depth/int -> Vec:
  hit := closest shapes ray
  if not hit: return Vec 0.0 0.0 0.0
  p := ray.origin + (ray.direction.scale hit.distance)
  n := hit.shape.normal-at p
  l := (light - p).normal
  diffuse := n.dot l
  if diffuse < 0.0: diffuse = 0.0
  if closest shapes (Ray p l): diffuse *= 0.5
  color := hit.shape.color.scale (0.2 + 0.8 * diffuse)
  if depth > 0 and hit.shape.reflection > 0.0:
    r := ray.direction - (n.scale 2.0 * (ray.direction.dot n))
    color = color + ((trace shapes (Ray p r) light depth - 1).scale hit.shape.reflection)
  return color

main:
  shapes := [
    Plane (Vec 0.0 1.0 0.0) 0.0 (Vec 0.4 0.4 0.4) 0.3,
    Sphere (Vec 0.0 1.0 0.0) 1.0 (Vec 0.9 0.2 0.2) 0.4,
    Sphere (Vec 2.0 0.7 1.0) 0.7 (Vec 0.2 0.9 0.2) 0.2,
    Sphere (Vec -2.0 0.5 -1.0) 0.5 (Vec 0.2 0.2 0.9) 0.5,
  ]
  light := Vec 5.0 8.0 -5.0
  camera := Vec 0.0 2.0 -6.0
  sum := 0.0
  size := 320
  size.repeat: | y |
    size.repeat: | x |
      d := (Vec (x - size / 2.0) / size (size / 2.0 - y) / size 1.0).normal
      c := trace shapes (Ray camera d) light 3
      sum += c.x + c.y + c.z
  print sum.to-int
