main args:
  make_test := args.size > 0 and args[0] == "--test"

  if make_test:
    print """
      // Copyright (C) 2022 Toitware ApS.
      // Use of this source code is governed by a Zero-Clause BSD license that can
      // be found in the tests/LICENSE file.

      import crypto.crc
      import expect show *

      main:"""

  lines := CRCCALC_TABLE.split "\n"
  for i := 0; i < lines.size - 1; i += 2:
    name := lines[i]
    fields := lines[i + 1].split "\t"

    name_camel := ""
    name_snake := ""
    upper := true
    name.to_byte_array.do:
      if it == '/' or it == '-':
        upper = true
        continue.do
      if 'A' <= it <= 'Z':
        name_camel += "$(%c upper ? it : it + 0x20)"
        if upper and name_snake != "": name_snake += "_"
        name_snake += "$(%c it + 0x20)"
      else if '0' <= it <= '9':
        name_camel += "$(%c it)"
        name_snake += "$(%c it)"
      else:
        throw "What to do about '$(%c it)'?"
      upper = false

    if fields[4] != fields[5]: throw "$lines[i]: Inconsistent endianism"
    endian := ?
    endian_upper := ?
    polynomial_argument := ?
    if fields[4] == "true":
      endian = "little"
      endian_upper = "LITTLE"
      polynomial_argument = "normal_polynomial"
    else if fields[4] == "false":
      endian = "big"
      endian_upper = "BIG"
      polynomial_argument = "polynomial"
    else:
      throw lines[i]
    width := ?
    if name.contains "-32":
      width = 32
    else if name.contains "-16" or name == "CRC-A":
      width = 16
    else if name.contains "-8":
      width = 8
    else:
      throw name

    if not fields[3].starts_with "0x": throw fields[3]
    if not fields[6].starts_with "0x": throw fields[6]

    initial := int.parse --radix=16 fields[3][2..]
    xor := int.parse --radix=16 fields[6][2..]

    initial_string := initial == 0 ? "" : " --initial_state=0x$(%x initial)"
    xor_string     := xor == 0     ? "" : " --xor_result=0x$(%x xor)"

    if make_test:
      print """  expect_equals $fields[1] (crc.$name_snake "123456789")"""
    else:
      print """

          /**
          Computes the $name checksum of the given \$data.

          The \$data must be a string or byte array.
          Returns the checksum as a$(width == 8 ? "n" : "") $(width)-bit integer.
          */
          $name_snake data -> int:
            crc := Crc.$(endian)_endian $width --$polynomial_argument=$fields[2]$initial_string$xor_string
            crc.add data
            return crc.get_as_int

          /** $name checksum state. */
          class $name_camel extends Crc:
            constructor:
              super.$(endian)_endian $width --$polynomial_argument=$fields[2]$initial_string$xor_string"""

CRCCALC_TABLE ::= """
    CRC-16/CCITT-FALSE
    0x29B1	0x29B1	0x1021	0xFFFF	false	false	0x0000
    CRC-16/ARC
    0xBB3D	0xBB3D	0x8005	0x0000	true	true	0x0000
    CRC-16/AUG-CCITT
    0xE5CC	0xE5CC	0x1021	0x1D0F	false	false	0x0000
    CRC-16/BUYPASS
    0xFEE8	0xFEE8	0x8005	0x0000	false	false	0x0000
    CRC-16/CDMA2000
    0x4C06	0x4C06	0xC867	0xFFFF	false	false	0x0000
    CRC-16/DDS-110
    0x9ECF	0x9ECF	0x8005	0x800D	false	false	0x0000
    CRC-16/DECT-R
    0x007E	0x007E	0x0589	0x0000	false	false	0x0001
    CRC-16/DECT-X
    0x007F	0x007F	0x0589	0x0000	false	false	0x0000
    CRC-16/DNP
    0xEA82	0xEA82	0x3D65	0x0000	true	true	0xFFFF
    CRC-16/EN-13757
    0xC2B7	0xC2B7	0x3D65	0x0000	false	false	0xFFFF
    CRC-16/GENIBUS
    0xD64E	0xD64E	0x1021	0xFFFF	false	false	0xFFFF
    CRC-16/MAXIM
    0x44C2	0x44C2	0x8005	0x0000	true	true	0xFFFF
    CRC-16/MCRF4XX
    0x6F91	0x6F91	0x1021	0xFFFF	true	true	0x0000
    CRC-16/RIELLO
    0x63D0	0x63D0	0x1021	0x554D	true	true	0x0000
    CRC-16/T10-DIF
    0xD0DB	0xD0DB	0x8BB7	0x0000	false	false	0x0000
    CRC-16/TELEDISK
    0x0FB3	0x0FB3	0xA097	0x0000	false	false	0x0000
    CRC-16/TMS37157
    0x26B1	0x26B1	0x1021	0x3791	true	true	0x0000
    CRC-16/USB
    0xB4C8	0xB4C8	0x8005	0xFFFF	true	true	0xFFFF
    CRC-A
    0xBF05	0xBF05	0x1021	0x6363	true	true	0x0000
    CRC-16/KERMIT
    0x2189	0x2189	0x1021	0x0000	true	true	0x0000
    CRC-16/MODBUS
    0x4B37	0x4B37	0x8005	0xFFFF	true	true	0x0000
    CRC-16/X-25
    0x906E	0x906E	0x1021	0xFFFF	true	true	0xFFFF
    CRC-16/XMODEM
    0x31C3	0x31C3	0x1021	0x0000	false	false	0x0000
    CRC-8
    0xF4	0xF4	0x07	0x00	false	false	0x00
    CRC-8/CDMA2000
    0xDA	0xDA	0x9B	0xFF	false	false	0x00
    CRC-8/DARC
    0x15	0x15	0x39	0x00	true	true	0x00
    CRC-8/DVB-S2
    0xBC	0xBC	0xD5	0x00	false	false	0x00
    CRC-8/EBU
    0x97	0x97	0x1D	0xFF	true	true	0x00
    CRC-8/I-CODE
    0x7E	0x7E	0x1D	0xFD	false	false	0x00
    CRC-8/ITU
    0xA1	0xA1	0x07	0x00	false	false	0x55
    CRC-8/MAXIM
    0xA1	0xA1	0x31	0x00	true	true	0x00
    CRC-8/ROHC
    0xD0	0xD0	0x07	0xFF	true	true	0x00
    CRC-8/WCDMA
    0x25	0x25	0x9B	0x00	true	true	0x00
    CRC-32
    0xCBF43926	0xCBF43926	0x04C11DB7	0xFFFFFFFF	true	true	0xFFFFFFFF
    CRC-32/BZIP2
    0xFC891918	0xFC891918	0x04C11DB7	0xFFFFFFFF	false	false	0xFFFFFFFF
    CRC-32C
    0xE3069283	0xE3069283	0x1EDC6F41	0xFFFFFFFF	true	true	0xFFFFFFFF
    CRC-32D
    0x87315576	0x87315576	0xA833982B	0xFFFFFFFF	true	true	0xFFFFFFFF
    CRC-32/JAMCRC
    0x340BC6D9	0x340BC6D9	0x04C11DB7	0xFFFFFFFF	true	true	0x00000000
    CRC-32/MPEG-2
    0x0376E6E7	0x0376E6E7	0x04C11DB7	0xFFFFFFFF	false	false	0x00000000
    CRC-32/POSIX
    0x765E7680	0x765E7680	0x04C11DB7	0x00000000	false	false	0xFFFFFFFF
    CRC-32Q
    0x3010BF7F	0x3010BF7F	0x814141AB	0x00000000	false	false	0x00000000
    CRC-32/XFER
    0xBD0BE338	0xBD0BE338	0x000000AF	0x00000000	false	false	0x00000000
    """
