// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class ImportedClass:
/*    @ ImportedClass */

class ImportedClass2:
  constructor.named:
/*@ ImportedClass2.named */

  static static-imported-fun:
/*       @ static_imported_fun */

  static static-imported-field := null
/*       @ static_imported_field */

interface ImportedInterface:
/*        @ ImportedInterface */

imported-global-fun:
/*
@ imported_global_fun
*/
