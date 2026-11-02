// Provenance: Written for this project.

main:
  total := 0
  200.repeat: | r |
    parts := []
    2000.repeat: parts.add "item-$it-$r"
    joined := parts.join ","
    split := joined.split ","
    split.do: total += it.size
    total += (joined.index-of "item-1999")
    total += joined.to-byte-array.size
  print total
