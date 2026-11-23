// Copyright (C) 2026 Toit contributors.

#ifndef TOIT_READ_SLICE_H
#define TOIT_READ_SLICE_H

#include "../blob/byte_content.gen.h"

/*@
predicate validation_slice(list<void *> objs, fixpoint(void *, oinfo) H, void *b, uint8 *p, int n) =
  heap_holes(objs, H, cons(b, nil)) &*& blob_hole(objs, H, b) &*&
  uchars(blob_base(H, b), (uword)p - (uword)blob_base(H, b), _) &*&
  uchars(p + n, blob_len(H, b) - ((uword)p - (uword)blob_base(H, b)) - n, _);

lemma void borrow_slice(void *b, uint8 *p, int n)
  requires heap(?objs, ?H) &*& mem(b, objs) == true &*& blob_ok(H, b, STRINGS_OR_BYTE_ARRAYS) == true &*& blob_in(H, b, p, n) == true;
  ensures validation_slice(objs, H, b, p, n) &*& uchars(p, n, _);
{
  heap_holes_open();
  blob_take(b);
  uchars_split(blob_base(H, b), (uword)p - (uword)blob_base(H, b));
  uchars_split(p, n);
  close validation_slice(objs, H, b, p, n);
}

lemma void return_slice(void *b, uint8 *p)
  requires validation_slice(?objs, ?H, b, p, ?n) &*& uchars(p, n, _) &*& blob_in(H, b, p, n) == true;
  ensures heap(objs, H);
{
  open validation_slice(objs, H, b, p, n);
  uchars_join(p);
  uchars_join(blob_base(H, b));
  blob_give(b);
  heap_holes_close();
}

@*/
#endif
