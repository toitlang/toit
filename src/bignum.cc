// Copyright (C) 2022 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR a PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#include "top.h"
#include "objects_inline.h"
#include "process.h"
#include "resource.h"
#include "resource_pool.h"
#include "vm.h"

#include "mbedtls/bignum.h"

namespace toit {

typedef int (*mpi_basic_func_t)(mbedtls_mpi* x, const mbedtls_mpi* a, const mbedtls_mpi* b);

static int mbedtls_mpi_div_mpi_no_r(mbedtls_mpi* x,
                                    const mbedtls_mpi* a,
                                    const mbedtls_mpi* b);

static const mpi_basic_func_t MPI_BASIC_FUNCS[] = {
    mbedtls_mpi_add_mpi,
    mbedtls_mpi_sub_mpi,
    mbedtls_mpi_mul_mpi,
    mbedtls_mpi_div_mpi_no_r,
    mbedtls_mpi_mod_mpi,
};
static const int MPI_BASIC_FUNCS_NUM = sizeof(MPI_BASIC_FUNCS) / sizeof(MPI_BASIC_FUNCS[0]);

static int mbedtls_mpi_div_mpi_no_r(mbedtls_mpi* x,
                                    const mbedtls_mpi* a,
                                    const mbedtls_mpi* b)
{
  return mbedtls_mpi_div_mpi(x, null, a, b);
}

MODULE_IMPLEMENTATION(bignum, MODULE_BIGNUM)


PRIMITIVE(binary_operator) {
  ARGS(int, operator_id, bool, a_negative, Blob, a_limbs, bool, b_negative, Blob, b_limbs);

  int ret;
  mbedtls_mpi a_mpi;
  mbedtls_mpi b_mpi;
  mbedtls_mpi x_mpi;

  if (operator_id >= MPI_BASIC_FUNCS_NUM || operator_id < 0) INVALID_ARGUMENT;

  Array* array = process->object_heap()->allocate_array(2, Smi::zero());
  if (array == null) ALLOCATION_FAILED;

  mbedtls_mpi_init(&a_mpi);
  mbedtls_mpi_init(&b_mpi);
  mbedtls_mpi_init(&x_mpi);

  ret = mbedtls_mpi_read_binary(&a_mpi, a_limbs.address(), a_limbs.length());
  if (ret != 0) MALLOC_FAILED;

  ret = mbedtls_mpi_read_binary(&b_mpi, b_limbs.address(), b_limbs.length());
  if (ret != 0) {
    mbedtls_mpi_free(&a_mpi);
    MALLOC_FAILED;
  }

  if (a_negative) a_mpi.s = -1;
  if (b_negative) b_mpi.s = -1;

  ret = MPI_BASIC_FUNCS[operator_id](&x_mpi, &a_mpi, &b_mpi);
  mbedtls_mpi_free(&b_mpi);
  mbedtls_mpi_free(&a_mpi);
  if (ret != 0) {
    if (ret == MBEDTLS_ERR_MPI_DIVISION_BY_ZERO) return Primitive::mark_as_error(process->program()->division_by_zero());
    if (ret == MBEDTLS_ERR_MPI_NEGATIVE_VALUE) return Primitive::mark_as_error(process->program()->negative_argument());
    else MALLOC_FAILED;
  }

  size_t n = mbedtls_mpi_size(&x_mpi);
  ByteArray* limbs = process->allocate_byte_array(n);
  if (limbs == null) {
    mbedtls_mpi_free(&x_mpi);
    ALLOCATION_FAILED;
  }

  bool sign = x_mpi.s == -1 ? true : false;
  ret = mbedtls_mpi_write_binary(&x_mpi, ByteArray::Bytes(limbs).address(), n);
  mbedtls_mpi_free(&x_mpi);
  if (ret) INVALID_ARGUMENT;

  array->at_put(0, BOOL(sign));
  array->at_put(1, limbs);

  return array;
}

PRIMITIVE(exp_mod) {
  ARGS(bool, a_negative, Blob, a_limbs, bool, b_negative, Blob, b_limbs, bool, c_negative, Blob, c_limbs);

  int ret;
  mbedtls_mpi a_mpi;
  mbedtls_mpi b_mpi;
  mbedtls_mpi c_mpi;
  mbedtls_mpi x_mpi;

  Array* array = process->object_heap()->allocate_array(2, Smi::zero());
  if (array == null) ALLOCATION_FAILED;

  mbedtls_mpi_init(&a_mpi);
  mbedtls_mpi_init(&b_mpi);
  mbedtls_mpi_init(&c_mpi);
  mbedtls_mpi_init(&x_mpi);

  ret = mbedtls_mpi_read_binary(&a_mpi, a_limbs.address(), a_limbs.length());
  if (ret != 0) MALLOC_FAILED;

  ret = mbedtls_mpi_read_binary(&b_mpi, b_limbs.address(), b_limbs.length());
  if (ret != 0) {
    mbedtls_mpi_free(&a_mpi);
    MALLOC_FAILED;
  }

  ret = mbedtls_mpi_read_binary(&c_mpi, c_limbs.address(), c_limbs.length());
  if (ret != 0) {
    mbedtls_mpi_free(&b_mpi);
    mbedtls_mpi_free(&a_mpi);
    MALLOC_FAILED;
  }

  if (a_negative) a_mpi.s = -1;
  if (b_negative) b_mpi.s = -1;
  if (c_negative) c_mpi.s = -1;

  ret = mbedtls_mpi_exp_mod(&x_mpi, &a_mpi, &b_mpi, &c_mpi, NULL);
  mbedtls_mpi_free(&c_mpi);
  mbedtls_mpi_free(&b_mpi);
  mbedtls_mpi_free(&a_mpi);
  if (ret != 0) {
    if (ret == MBEDTLS_ERR_MPI_DIVISION_BY_ZERO) return Primitive::mark_as_error(process->program()->division_by_zero());
    else MALLOC_FAILED;
  }

  size_t n = mbedtls_mpi_size(&x_mpi);
  ByteArray* limbs = process->allocate_byte_array(n);
  if (limbs == null) {
    mbedtls_mpi_free(&x_mpi);
    ALLOCATION_FAILED;
  }

  bool sign = x_mpi.s == -1 ? true : false;
  ret = mbedtls_mpi_write_binary(&x_mpi, ByteArray::Bytes(limbs).address(), n);
  mbedtls_mpi_free(&x_mpi);
  if (ret) INVALID_ARGUMENT;

  array->at_put(0, BOOL(sign));
  array->at_put(1, limbs);

  return array;
}

} // namespace toit
