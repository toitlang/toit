import encoding.tison
main:
  marker := (tison.encode null)[..4]
  depth := 1_000_000
  payload := ByteArray depth * 2 + 1: it == depth * 2 ? 3 : (it % 2 == 0 ? 6 : 1)
  size := payload.size
  card := []
  while size >= 128:
    card.add (size & 0x7f) | 0x80
    size >>= 7
  card.add size
  e := catch: tison.decode marker + (ByteArray card.size: card[it]) + payload
  print "survived: $e"
