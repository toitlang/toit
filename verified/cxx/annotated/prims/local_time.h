// Copyright (C) 2026 Toit contributors.
#ifndef TOIT_LOCAL_TIME_H
#define TOIT_LOCAL_TIME_H

typedef long time_t;
typedef unsigned long size_t;

// Calendar fields used by src/primitive_core.cc (C11 7.27.1).
struct tm {
  int tm_sec;
  int tm_min;
  int tm_hour;
  int tm_mday;
  int tm_mon;
  int tm_year;
  int tm_wday;
  int tm_yday;
  int tm_isdst;
};

/*@
// The fields of a struct tm, possibly uninitialized.
predicate tm_fields(struct tm *t;) =
  t->tm_sec |-> _ &*& t->tm_min |-> _ &*& t->tm_hour |-> _ &*& t->tm_mday |-> _ &*&
  t->tm_mon |-> _ &*& t->tm_year |-> _ &*& t->tm_wday |-> _ &*& t->tm_yday |-> _ &*&
  t->tm_isdst |-> _;
@*/

// Both primitives clear the complete native struct before using its fields.
void *memset(void *array, int value, size_t size);
//@ requires tm_fields(array) &*& size == sizeof(struct tm);
//@ ensures tm_fields(array) &*& result == array;

void tm_ctor(struct tm *self);
//@ requires tm_fields(self);
//@ ensures tm_fields(self);

#endif
