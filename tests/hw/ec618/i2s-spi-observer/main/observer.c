// Copyright (C) 2026 Toit contributors.
// Private diagnostic; use of this source is governed by tests/LICENSE.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "driver/gpio.h"
#include "driver/i2s_std.h"
#include "driver/uart.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"
#include "esp_memory_utils.h"
#include "esp_vfs_dev.h"
#include "soc/i2s_struct.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "verify.h"

enum { GO = 40, ACK = 39 };
static i2s_chan_handle_t tx, rx[2];
static Verify checks[2];
static bool running;
static unsigned rate;
static uint32_t callback_max_us[2];
static uint8_t *tx_pattern;
static size_t tx_size, tx_offset;
static SemaphoreHandle_t writer_done;
static volatile bool writer_stop;
static bool writer_running;
static esp_err_t writer_error;
static volatile uint32_t tx_losses;
static Verify queued;
static uint8_t *read_buffer;
static size_t read_size;
static SemaphoreHandle_t reader_done;
static volatile bool reader_stop;
static bool reader_running;
static esp_err_t reader_error;
static volatile uint32_t rx_losses;
#include "frame.h"
#include "rolling.h"

static bool IRAM_ATTR rx_overflow(i2s_chan_handle_t channel, i2s_event_data_t *event, void *context) {
  (void)channel; (void)event;
  if (context == &checks[0]) rx_losses++;
  return false;
}

static void read_queued(void *unused) {
  (void)unused;
  size_t filled = 0;
  while (!reader_stop) {
    size_t count = 0;
    esp_err_t error = i2s_channel_read(rx[0], read_buffer + filled, read_size - filled, &count, 100);
    filled += count;
    if (filled == read_size) {
      verify_data(&queued, read_buffer, filled);
      filled = 0;
    }
    if (error != ESP_OK && !reader_stop) { reader_error = error; break; }
  }
  if (filled) verify_data(&queued, read_buffer, filled);
  xSemaphoreGive(reader_done);
  vTaskDelete(NULL);
}


static bool IRAM_ATTR tx_overflow(i2s_chan_handle_t channel, i2s_event_data_t *event, void *context) {
  (void)channel; (void)event; (void)context;
  tx_losses++;
  return false;
}

static void write_pattern(void *unused) {
  (void)unused;
  while (!writer_stop) {
    size_t written = 0;
    // Allow startup and the control task's stop acknowledgement to finish.
    // Payload checks and the TX loss counter still reject live starvation.
    esp_err_t error = i2s_channel_write(tx, tx_pattern + tx_offset, tx_size - tx_offset, &written, 100);
    tx_offset = (tx_offset + written) % tx_size;
    if (error != ESP_OK && !writer_stop) { writer_error = error; break; }
  }
  xSemaphoreGive(writer_done);
  vTaskDelete(NULL);
}


static bool IRAM_ATTR receive(i2s_chan_handle_t channel, i2s_event_data_t *event, void *context) {
  (void)channel;
  unsigned id = (unsigned)((Verify *)context - checks);
  int64_t start = esp_timer_get_time();
  int clock_bits = 0, clock_ws = 0;
  bool counting = frame_counting;
  if (counting) {
    ESP_ERROR_CHECK(pcnt_unit_get_count(bit_unit, &clock_bits));
    ESP_ERROR_CHECK(pcnt_unit_get_count(frame_unit, &clock_ws));
  }
  verify_data(&checks[id], event->dma_buf, event->size);
  if (counting) {
    unsigned callback = ++dma_callback_count[id];
    DmaSnapshot snapshot = {.ws=clock_ws, .bits=clock_bits,
        .frames=checks[id].frames, .callback=callback, .training=checks[id].training};
    dma_last[id] = snapshot;
    if ((callback <= 8 || callback % 64 == 0) && dma_snapshot_count[id] < DMA_SNAPSHOTS)
      dma_snapshots[id][dma_snapshot_count[id]++] = snapshot;
  }
  uint32_t elapsed = esp_timer_get_time() - start;
  if (elapsed > callback_max_us[id]) callback_max_us[id] = elapsed;
  return false;
}

static bool wait_ack(int level) {
  int64_t deadline = esp_timer_get_time() + 15000000;
  while (gpio_get_level(ACK) != level) {
    if (esp_timer_get_time() > deadline) return false;
    vTaskDelay(1);
  }
  return true;
}

static void halt(void) {
  wire_halt();
  gpio_set_level(GO, 0);
  reader_stop = true;
  writer_stop = true;
  if (reader_running) {
    configASSERT(xSemaphoreTake(reader_done, pdMS_TO_TICKS(1000)));
    reader_running = false;
  }
  if (writer_running) {
    writer_stop = true;
    configASSERT(xSemaphoreTake(writer_done, pdMS_TO_TICKS(1000)));
    writer_running = false;
  }
  if (running) {
    ESP_ERROR_CHECK(i2s_channel_disable(tx));
    for (unsigned i = 0; i < 2; i++) ESP_ERROR_CHECK(i2s_channel_disable(rx[i]));
    running = false;
  }
  frame_stop();
}

static void close_channels(void) {
  halt();
  frame_close();
  wire_close();
  if (tx) ESP_ERROR_CHECK(i2s_del_channel(tx));
  tx = NULL;
  free(tx_pattern);
  tx_pattern = NULL;
  free(read_buffer);
  read_buffer = NULL;
  for (unsigned i = 0; i < 2; i++) {
    if (rx[i]) ESP_ERROR_CHECK(i2s_del_channel(rx[i]));
    rx[i] = NULL;
  }
  gpio_set_direction(41, GPIO_MODE_INPUT);
}

static void configure(unsigned hz, unsigned bits, unsigned external, unsigned spi_mode) {
  close_channels();
  rate = hz;
  printf("DUAL SPI mode=%u\n", spi_mode);
  read_size = 512 * 2 * (bits / 8);
  read_buffer = heap_caps_malloc(read_size, MALLOC_CAP_8BIT | (external ? MALLOC_CAP_SPIRAM : MALLOC_CAP_INTERNAL));
  configASSERT(read_buffer);
  configASSERT(esp_ptr_external_ram(read_buffer) == (external != 0));
  verify_init(&queued, bits);
  reader_error = ESP_OK;
  rx_losses = 0;
  i2s_std_config_t config = {
    .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(hz),
    .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(bits, I2S_SLOT_MODE_STEREO),
    .gpio_cfg = { .mclk = I2S_GPIO_UNUSED, .bclk = 1, .ws = 2, .dout = 41, .din = 8 },
  };
  config.clk_cfg.mclk_multiple = bits == 24 ? I2S_MCLK_MULTIPLE_384 : I2S_MCLK_MULTIPLE_256;
  for (unsigned i = 0; i < 2; i++) {
    i2s_chan_config_t channel = I2S_CHANNEL_DEFAULT_CONFIG(i, I2S_ROLE_SLAVE);
    // Match the permanent Toit fixture's default DMA geometry and clearing.
    channel.auto_clear_before_cb = true;
    ESP_ERROR_CHECK(i2s_new_channel(&channel, i == 0 ? &tx : NULL, &rx[i]));
    if (i == 0) ESP_ERROR_CHECK(i2s_channel_init_std_mode(tx, &config));
else {
  config.gpio_cfg.dout = I2S_GPIO_UNUSED;

}
    ESP_ERROR_CHECK(i2s_channel_init_std_mode(rx[i], &config));
    verify_init(&checks[i], bits);
    callback_max_us[i] = 0;
    i2s_event_callbacks_t callbacks = { .on_recv = receive, .on_recv_q_ovf = rx_overflow };
    ESP_ERROR_CHECK(i2s_channel_register_event_callback(rx[i], &callbacks, &checks[i]));
    i2s_dev_t *hw = i == 0 ? &I2S0 : &I2S1;
    hw->rx_timing.rx_ws_in_dm = 0;
    printf("TIMING id=%u ws_delay=%u sd_delay=%u bck_delay=%u raw=%08lx\n",
           i, (unsigned)hw->rx_timing.rx_ws_in_dm,
           (unsigned)hw->rx_timing.rx_sd_in_dm,
           (unsigned)hw->rx_timing.rx_bck_in_dm,
           (unsigned long)hw->rx_timing.val);
    printf("CLKREG id=%u source=%u active=%u mclk_select=%u divider=%u conf=%08lx\n",
           i, (unsigned)hw->rx_clkm_conf.rx_clk_sel,
           (unsigned)hw->rx_clkm_conf.rx_clk_active,
           (unsigned)hw->rx_clkm_conf.mclk_sel,
           (unsigned)hw->rx_clkm_conf.rx_clkm_div_num,
           (unsigned long)hw->rx_clkm_conf.val);
  }
unsigned width = bits / 8;
tx_size = 251 * 2 * width;
tx_pattern = malloc(tx_size);
configASSERT(tx_pattern);
uint32_t mask = bits == 32 ? UINT32_MAX : (1u << bits) - 1;
for (unsigned frame = 0; frame < 251; frame++) {
  for (unsigned side = 0; side < 2; side++) {
    // The receiver helper returns the inverted pattern; undo inversion.
    uint32_t value = sample(frame, side != 0, bits) ^ mask;
    for (unsigned byte = 0; byte < width; byte++)
      tx_pattern[(frame * 2 + side) * width + byte] = value >> (8 * byte);
  }
}
uint8_t training[64] = {0};
size_t loaded = 0;
ESP_ERROR_CHECK(i2s_channel_preload_data(tx, training, 8 * 2 * width, &loaded));
configASSERT(loaded == 8 * 2 * width);
tx_offset = 0;
for (;;) {
  ESP_ERROR_CHECK(i2s_channel_preload_data(tx, tx_pattern + tx_offset, tx_size - tx_offset, &loaded));
  if (!loaded) break;
  tx_offset = (tx_offset + loaded) % tx_size;
}
writer_error = ESP_OK;
tx_losses = 0;
i2s_event_callbacks_t callbacks = { .on_send_q_ovf = tx_overflow };
ESP_ERROR_CHECK(i2s_channel_register_event_callback(tx, &callbacks, NULL));
wire_configure(bits, spi_mode);
frame_configure(2, 0);

}

static void report_records(const char *name, const Verify *v) {
  unsigned count = v->errors < VERIFY_RECORDS ? v->errors : VERIFY_RECORDS;
  printf("RECORDS %s saved=%u total=%lu\n", name, count, (unsigned long)v->errors);
  for (unsigned i = 0; i < count; i++) {
    const VerifyError *e = &v->records[i];
    printf("BAD %s frame=%lu left=%08lx right=%08lx\n", name,
           (unsigned long)e->frame, (unsigned long)e->left, (unsigned long)e->right);
  }
}

static void report(void) {
  printf("DUAL TX errors=%lu writer_error=%d\n", (unsigned long)tx_losses, writer_error);
  frame_report();
  dma_report();
  bool valid = wire_report() && !frame_overflow && tx_losses == 0 && writer_error == ESP_OK;
  for (unsigned i = 0; i < 2; i++) {
    Verify *v = &checks[i];
    printf("DUAL RX%u frames=%lu errors=%lu invalid=%u training=%u first_frame=%lu left=%08lx right=%08lx expected_left=%08lx expected_right=%08lx callback_max_us=%lu\n",
           i, (unsigned long)v->frames, (unsigned long)v->errors, v->invalid, v->training,
           (unsigned long)v->first_frame, (unsigned long)v->first_left, (unsigned long)v->first_right,
           (unsigned long)sample(v->first_frame % 251, false, v->bits),
           (unsigned long)sample(v->first_frame % 251, true, v->bits), (unsigned long)callback_max_us[i]);
    valid &= v->started && !v->invalid && !v->errors && v->frames >= rate * 99 / 10;
  }
Verify *q = &queued;
printf("QUEUED external=%u frames=%lu errors=%lu invalid=%u training=%u drops=%lu reader_error=%d first_frame=%lu left=%08lx right=%08lx expected_left=%08lx expected_right=%08lx\n",
       esp_ptr_external_ram(read_buffer), (unsigned long)q->frames, (unsigned long)q->errors, q->invalid, q->training,
       (unsigned long)rx_losses, reader_error, (unsigned long)q->first_frame, (unsigned long)q->first_left, (unsigned long)q->first_right,
       (unsigned long)sample(q->first_frame % 251, false, q->bits), (unsigned long)sample(q->first_frame % 251, true, q->bits));
valid &= q->started && !q->invalid && !q->errors && q->frames >= rate * 99 / 10 && !rx_losses && reader_error == ESP_OK;
report_records("RX0", &checks[0]);
report_records("RX1", &checks[1]);
report_records("QUEUED", q);
puts(valid ? "DUAL-REPLY VERIFIED" : "DUAL-REPLY FAILED payload");
}

void app_main(void) {
  setvbuf(stdout, NULL, _IONBF, 0);
  ESP_ERROR_CHECK(uart_driver_install(UART_NUM_0, 1024, 1024, 0, NULL, 0));
  esp_vfs_dev_uart_use_driver(UART_NUM_0);
  gpio_config_t input = { .pin_bit_mask = (1ULL<<GO)|(1ULL<<1)|(1ULL<<2)|(1ULL<<8)|(1ULL<<39)|(1ULL<<41), .mode = GPIO_MODE_INPUT };
  ESP_ERROR_CHECK(gpio_config(&input));
  ESP_ERROR_CHECK(gpio_pulldown_en(ACK));
  ESP_ERROR_CHECK(gpio_set_level(GO, 0));
  ESP_ERROR_CHECK(gpio_set_direction(GO, GPIO_MODE_INPUT_OUTPUT));
  wire_mounted = xSemaphoreCreateBinary();
  wire_done = xSemaphoreCreateBinary();
  configASSERT(wire_mounted && wire_done);
  writer_done = xSemaphoreCreateBinary();
  configASSERT(writer_done);
  reader_done = xSemaphoreCreateBinary();
  configASSERT(reader_done);
  char line[80];
  while (fgets(line, sizeof(line), stdin)) {
    unsigned hz, bits, external, spi_mode, stall_ms;
    if (!strncmp(line, "PING", 4)) puts("DUAL-REPLY EC618-CONTINUOUS-SPI-v3");
    else if (sscanf(line, "STALL %u", &stall_ms) == 1 && (stall_ms == 0 || stall_ms == 100) && tx && !running) {
      stream_stall_ms = stall_ms;
      puts("DUAL-REPLY OK");
    }
    else if (sscanf(line, "SELFTEST %u", &spi_mode) == 1 && spi_mode <= 1 && !running) {
      close_channels();
      puts(wire_selftest(spi_mode) ? "DUAL-REPLY SELFTEST-PASS" : "DUAL-REPLY FAILED selftest");
    }
    else if (sscanf(line, "PREPARE %u %u %u %u", &hz, &bits, &external, &spi_mode) == 4 && external <= 1 && spi_mode <= 1 && hz && hz <= 96000 && (bits == 16 || bits == 24 || bits == 32)) {
      configure(hz, bits, external, spi_mode);
      puts("DUAL-REPLY READY");
    } else if (!strncmp(line, "START", 5) && tx && !running) {
      if (gpio_get_level(ACK)) { puts("DUAL-REPLY FAILED ACK initially high"); continue; }
      ESP_ERROR_CHECK(i2s_channel_enable(rx[0]));
      ESP_ERROR_CHECK(i2s_channel_enable(tx));
      running = true;
      reader_stop = false;
      reader_running = true;
      configASSERT(xTaskCreate(read_queued, "i2s-reader", 4096, NULL, 5, NULL) == pdPASS);
      writer_stop = false;
      writer_running = true;
      configASSERT(xTaskCreate(write_pattern, "i2s-writer", 4096, NULL, 5, NULL) == pdPASS);
      puts("DUAL-REPLY READY");
      int64_t start = esp_timer_get_time();
      memset(dma_snapshot_count, 0, sizeof(dma_snapshot_count));
      memset(dma_callback_count, 0, sizeof(dma_callback_count));
      memset(dma_last, 0, sizeof(dma_last));
      frame_start();
      gpio_set_level(GO, 1);
      // Clock-source transitions can need live MCLK even when selecting PLL.
      // Keep the strict startup verifier: a late receiver must fail training.
      ESP_ERROR_CHECK(i2s_channel_enable(rx[1]));
      printf("DUAL GO readback=%d ACK=%d\n", gpio_get_level(GO), gpio_get_level(ACK));
      // The permanent EC test raises ACK after verifying ten seconds.
      wire_start();
      bool captured = wait_ack(1);
      wire_halt();
      gpio_set_level(GO, 0);
      halt();
      printf("DUAL STOP elapsed_us=%lld acknowledged=%u\n", (long long)(esp_timer_get_time()-start), captured);
      if (!captured) puts("DUAL-REPLY FAILED capture timeout");
    } else if (!strncmp(line, "RESULT", 6) && tx && !running) report();
    else if (!strncmp(line, "STOP", 4)) { close_channels(); puts("DUAL-REPLY OK"); }
    else puts("DUAL-REPLY FAILED command");
  }
  close_channels();
}
