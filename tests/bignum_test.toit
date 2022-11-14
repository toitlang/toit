// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import bignum show *

main:
  A := Bignum.from_string """
          EFE021C2645FD1DC586E69184AF4A31E\
          D5F53E93B5F123FA41680867BA110131\
          944FE7952E2517337780CB0DB80E61AA\
          E7C8DDC6C5C6AADEB34EB38A2F40D5E6"""
  B := Bignum.from_string """
          0066A198186C18C10B2F5ED9B522752A\
          9830B69916E535C8F047518A889A43A5\
          94B6BED27A168D31D4A52F88925AA8F5"""

  X := A + B
  U := Bignum.from_string """
          EFE021C2645FD1DC586E69184AF4A31E\
          D65BE02BCE5D3CBB4C9767416F33765C\
          2C809E2E450A4CFC67C81C9840A8A550\
          7C7F9C993FDD381087F3E312C19B7EDB"""
  expect X == U

  X = A - B
  U = Bignum.from_string """
          EFE021C2645FD1DC586E69184AF4A31E\
          D58E9CFB9D850B393638A98E04EE8C06\
          FC1F30FC173FE16A873979832F741E05\
          53121EF44BB01DACDEA984019CE62CF1"""
  expect X == U

  X = A * B
  U = Bignum.from_string """
          602AB7ECA597A3D6B56FF9829A5E8B85\
          9E857EA95A03512E2BAE7391688D264A\
          A5663B0341DB9CCFD2C4C5F421FEC814\
          8001B72E848A38CAE1C65F78E56ABDEF\
          E12D3C039B8A02D6BE593F0BBBDA56F1\
          ECF677152EF804370C1A305CAF3B5BF1\
          30879B56C61DE584A0F53A2447A51E"""
  expect X == U

  X = A / B
  U = Bignum.from_string """
          256567336059E52CAE22925474705F39A94"""
  expect X == U

  X = A % B
  U = Bignum.from_string """
          6613F26162223DF488E9CD48CC132C7A\
          0AC93C701B001B092E4E5B9F73BCD27B\
          9EE50D0657C77F374E903CDFA4C642"""
  expect X == U

  C := Bignum.from_string """
          B2E7EFD37075B9F03FF989C7C5051C20\
          34D2A323810251127E7BF8625A4F49A5\
          F3E27F4DA8BD59C47D6DAABA4C8127BD\
          5B5C25763222FEFCCFC38B832366C29E"""
  X = mod_exp A C B
  U = Bignum.from_string """
          36E139AEA55215609D2816998ED020BB\
          BD96C37890F65171D948E9BC7CBAA4D9\
          325D24D6A3C12710F10A09FA08AB87"""
  expect X == U
