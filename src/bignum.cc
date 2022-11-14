// Copyright (C) 2022 Toitware ApS.
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

#include "top.h"
#include "objects_inline.h"
#include "process.h"
#include "resource.h"
#include "resource_pool.h"
#include "vm.h"

#include "mbedtls/bignum.h"

namespace toit {

class BigNumResourceGroup : public ResourceGroup {
 public:
  TAG(BigNumResourceGroup);

  BigNumResourceGroup(Process* process) : ResourceGroup(process) {
    mbedtls_mpi_init(&bignum);
  }
  ~BigNumResourceGroup() {
    mbedtls_mpi_free(&bignum);
  }

  bool init(const uint8_t *data, int len) {
    int ret = mbedtls_mpi_read_binary(&bignum, data, len);
    if (ret != 0) return false;
    
    return true;
  }

  bool init_from_string(const char *data) {
    int ret = mbedtls_mpi_read_string(&bignum, 16, data);
    if (ret != 0) return false;
    
    return true;
  }

  mbedtls_mpi bignum;
};

MODULE_IMPLEMENTATION(bignum, MODULE_BIGNUM)

PRIMITIVE(init) {
  ARGS(Blob, data);

  if (data.length() <= 0) INVALID_ARGUMENT;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  BigNumResourceGroup* group = _new BigNumResourceGroup(process);
  if (!group) MALLOC_FAILED;

  if (!group->init(data.address(), data.length())) MALLOC_FAILED;

  proxy->set_external_address(group);

  return proxy;
}

PRIMITIVE(init_from_string) {
  ARGS(String, data);

  if (data->length() <= 0) INVALID_ARGUMENT;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  BigNumResourceGroup* group = _new BigNumResourceGroup(process);
  if (!group) MALLOC_FAILED;

  if (!group->init_from_string(data->as_cstr())) MALLOC_FAILED;

  proxy->set_external_address(group);

  return proxy;
}

PRIMITIVE(bytes) {
  ARGS(BigNumResourceGroup, A);

  size_t n = mbedtls_mpi_size(&A->bignum);
  ByteArray* data = process->allocate_byte_array(n);
  if (data == null) ALLOCATION_FAILED;

  memcpy(ByteArray::Bytes(data).address(), A->bignum.p, n);

  return data;
}

PRIMITIVE(string) {
  ARGS(BigNumResourceGroup, A);

  size_t n = mbedtls_mpi_size(&A->bignum) * 2 + 3;
  String* data = process->allocate_string(n);
  if (data == null) ALLOCATION_FAILED;

  String::Bytes bytes(data);
  int ret = mbedtls_mpi_write_string(&A->bignum, 16, (char *)bytes.address(), n, &n);
  if (ret != 0) MALLOC_FAILED;

  return data;
}

PRIMITIVE(equal) {
  ARGS(BigNumResourceGroup, A, BigNumResourceGroup, B);

  int ret = mbedtls_mpi_cmp_mpi(&A->bignum, &B->bignum);

  return BOOL(ret == 0);
}

PRIMITIVE(add) {
  ARGS(BigNumResourceGroup, A, BigNumResourceGroup, B);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  BigNumResourceGroup* group = _new BigNumResourceGroup(process);
  if (!group) MALLOC_FAILED;

  int ret = mbedtls_mpi_add_mpi(&group->bignum, &A->bignum, &B->bignum);
  if (ret != 0) MALLOC_FAILED;

  proxy->set_external_address(group);

  return proxy;
}

PRIMITIVE(subtract) {
  ARGS(BigNumResourceGroup, A, BigNumResourceGroup, B);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  BigNumResourceGroup* group = _new BigNumResourceGroup(process);
  if (!group) MALLOC_FAILED;

  int ret = mbedtls_mpi_sub_mpi(&group->bignum, &A->bignum, &B->bignum);
  if (ret != 0) MALLOC_FAILED;

  proxy->set_external_address(group);

  return proxy;
}

PRIMITIVE(multiply) {
  ARGS(BigNumResourceGroup, A, BigNumResourceGroup, B);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  BigNumResourceGroup* group = _new BigNumResourceGroup(process);
  if (!group) MALLOC_FAILED;

  int ret = mbedtls_mpi_mul_mpi(&group->bignum, &A->bignum, &B->bignum);
  if (ret != 0) MALLOC_FAILED;

  proxy->set_external_address(group);

  return proxy;
}

PRIMITIVE(divide) {
  ARGS(BigNumResourceGroup, A, BigNumResourceGroup, B);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  BigNumResourceGroup* group = _new BigNumResourceGroup(process);
  if (!group) MALLOC_FAILED;

  int ret = mbedtls_mpi_div_mpi(&group->bignum, NULL, &A->bignum, &B->bignum);
  if (ret != 0) MALLOC_FAILED;

  proxy->set_external_address(group);

  return proxy;
}

PRIMITIVE(mod) {
  ARGS(BigNumResourceGroup, A, BigNumResourceGroup, B);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  BigNumResourceGroup* group = _new BigNumResourceGroup(process);
  if (!group) MALLOC_FAILED;

  int ret = mbedtls_mpi_mod_mpi(&group->bignum, &A->bignum, &B->bignum);
  if (ret != 0) MALLOC_FAILED;

  proxy->set_external_address(group);

  return proxy;
}

PRIMITIVE(exp_mod) {
  ARGS(BigNumResourceGroup, A, BigNumResourceGroup, E, BigNumResourceGroup, N);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  BigNumResourceGroup* group = _new BigNumResourceGroup(process);
  if (!group) MALLOC_FAILED;

  int ret = mbedtls_mpi_exp_mod(&group->bignum, &A->bignum, &E->bignum, &N->bignum, NULL);
  if (ret != 0) MALLOC_FAILED;

  proxy->set_external_address(group);

  return proxy;
}

} // namespace toit
