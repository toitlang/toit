// Copyright (C) 2019 Toitware ApS. All rights reserved.

// This file is similar to definition_imported.toit.
// It doesn't need to be identical, as long as the tested entries are
//   duplicated. to yield ambiguous results.

class ImportedClass:
/*    @ ImportedClass_ambig */

  constructor.named:
/*@ ImportedClass.named_ambig */

  static static_imported_fun:
/*       @ static_imported_fun_ambig */

  static static_imported_field := null
/*       @ static_imported_field_ambig */

interface ImportedInterface:
/*        @ ImportedInterface_ambig */

imported_global_fun:
/*
@ imported_global_fun_ambig
*/
