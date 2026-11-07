// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.

// Experimental ESP-AT extension. The caller must select CIPRECVMODE=1 first.
// Unlike CIPRECVDATA, this performs exactly one nonblocking UDP receive and
// distinguishes an empty datagram from an empty queue. AT command execution
// serializes access to the reply buffer; this is not a receive-task callback.
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#ifdef TOIT_AT_HOST_TEST
#include <arpa/inet.h>
#include <sys/socket.h>
#else
#include "lwip/sockets.h"
#include "lwip/inet.h"
#endif
#include "esp_at_core.h"

// Exported by the pinned ESP8266 AT core (6cdf453); the older public header
// omits this declaration. Newer ESP-AT headers document the same signature.
extern int32_t esp_at_get_socket_by_link_id(uint8_t link_id);

#define TOIT_UDP_MTU 1460
#define TOIT_UDP_HEADER 96
static uint8_t reply[TOIT_UDP_HEADER + TOIT_UDP_MTU + 1 + 2];

static uint8_t write_reply(size_t length) {
  return esp_at_port_write_data(reply, length) == (int32_t)length
      ? ESP_AT_RESULT_CODE_OK : ESP_AT_RESULT_CODE_ERROR;
}

static uint8_t query_udp(uint8_t* command_name) {
  (void)command_name;
  int length = snprintf((char*)reply, sizeof(reply), "+TOITUDP:2,%d\r\n", TOIT_UDP_MTU);
  return write_reply(length);
}

static int udp_socket(void) {
  int32_t link_id;
  if (esp_at_get_para_as_digit(0, &link_id) != ESP_AT_PARA_PARSE_RESULT_OK ||
      link_id < 0 || link_id > 255) {
    return -1;
  }
  int fd = esp_at_get_socket_by_link_id((uint8_t)link_id);
  int type = 0;
  socklen_t type_length = sizeof(type);
  if (fd < 0 || getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &type_length) != 0 ||
      type != SOCK_DGRAM) {
    return -1;
  }
  return fd;
}

static uint8_t send_empty_udp(uint8_t parameter_count) {
  if (parameter_count != 3) return ESP_AT_RESULT_CODE_ERROR;
  int fd = udp_socket();
  uint8_t* address;
  int32_t port;
  struct sockaddr_in remote = {0};
  remote.sin_family = AF_INET;
  if (fd < 0 ||
      esp_at_get_para_as_str(1, &address) != ESP_AT_PARA_PARSE_RESULT_OK ||
      esp_at_get_para_as_digit(2, &port) != ESP_AT_PARA_PARSE_RESULT_OK ||
      port < 1 || port > 65535 ||
      inet_pton(AF_INET, (const char*)address, &remote.sin_addr) != 1) {
    return ESP_AT_RESULT_CODE_ERROR;
  }
  remote.sin_port = htons((uint16_t)port);
  // CIPSEND rejects length zero, and CIPSENDEX's empty terminator acknowledges
  // without emitting a packet. Send exactly one empty datagram directly.
  return sendto(fd, "", 0, MSG_DONTWAIT,
                (struct sockaddr*)&remote, sizeof(remote)) == 0
      ? ESP_AT_RESULT_CODE_OK : ESP_AT_RESULT_CODE_ERROR;
}

static uint8_t receive_udp(uint8_t parameter_count) {
  if (parameter_count != 1) return ESP_AT_RESULT_CODE_ERROR;
  int fd = udp_socket();
  if (fd < 0) return ESP_AT_RESULT_CODE_ERROR;

  struct sockaddr_in remote = {0};
  socklen_t remote_length = sizeof(remote);
  // Read one byte beyond our MTU so an oversized datagram is discarded rather
  // than delivered as a silently truncated packet. recvfrom consumes only one
  // datagram, including when that datagram has zero bytes.
  int count = recvfrom(fd, reply + TOIT_UDP_HEADER, TOIT_UDP_MTU + 1,
                      MSG_DONTWAIT, (struct sockaddr*)&remote, &remote_length);
  if (count < 0) {
    if (errno != EAGAIN && errno != EWOULDBLOCK) return ESP_AT_RESULT_CODE_ERROR;
    memcpy(reply, "+TOITUDP:-1\r\n", 13);
    return write_reply(13);
  }
  if (count > TOIT_UDP_MTU) {
    memcpy(reply, "+TOITUDP:-2\r\n", 13);
    return write_reply(13);
  }
  char address[INET_ADDRSTRLEN];
  if (remote_length != sizeof(remote) || remote.sin_family != AF_INET ||
      !inet_ntop(AF_INET, &remote.sin_addr, address, sizeof(address))) {
    return ESP_AT_RESULT_CODE_ERROR;
  }
  int header_length = snprintf((char*)reply, TOIT_UDP_HEADER,
      "+TOITUDP:%d,\"%s\",%u,", count, address, (unsigned)ntohs(remote.sin_port));
  if (header_length < 0 || header_length >= TOIT_UDP_HEADER) return ESP_AT_RESULT_CODE_ERROR;
  memmove(reply + header_length, reply + TOIT_UDP_HEADER, count);
  reply[header_length + count] = '\r';
  reply[header_length + count + 1] = '\n';
  // Emit the header and binary payload in one transport write.
  return write_reply(header_length + count + 2);
}

bool toit_udp_cmd_register(void) {
  static const esp_at_cmd_struct commands[] = {
    {"+TOITUDP", NULL, query_udp, receive_udp, NULL},
    {"+TOITUDPEMPTY", NULL, NULL, send_empty_udp, NULL},
  };
  return esp_at_custom_cmd_array_regist(commands, sizeof(commands) / sizeof(commands[0]));
}
