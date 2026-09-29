// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

/**
Resolves class, field, and global names from the snapshots of the programs
  in a capture.

Snapshots are found by the UUID of their program. Without a snapshot, names
  fall back to class ids and global indices.
*/

import ar
import fs
import fs.xdg
import host.file

import ..snapshot as snapshot
import .capture

/** The directories where the Toit and Jaguar tools store snapshots. */
default-snapshot-dirs -> List:
  return [
    fs.join xdg.state-home "toit" "snapshots",
    fs.join xdg.cache-home "jaguar" "snapshots",
  ]

class Names:
  snapshot-dirs_/List
  // From UUID string to program, or null if no snapshot was found.
  programs_/Map ::= {:}

  /**
  Uses the given snapshot files, the snapshots of the containers in the
    given firmware envelopes, and searches the given directories for
    "<uuid>.snapshot" files.
  */
  constructor
      --snapshots/List=[]
      --envelopes/List=[]
      --snapshot-dirs/List=default-snapshot-dirs:
    snapshot-dirs_ = snapshot-dirs
    snapshots.do: | path/string |
      add_ (snapshot.SnapshotBundle.from-file path)
    envelopes.do: | path/string |
      reader := ar.ArReader.from-bytes (file.read-contents path)
      while entry := reader.next:
        if snapshot.SnapshotBundle.is-bundle-content entry.contents:
          add_ (snapshot.SnapshotBundle entry.name entry.contents)

  add_ bundle/snapshot.SnapshotBundle -> none:
    programs_[bundle.uuid.stringify] = bundle.decode

  program-for_ program/ProgramInfo -> snapshot.Program?:
    uuid := program.uuid-string
    return programs_.get uuid --init=:
      result := null
      snapshot-dirs_.do: | dir/string |
        path := fs.join dir "$(uuid).snapshot"
        if not result and file.is-file path:
          result = (snapshot.SnapshotBundle.from-file path).decode
      result

  /** Whether a snapshot for the given program is available. */
  has-snapshot program/ProgramInfo -> bool:
    return (program-for_ program) != null

  class-name program/ProgramInfo class-id/int -> string:
    decoded := program-for_ program
    if decoded:
      info := decoded.class-info-for class-id: return "class#$class-id"
      return info.name
    return "class#$class-id"

  /**
  Returns the names of all fields of instances of the given class, including
    inherited fields, in layout order. Returns null if unknown.
  */
  field-names program/ProgramInfo class-id/int -> List?:
    decoded := program-for_ program
    if not decoded: return null
    chain := []
    id := class-id
    while id != null:
      info := decoded.class-info-for id: return null
      chain.add info
      id = info.super-id
    result := []
    chain.do --reversed: | info/snapshot.ClassInfo | result.add-all info.fields
    return result

  global-name program/ProgramInfo index/int -> string:
    decoded := program-for_ program
    if decoded and index < decoded.global-table.size:
      info/snapshot.GlobalInfo := decoded.global-table[index]
      if info.holder-name: return "$(info.holder-name).$(info.name)"
      return info.name
    return "global#$index"
