// Copyright (C) 2026 Toit contributors.

/**
Splits $str on runs of whitespace, dropping empty tokens.

Invalid Unicode runes are ignored. ELF tools emit ASCII, but their output is
  external input and should not make a parser fail with a nullable-rune error.
*/
split-whitespace str/string -> List:
  result := []
  current := []
  str.do: | c/int? |
    if not c: continue.do
    if c == ' ' or c == '\t' or c == '\r' or c == '\n':
      if not current.is-empty:
        result.add (string.from-runes current)
        current = []
    else:
      current.add c
  if not current.is-empty:
    result.add (string.from-runes current)
  return result
