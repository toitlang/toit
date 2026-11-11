// Copyright (C) 2026 Toit contributors.

crc_ acc width data from to table: #primitive.core.crc
ba2s_ blob from to: #primitive.core.byte_array_convert_to_string
s2utf16_ s: #primitive.core.string_to_utf_16
utf162s_ blob: #primitive.core.utf_16_to_string
fparse_ blob from to blk: #primitive.core.float_parse
iparse_ blob from to blk: #primitive.core.int_parse
f2s_ val prec: #primitive.core.float_to_string
fround_ val prec: #primitive.core.float_round
timeinfo_ ts local: #primitive.core.time_info
secs-local_ y mo d h mi s dst: #primitive.core.seconds_since_epoch_local
rawat_ s i: #primitive.core.string_raw_at
strat_ s i: #primitive.core.string_at
runecount_ blob: #primitive.core.string_rune_count
array-new_ n f: #primitive.core.array_new
array-at-put_ a i v: #primitive.core.array_at_put
try_ name/string [fn]:
  e := catch: fn.call
  print "F $name: $(e ? "threw $e" : "ok")"

main:
  try_ "utf162s-odd": print (utf162s_ #[0x41,0x00,0x42]).size
  print "F-DONE"
