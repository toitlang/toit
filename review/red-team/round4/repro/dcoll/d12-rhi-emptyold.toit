// Copyright (C) 2026 Toit contributors.

array-at-put_ a i v: #primitive.core.array_at_put
array-at_ a i: #primitive.core.array_at
array-new_ n f: #primitive.core.array_new
array-expand_ a from to filler: #primitive.core.array_expand
array-replace_ dst di src sf st: #primitive.core.array_replace
array-length_ a: #primitive.core.array_length
rebuild-hash-index_ o n: #primitive.core.rebuild_hash_index
blit_ dst dps dls src sps sls ppl lut shift mask op: #primitive.bitmap.blit
string-slice_ s from to: #primitive.core.string_slice
ba-replace_ dst di src sf st: #primitive.core.byte_array_replace

main:
  old := array-new_ 0 0
  nw := array-new_ 4 0
  print (catch: rebuild-hash-index_ old nw)
