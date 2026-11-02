// Provenance: Written for this project. Not a port: it is inspired by crypto.js in
// the Octane suite, which uses Tom Wu's BigInteger library, and shares no code with it.

BITS ::= 28
MASK ::= (1 << BITS) - 1

// Computes x * y mod m with schoolbook multiplication and shift-subtract reduction.
mul-mod x/List y/List m/List n/int -> List:
  r := List 2 * n + 1: 0
  n.repeat: | i |
    carry := 0
    xi/int := x[i]
    n.repeat: | j |
      t := (r[i + j] as int) + xi * (y[j] as int) + carry
      r[i + j] = t & MASK
      carry = t >> BITS
    r[i + n] = (r[i + n] as int) + carry
  // Montgomery-free reduction, word by word.
  top/int := m[n - 1]
  for i := 2 * n - 1; i >= n; i--:
    q := ((r[i] as int) << BITS | (r[i - 1] as int)) / (top + 1)
    if q != 0:
      borrow := 0
      n.repeat: | j |
        t := (r[i - n + j] as int) - q * (m[j] as int) - borrow
        r[i - n + j] = t & MASK
        borrow = -(t >> BITS)
      r[i] = (r[i] as int) - borrow
  return List n: r[it]

pow-mod base/List exp/List m/List n/int -> List:
  result := List n: it == 0 ? 1 : 0
  for i := n - 1; i >= 0; i--:
    e/int := exp[i]
    for b := BITS - 1; b >= 0; b--:
      result = mul-mod result result m n
      if (e >> b) & 1 != 0: result = mul-mod result base m n
  return result

main:
  n := 18
  seed := 99
  next := :: seed = (seed * 1103515245 + 12345) & 0x7fffffff; seed & MASK
  m := List n: next.call | 1
  m[n - 1] = (m[n - 1] as int) | (1 << (BITS - 1))
  base := List n: next.call
  exp := List n: next.call
  r := List n: 0
  24.repeat:
    r = pow-mod base exp m n
    base = r
  print r[0]
