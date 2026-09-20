// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.

// Exposes a PTY master over stdin/stdout for the Toit protocol regression.
// The first stdout line names the slave. All subsequent bytes are unmodified.
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static bool copy_bytes(int input, int output) {
  char buffer[4096];
  ssize_t count = read(input, buffer, sizeof(buffer));
  if (count <= 0) return false;
  for (ssize_t sent = 0; sent < count;) {
    ssize_t written = write(output, buffer + sent, count - sent);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) return false;
    sent += written;
  }
  return true;
}

int main() {
  int master = posix_openpt(O_RDWR | O_NOCTTY);
  if (master < 0 || grantpt(master) || unlockpt(master)) return 1;
  char* name = ptsname(master);
  if (!name) return 1;
  // Keep the slave open so reads do not fail before the uploader connects.
  int slave = open(name, O_RDWR | O_NOCTTY);
  if (slave < 0) return 1;
  printf("%s\n", name);
  fflush(stdout);
  pollfd ports[] = {{STDIN_FILENO, POLLIN, 0}, {master, POLLIN, 0}};
  while (true) {
    int result = poll(ports, 2, -1);
    if (result < 0 && errno == EINTR) continue;
    if (result < 0) return 1;
    if (ports[0].revents & (POLLIN | POLLHUP | POLLERR)) {
      if (!copy_bytes(STDIN_FILENO, master)) break;
    }
    if (ports[1].revents & (POLLIN | POLLHUP | POLLERR)) {
      if (!copy_bytes(master, STDOUT_FILENO)) break;
    }
  }
  close(slave);
  close(master);
  return 0;
}
