// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
// Minimal host harness for the extension's AT registration and transport calls.
#include <stdbool.h>
#include <stdint.h>

#define ESP_AT_RESULT_CODE_OK 0
#define ESP_AT_RESULT_CODE_ERROR 1
#define ESP_AT_PARA_PARSE_RESULT_OK 0
typedef struct {
  char* at_cmdName;
  uint8_t (*at_testCmd)(uint8_t*);
  uint8_t (*at_queryCmd)(uint8_t*);
  uint8_t (*at_setupCmd)(uint8_t);
  uint8_t (*at_exeCmd)(uint8_t*);
} esp_at_cmd_struct;
int esp_at_get_para_as_digit(int index, int32_t* value);
int esp_at_get_para_as_str(int index, uint8_t** value);
int32_t esp_at_port_write_data(uint8_t* data, int32_t length);
bool esp_at_custom_cmd_array_regist(const esp_at_cmd_struct* commands, uint32_t count);
