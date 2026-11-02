// Provenance: Written for this project from the description of the spectral-norm task in the
// Computer Language Benchmarks Game, https://benchmarksgame-team.pages.debian.net/.

eval-a i/int j/int -> float:
  return 1.0 / ((i + j) * (i + j + 1) / 2 + i + 1).to-float

times-a n/int v/List out/List:
  n.repeat: | i |
    s := 0.0
    for j := 0; j < n; j++: s += (eval-a i j) * (v[j] as float)
    out[i] = s

times-at n/int v/List out/List:
  n.repeat: | i |
    s := 0.0
    for j := 0; j < n; j++: s += (eval-a j i) * (v[j] as float)
    out[i] = s

main:
  n := 400
  u := List n: 1.0
  v := List n: 0.0
  tmp := List n: 0.0
  10.repeat:
    times-a n u tmp
    times-at n tmp v
    times-a n v tmp
    times-at n tmp u
  vbv := 0.0
  vv := 0.0
  n.repeat:
    vbv += (u[it] as float) * (v[it] as float)
    vv += (v[it] as float) * (v[it] as float)
  print (vbv / vv).sqrt
