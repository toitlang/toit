// Provenance: Written for this project from the description of the fannkuch-redux task in the
// Computer Language Benchmarks Game, https://benchmarksgame-team.pages.debian.net/.

fannkuch n/int -> List:
  perm := List n: 0
  perm1 := List n: it
  count := List n: 0
  max-flips := 0
  checksum := 0
  r := n
  nperm := 0
  while true:
    while r != 1:
      count[r - 1] = r
      r--
    n.repeat: perm[it] = perm1[it]
    flips := 0
    k := perm[0]
    while k != 0:
      i := 0
      j := k
      while i < j:
        t := perm[i]
        perm[i] = perm[j]
        perm[j] = t
        i++
        j--
      flips++
      k = perm[0]
    if flips > max-flips: max-flips = flips
    checksum += (nperm & 1) == 0 ? flips : -flips
    while true:
      if r == n: return [checksum, max-flips]
      first := perm1[0]
      i := 0
      while i < r:
        perm1[i] = perm1[i + 1]
        i++
      perm1[r] = first
      count[r]--
      if count[r] > 0: break
      r++
    nperm++

main:
  print (fannkuch 9)
