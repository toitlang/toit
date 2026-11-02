// Provenance: Written for this project from the description of the k-nucleotide task in the
// Computer Language Benchmarks Game, https://benchmarksgame-team.pages.debian.net/.

main:
  seed := 42
  letters := "ACGT"
  buffer := ByteArray 40000
  buffer.size.repeat:
    seed = (seed * 3877 + 29573) % 139968
    buffer[it] = letters[seed & 3]
  text := buffer.to-string
  total := 0
  3.repeat:
    [1, 2, 3, 4, 6].do: | k |
      counts := {:}
      for i := 0; i + k <= text.size; i++:
        key := text[i..i + k]
        counts[key] = (counts.get key --if-absent=(: 0)) + 1
      total += counts.size
  print total
