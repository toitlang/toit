// Copyright (C) 2026 Toit contributors.

#ifndef TOIT_VERIFIED_FREE_REGION_H
#define TOIT_VERIFIED_FREE_REGION_H

#include "../model/objects.gen.h"

typedef HeapObject FreeListRegion;
/*@
predicate region_storage(FreeListRegion *region, uword base, int count, FreeListRegion *next, list<option<void *> > slots) =
  (uword)region == base + 1 &*& base > 0 &*& base % sizeof(word) == 0 &*&
  count >= 3 &*& base + count * sizeof(word) <= UINTPTR_MAX &*&
  pointers_((void **)base,count,slots) &*& nth(0,slots) == some(?header) &*&
  header_tag2((uword)header) == 2 * FREE_LIST_REGION_TAG &*&
  nth(1,slots) == some((void *)(count * sizeof(word))) &*& nth(2,slots) == some((void *)next);
@*/
uword FreeListRegion_size(FreeListRegion *self);
//@ requires region_storage(self,?base,?n,?next,?words);
//@ ensures region_storage(self,base,n,next,words) &*& result == n * sizeof(word);

#endif
