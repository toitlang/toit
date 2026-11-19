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

#include "../top.h"

#ifdef TOIT_EC618

#include "../event_sources/cellular_ec618.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "cellular_state_ec618.h"
#include "cellular_modem_ec618.h"

extern "C" {
  // networkmgr.h (included by ps_lib_api.h) needs these defines
  // which normally come from the lwIP config header.
  #ifndef NM_PDN_TYPE_MAX_DNS_NUM
  #define NM_PDN_TYPE_MAX_DNS_NUM 2
  #endif
  #ifndef NM_MAX_DNS_NUM
  #define NM_MAX_DNS_NUM 4
  #endif
  #include "ps_lib_api.h"
  #include "networkmgr.h"
  #include "cmips.h"

  CmsRetId psSetCdgcont(UINT32 atHandle, CmiPsDefPdpDefinition* ctxInfo);
}

namespace toit {

class CellularEvents : public Resource {
 public:
  TAG(CellularEvents);
  CellularEvents(ResourceGroup* group)
    : Resource(group) {}

  CellularNetworkState& network_state() { return network_state_; }

 private:
  CellularNetworkState network_state_;
};

static CellularModemState modem;

static int32_t initialize_modem() {
  Locker locker(OS::global_mutex());
  return modem.initialize(appSetCFUN);
}

static CellularModemState::ConnectResult activate_modem(CellularEvents* events) {
  Locker locker(OS::global_mutex());
  return modem.activate(events, appSetCFUN);
}

static int32_t deactivate_modem(CellularEvents* events) {
  Locker locker(OS::global_mutex());
  return modem.deactivate(events, appSetCFUN);
}

static Object* modem_error(Process* process, const char* operation, int32_t error) {
  char message[96];
  snprintf(message, sizeof(message), "cellular %s failed (CMS error %ld)",
           operation, static_cast<long>(error));
  String* result = process->allocate_string(message);
  if (result == null) FAIL(ALLOCATION_FAILED);
  return Error::from(result);
}

class CellularResourceGroup : public ResourceGroup {
 public:
  TAG(CellularResourceGroup);
  CellularResourceGroup(Process* process, EventSource* event_source)
    : ResourceGroup(process, event_source)
    , ipv4_addr_(0) {}

  uint32 ipv4_addr() const { return ipv4_addr_; }
  void set_ipv4_addr(uint32 addr) { ipv4_addr_ = addr; }

  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
    auto event = reinterpret_cast<CellularEvent*>(data);
    auto events = static_cast<CellularEvents*>(resource);

    switch (event->event_id) {
      case PS_URC_ID_PS_NETINFO: {
        auto& network = events->network_state();
        state = network.on_net_info(event->param, event->param_len, state);
        ipv4_addr_ = network.ipv4_address();
        break;
      }
      default:
        break;
    }
    return state;
  }

 protected:
  void on_unregister_resource(Resource* resource) override {
    int32_t error = deactivate_modem(static_cast<CellularEvents*>(resource));
    if (error != CMS_RET_SUCC) {
      // Forced container cleanup cannot throw. Keep the failure visible and
      // let the next activation retry the failed shutdown before enabling.
      printf("[cellular] disable failed (CMS error %ld)\n", static_cast<long>(error));
    }
    // A failed second connect can unregister a temporary resource while the
    // group's original connection is still alive.
    if (resources().is_empty()) ipv4_addr_ = 0;
  }

 private:
  uint32 ipv4_addr_;
};

MODULE_IMPLEMENTATION(cellular, MODULE_CELLULAR)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  // Ensure the modem starts from a clean state, without letting a later
  // resource group disrupt an existing connection.
  int32_t error = initialize_modem();
  if (error != CMS_RET_SUCC) return modem_error(process, "initialize", error);

  CellularEventSource* event_source = CellularEventSource::instance();
  if (event_source == null) FAIL(ALREADY_CLOSED);

  CellularResourceGroup* group = _new CellularResourceGroup(process, event_source);
  if (group == null) FAIL(MALLOC_FAILED);

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(close) {
  ARGS(CellularResourceGroup, group);
  group->tear_down();
  group_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(configure) {
  ARGS(CellularResourceGroup, group, Blob, apn);
  USE(group);
  if (apn.length() == 0) return process->null_object();
  if (apn.length() > CMI_PS_MAX_APN_LEN) FAIL(INVALID_ARGUMENT);

  CmiPsDefPdpDefinition ctx = {};
  ctx.cid = 0;
  ctx.pdnType = CMI_PS_PDN_TYPE_IP_V4;
  ctx.apnPresentType = CMI_UPDATE_WITH_NEW;
  ctx.apnLength = apn.length();
  memcpy(ctx.apnStr, apn.address(), apn.length());
  CmsRetId ret = psSetCdgcont(0, &ctx);
  if (ret != CMS_RET_SUCC) FAIL(ERROR);

  return process->null_object();
}

PRIMITIVE(connect) {
  ARGS(CellularResourceGroup, group);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  CellularEvents* events = _new CellularEvents(group);
  if (events == null) FAIL(MALLOC_FAILED);

  group->register_resource(events);
  AutoUnregisteringResource<CellularEvents> allocation(group, events);

  auto result = activate_modem(events);
  if (result.already_in_use) FAIL(ALREADY_IN_USE);
  if (result.error != CMS_RET_SUCC) return modem_error(process, "enable", result.error);

  allocation.set_external_address(proxy);
  return proxy;
}

PRIMITIVE(disconnect) {
  ARGS(CellularResourceGroup, group, CellularEvents, events);
  if (events->resource_group() != group) FAIL(INVALID_ARGUMENT);
  int32_t error = deactivate_modem(events);
  group->unregister_resource(events);
  events_proxy->clear_external_address();
  if (error != CMS_RET_SUCC) return modem_error(process, "disable", error);
  return process->null_object();
}

PRIMITIVE(disconnect_reason) {
  ARGS(CellularEvents, events);
  char reason[80];
  {
    Locker locker(events->resource_group()->event_source()->mutex());
    events->network_state().format_disconnect_reason(reason, sizeof(reason));
  }
  return process->allocate_string_or_error(reason);
}

PRIMITIVE(get_ip) {
  ARGS(CellularResourceGroup, group, int, index);
  if (index != 0) FAIL(INVALID_ARGUMENT);
  uint32 addr;
  {
    Locker locker(group->event_source()->mutex());
    addr = group->ipv4_addr();
  }
  if (addr == 0) return process->null_object();

  // Return as a 4-byte byte array.
  ByteArray* result = process->object_heap()->allocate_internal_byte_array(4);
  if (result == null) FAIL(ALLOCATION_FAILED);
  ByteArray::Bytes bytes(result);
  bytes.address()[0] = (addr >> 0) & 0xff;
  bytes.address()[1] = (addr >> 8) & 0xff;
  bytes.address()[2] = (addr >> 16) & 0xff;
  bytes.address()[3] = (addr >> 24) & 0xff;
  return result;
}

PRIMITIVE(get_cell_info) {
  // Query serving cell information.
  BasicCellListInfo info;
  memset(&info, 0, sizeof(info));
  CmsRetId ret = appGetECBCInfoSync(&info);
  if (ret != CMS_RET_SUCC) return Smi::from(static_cast<int>(ret));
  if (!info.sCellPresent) return process->null_object();

  // Return as a flat array of values.
  Array* result = process->object_heap()->allocate_array(16, Smi::from(0));
  if (result == null) FAIL(ALLOCATION_FAILED);

  auto& cell = info.sCellInfo;
  int i = 0;
  result->at_put(i++, Smi::from(cell.plmn.mcc));
  result->at_put(i++, Smi::from(CAM_GET_PURE_MNC(cell.plmn.mncWithAddInfo)));
  result->at_put(i++, Smi::from(cell.earfcn));
  result->at_put(i++, Smi::from(cell.cellId));
  result->at_put(i++, Smi::from(cell.tac));
  result->at_put(i++, Smi::from(cell.phyCellId));
  result->at_put(i++, Smi::from(cell.snrPresent));
  result->at_put(i++, Smi::from(cell.snr));
  result->at_put(i++, Smi::from(cell.rsrp));
  result->at_put(i++, Smi::from(cell.rsrq));
  // Fill remaining slots with 0 (reserved for extended fields).
  while (i < 16) result->at_put(i++, Smi::from(0));

  return result;
}

}  // namespace toit

#endif  // TOIT_EC618
