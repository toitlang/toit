// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// This file is similar to definition_imported.toit.
// It doesn't need to be identical, as long as the tested entries are
//   duplicated. to yield ambiguous results.

class ImportedClass:
/*    @ ImportedClass_ambig */

  constructor.named:
/*@ ImportedClass.named_ambig */

  static static-imported-fun:
/*       @ static_imported_fun_ambig */

  static static-imported-field := null
/*       @ static_imported_field_ambig */

interface ImportedInterface:
/*        @ ImportedInterface_ambig */

imported-global-fun:
/*
@ imported_global_fun_ambig
*/
