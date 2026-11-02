// Provenance: Written for this project.

main:
  words := ["the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "pack", "my", "box", "with", "five", "dozen", "liquor", "jugs"]
  seed := 7
  parts := []
  60000.repeat:
    seed = (seed * 1103515245 + 12345) & 0x7fffffff
    parts.add words[(seed >> 16) % words.size]
  text := parts.join " "
  8.repeat:
    counts := {:}
    (text.split " ").do: | word |
      counts[word] = (counts.get word --if-absent=(: 0)) + 1
    sorted := counts.keys.sort
    print "$(sorted[0]) $(counts[sorted[0]])"
