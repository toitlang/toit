// Copyright (C) 2026 Toit contributors.
#ifndef TOIT_VF_BORROW_SLICE_H
#define TOIT_VF_BORROW_SLICE_H
#include "../model/objects.gen.h"
/*@
// Take one readable slice at a time. The data and table can be different
// slices of the same object, or the table can contain references into it.
predicate borrowed_slice(list<void *> objs, fixpoint(void *, oinfo) H, void *b, uint8 *a, int len) =
  blob_in(H, b, a, len) == true &*& heap_holes(objs, H, cons(b, nil)) &*& blob_hole(objs, H, b) &*&
  uchars(blob_base(H, b), (uword)a - (uword)blob_base(H, b), _) &*&
  uchars(a + len, blob_len(H, b) - ((uword)a - (uword)blob_base(H, b)) - len, _);

lemma void borrow_slice(void *b, uint8 *a, int len)
  requires heap(?objs, ?H) &*& [_]blob_result(objs, H, STRINGS_OR_BYTE_ARRAYS, a, len, b);
  ensures borrowed_slice(objs, H, b, a, len) &*& uchars(a, len, _);
{
  open [_]blob_result(objs, H, STRINGS_OR_BYTE_ARRAYS, a, len, b);
  blob_facts(b);
  heap_holes_open();
  blob_take(b);
  uchars_split(blob_base(H, b), (uword)a - (uword)blob_base(H, b));
  uchars_split(a, len);
  close borrowed_slice(objs, H, b, a, len);
}

lemma void return_slice(void *b, uint8 *a, int len)
  requires borrowed_slice(?objs, ?H, b, a, len) &*& uchars(a, len, _);
  ensures heap(objs, H);
{
  open borrowed_slice(objs, H, b, a, len);
  uchars_join(a);
  uchars_join(blob_base(H, b));
  blob_give(b);
  heap_holes_close();
}
lemma void slice_byte_limits(uint8 *a, int i)
  requires [?f]uchars(a, ?n, ?bytes) &*& 0 <= i &*& i < n;
  ensures [f]uchars(a, n, bytes) &*& 0 <= nth(i, bytes) &*& nth(i, bytes) <= 255;
{
  uchars_split(a, i);
  open [f]uchars(a+i, n-i, _);
  u_character_limits(a+i);
  close [f]uchars(a+i, n-i, _);
  uchars_join(a);
  nth_drop(0, i, bytes);
}
@*/
#endif
