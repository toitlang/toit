#ifdef TOIT_FREERTOS
#include "ota.h"

#include "esp_ota_ops.h"

namespace toit {

bool Ota::is_firmware_updated() {
  return false;
}

void Ota::set_up() { }

}  // namespace toit

#endif