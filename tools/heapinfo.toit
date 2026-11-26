// Copyright (C) 2026 Toit contributors.
//
// Red-team round 3 helper: decode a format-2 snapshot with the snapshot
// library and print the literal / root / global heap objects with their
// class ids, class names, kinds and fields. Used to pick targets for
// heapcraft.toit (which edits the raw heap stream).
//
// Usage: toit.run --project-root tools tools/heapinfo.toit <snapshot>

import host.file
import .snapshot

safe-cid obj -> int:
  if obj is ToitHeapObject and (obj as ToitHeapObject).header != null:
    return (obj as ToitHeapObject).class-id
  return -1

kind-of obj -> string:
  if obj is ToitArray:     return "array"
  if obj is ToitByteArray: return "bytearray"
  if obj is ToitString:    return "string"
  if obj is ToitInstance:  return "instance"
  if obj is ToitFloat:     return "float"
  if obj is ToitInteger:   return "integer"
  if obj is ToitOddball:   return "oddball"
  return "?"

describe program/Program obj -> string:
  if obj is ToitInteger: return "int=$((obj as ToitInteger).value)"
  if obj is ToitString:
    s := (obj as ToitString).content
    return "str len=$s.size \"$(s.to-string-non-throwing)\""
  if obj is ToitByteArray:
    return "bytes len=$((obj as ToitByteArray).content.size)"
  if obj is ToitArray:
    a := obj as ToitArray
    return "array len=$a.content.size"
  if obj is ToitFloat:  return "float=$((obj as ToitFloat).value)"
  if obj is ToitOddball: return "oddball"
  if obj is ToitInstance:
    inst := obj as ToitInstance
    cid := inst.class-id
    cname := program.class-info-for cid (: return "instance class=$cid(<$cid>) fields=$inst.fields.size")
    return "instance class=$cid($cname.name) fields=$inst.fields.size"
  return "?"

print-list program/Program title/string lst/List:
  print "== $title ($lst.size) =="
  lst.size.repeat: | i |
    obj := lst[i]
    cid := safe-cid obj
    print "  [$i] $(kind-of obj)  cid=$cid  $(describe program obj)"
    if obj is ToitInstance:
      inst := obj as ToitInstance
      inst.fields.size.repeat: | f |
        fv := inst.fields[f]
        print "        .$f = $(kind-of fv) $(describe program fv)"

main args/List:
  if args.size >= 1 and args[0] == "--classes":
    dump-classes args[1..]
    return
  if args.size != 1:
    print "Usage: heapinfo <snapshot> | heapinfo --classes <snapshot>"
    return
  bundle := SnapshotBundle.from-file args[0]
  program := bundle.decode
  print "format=$program.format ($program.format-name) literals=$program.literals.size roots=$program.roots.size globals=$program.global-variables.size"
  print-list program "literals" program.literals
  print-list program "globals" program.global-variables
  print-list program "roots" program.roots

// Extra entry point: dump the class table id/name/tag/size for classcraft.
dump-classes args/List:
  bundle := SnapshotBundle.from-file args[0]
  program := bundle.decode
  program.class-tags.size.repeat: | id |
    tag := program.class-tags[id]
    size := program.class-instance-sizes[id]
    name := program.class-info-for id (: null)
    nm := name ? name.name : "?"
    print "  cid=$id tag=$tag size=$size $nm"
