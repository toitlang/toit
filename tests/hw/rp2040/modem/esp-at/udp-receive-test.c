// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
#include <arpa/inet.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include "esp_at_core.h"

extern bool toit_udp_cmd_register(void);
static const esp_at_cmd_struct* command;
static int socket_fd = -1;
static int32_t parameter;
static int32_t remote_port;
static char* remote_address = "127.0.0.1";
static int parse_error;
static int short_write;
static uint8_t output[2048];
static int output_length;
static int write_count;

int32_t esp_at_get_socket_by_link_id(uint8_t link_id) {
  return link_id == 0 ? socket_fd : -1;
}
int esp_at_get_para_as_digit(int index, int32_t* value) {
  assert(index == 0 || index == 2);
  *value = index == 0 ? parameter : remote_port;
  return parse_error;
}
int esp_at_get_para_as_str(int index, uint8_t** value) {
  assert(index == 1);
  *value = (uint8_t*)remote_address;
  return parse_error;
}
int32_t esp_at_port_write_data(uint8_t* data, int32_t length) {
  assert(length >= 0 && (size_t)length <= sizeof(output));
  memcpy(output, data, length);
  output_length = length;
  write_count++;
  return short_write ? length - 1 : length;
}
bool esp_at_custom_cmd_array_regist(const esp_at_cmd_struct* commands, uint32_t count) {
  assert(count == 2 && strcmp(commands[0].at_cmdName, "+TOITUDP") == 0);
  assert(strcmp(commands[1].at_cmdName, "+TOITUDPEMPTY") == 0);
  command = commands;
  return true;
}
static int bind_udp(struct sockaddr_in* address) {
  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  assert(fd >= 0);
  *address = (struct sockaddr_in){.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
  assert(bind(fd, (struct sockaddr*)address, sizeof(*address)) == 0);
  socklen_t length = sizeof(*address);
  assert(getsockname(fd, (struct sockaddr*)address, &length) == 0);
  return fd;
}
static void send_packet(int fd, struct sockaddr_in* destination, const uint8_t* data, size_t length) {
  assert(sendto(fd, data, length, 0, (struct sockaddr*)destination, sizeof(*destination)) == (ssize_t)length);
}
static void expect_packet(const uint8_t* data, size_t length, unsigned port) {
  write_count = 0;
  assert(command->at_setupCmd(1) == ESP_AT_RESULT_CODE_OK);
  assert(write_count == 1);
  char header[96];
  int header_length = snprintf(header, sizeof(header), "+TOITUDP:%zu,\"127.0.0.1\",%u,", length, port);
  assert(output_length == header_length + (int)length + 2);
  assert(memcmp(output, header, header_length) == 0);
  assert(memcmp(output + header_length, data, length) == 0);
  assert(memcmp(output + header_length + length, "\r\n", 2) == 0);
}
static void expect_status(const char* status) {
  assert(command->at_setupCmd(1) == ESP_AT_RESULT_CODE_OK);
  assert(output_length == (int)strlen(status));
  assert(memcmp(output, status, output_length) == 0);
}
int main(void) {
  assert(toit_udp_cmd_register());
  assert(command->at_queryCmd(NULL) == ESP_AT_RESULT_CODE_OK);
  assert(output_length == 17 && memcmp(output, "+TOITUDP:2,1460\r\n", 17) == 0);
  assert(command->at_setupCmd(0) == ESP_AT_RESULT_CODE_ERROR);
  assert(command->at_setupCmd(2) == ESP_AT_RESULT_CODE_ERROR);
  parameter = -1;
  assert(command->at_setupCmd(1) == ESP_AT_RESULT_CODE_ERROR);
  parameter = 256;
  assert(command->at_setupCmd(1) == ESP_AT_RESULT_CODE_ERROR);
  parameter = 1;
  assert(command->at_setupCmd(1) == ESP_AT_RESULT_CODE_ERROR);
  parameter = 0;
  parse_error = 1;
  assert(command->at_setupCmd(1) == ESP_AT_RESULT_CODE_ERROR);
  parse_error = 0;
  assert(command->at_setupCmd(1) == ESP_AT_RESULT_CODE_ERROR);
  socket_fd = socket(AF_INET, SOCK_STREAM, 0);
  assert(command->at_setupCmd(1) == ESP_AT_RESULT_CODE_ERROR);
  close(socket_fd);
  struct sockaddr_in destination, first_address, second_address;
  socket_fd = bind_udp(&destination);
  int first = bind_udp(&first_address);
  int second = bind_udp(&second_address);
  unsigned first_port = ntohs(first_address.sin_port);
  unsigned second_port = ntohs(second_address.sin_port);
  uint8_t data[1461];
  assert(command[1].at_setupCmd(1) == ESP_AT_RESULT_CODE_ERROR);
  remote_port = first_port;
  assert(command[1].at_setupCmd(3) == ESP_AT_RESULT_CODE_OK);
  struct sockaddr_in sender;
  socklen_t sender_length = sizeof(sender);
  assert(recvfrom(first, data, sizeof(data), MSG_DONTWAIT,
                  (struct sockaddr*)&sender, &sender_length) == 0);
  assert(sender.sin_port == destination.sin_port);
  assert(recvfrom(first, data, sizeof(data), MSG_DONTWAIT, NULL, NULL) == -1);
  remote_address = "bad address";
  assert(command[1].at_setupCmd(3) == ESP_AT_RESULT_CODE_ERROR);
  remote_address = "127.0.0.1";
  remote_port = 0;
  assert(command[1].at_setupCmd(3) == ESP_AT_RESULT_CODE_ERROR);
  remote_port = 65536;
  assert(command[1].at_setupCmd(3) == ESP_AT_RESULT_CODE_ERROR);
  parameter = 1;
  assert(command[1].at_setupCmd(3) == ESP_AT_RESULT_CODE_ERROR);
  parameter = 0;
  for (size_t i = 0; i < sizeof(data); i++) data[i] = (i * 37) & 255;
  expect_status("+TOITUDP:-1\r\n");
  send_packet(first, &destination, data, 97);
  send_packet(second, &destination, data, 211);
  expect_packet(data, 97, first_port);
  expect_packet(data, 211, second_port);
  send_packet(first, &destination, data, 1009);
  send_packet(second, &destination, data, 907);
  expect_packet(data, 1009, first_port);
  expect_packet(data, 907, second_port);
  send_packet(first, &destination, data, 0);
  send_packet(second, &destination, data, 1460);
  expect_packet(data, 0, first_port);
  expect_packet(data, 1460, second_port);
  send_packet(first, &destination, data, 1461);
  send_packet(second, &destination, data, 3);
  expect_status("+TOITUDP:-2\r\n");
  expect_packet(data, 3, second_port);
  expect_status("+TOITUDP:-1\r\n");
  short_write = 1;
  assert(command->at_setupCmd(1) == ESP_AT_RESULT_CODE_ERROR);
  close(first);
  close(second);
  close(socket_fd);
  puts("ESP-AT datagram extension host sockets: PASS");
  return 0;
}
