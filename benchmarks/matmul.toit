// Provenance: Written for this project.

make n/int seed/float -> List:
  return List n: | i | List n: | j | (i * j + seed) / n

mul n/int a/List b/List -> List:
  c := List n: List n: 0.0
  n.repeat: | i |
    ai/List := a[i]
    ci/List := c[i]
    n.repeat: | k |
      aik/float := ai[k]
      bk/List := b[k]
      n.repeat: | j |
        ci[j] = (ci[j] as float) + aik * (bk[j] as float)
  return c

main:
  n := 200
  c := mul n (make n 1.0) (make n 2.0)
  print (c[n / 2] as List)[n / 3]
