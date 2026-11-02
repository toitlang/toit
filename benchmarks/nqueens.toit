// Provenance: Written for this project.

solve n/int row/int cols/List d1/List d2/List -> int:
  if row == n: return 1
  count := 0
  n.repeat: | col |
    a := row + col
    b := row - col + n
    if not (cols[col] or d1[a] or d2[b]):
      cols[col] = true
      d1[a] = true
      d2[b] = true
      count += solve n row + 1 cols d1 d2
      cols[col] = false
      d1[a] = false
      d2[b] = false
  return count

main:
  n := 12
  print (solve n 0 (List n: false) (List 2 * n: false) (List 2 * n: false))
