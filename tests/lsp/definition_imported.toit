// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class ImportedClass:
/*    @ ImportedClass */

class ImportedClass2:
  constructor.named:
/*@ ImportedClass2.named */

  static static_imported_fun:
/*       @ static_imported_fun */

  static static_imported_field := null
/*       @ static_imported_field */

interface ImportedInterface:
/*        @ ImportedInterface */

imported_global_fun:
/*
@ imported_global_fun
*/
