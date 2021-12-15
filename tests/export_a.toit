// Copyright (C) 2020 Toitware ApS. All rights reserved.

// The explicit 'show foo' disambiguates the export clause.
import .export_b
import .export_c show foo

export foo
