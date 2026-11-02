// Provenance: Written for this project.

crc-table -> List:
  return List 256: | i |
    c := i
    8.repeat: c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1
    c

main:
  table := crc-table
  data := ByteArray 65536: (it * 31 + (it >> 3)) & 0xff
  crc := 0xffffffff
  300.repeat:
    data.size.repeat:
      crc = (table[(crc ^ data[it]) & 0xff] as int) ^ (crc >> 8)
  print crc
  reversed := ByteArray data.size
  100.repeat:
    n := data.size
    n.repeat: reversed[n - 1 - it] = data[it]
    data.replace 0 reversed
  print data[12345]
