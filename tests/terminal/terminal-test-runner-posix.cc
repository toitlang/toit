// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

#include <string>

static void fail(const char* message, const std::string& output = "") {
  fprintf(stderr, "%s\n", message);
  if (!output.empty()) fprintf(stderr, "terminal output:\n%s\n", output.c_str());
  exit(1);
}

static bool same_mode(const termios& left, const termios& right) {
  return left.c_iflag == right.c_iflag &&
      left.c_oflag == right.c_oflag &&
      left.c_cflag == right.c_cflag &&
      left.c_lflag == right.c_lflag &&
      memcmp(left.c_cc, right.c_cc, sizeof(left.c_cc)) == 0 &&
      cfgetispeed(&left) == cfgetispeed(&right) &&
      cfgetospeed(&left) == cfgetospeed(&right);
}

static void write_byte(int fd, char value) {
  ssize_t result;
  do {
    result = write(fd, &value, 1);
  } while (result < 0 && errno == EINTR);
  if (result != 1) fail("failed to write to pseudo-terminal");
}

int main(int argc, char** argv) {
  if (argc != 3) fail("usage: terminal-test-runner TOIT_RUN TEST");

  winsize initial_size = {};
  initial_size.ws_col = 80;
  initial_size.ws_row = 24;

  int master;
  int slave;
  termios initial_mode;
  if (openpty(&master, &slave, nullptr, nullptr, &initial_size) != 0) {
    fail("failed to open pseudo-terminal");
  }
  if (tcgetattr(slave, &initial_mode) != 0) fail("failed to read terminal mode");
  initial_mode.c_lflag |= ECHO | ICANON | ISIG;
  if (tcsetattr(slave, TCSANOW, &initial_mode) != 0) fail("failed to set terminal mode");

  pid_t child = fork();
  if (child < 0) fail("failed to fork terminal test");
  if (child == 0) {
    close(master);
    if (setsid() < 0) _exit(126);
    if (ioctl(slave, TIOCSCTTY, 0) != 0) _exit(126);
    if (dup2(slave, STDIN_FILENO) < 0 ||
        dup2(slave, STDOUT_FILENO) < 0 ||
        dup2(slave, STDERR_FILENO) < 0) {
      _exit(126);
    }
    if (slave > STDERR_FILENO) close(slave);
    execl(argv[1], argv[1], argv[2], static_cast<char*>(nullptr));
    _exit(127);
  }
  close(slave);

  std::string output;
  std::string pending;
  bool saw_raw = false;
  bool saw_restored = false;
  bool saw_watching = false;
  bool saw_done = false;

  while (!saw_done) {
    pollfd descriptor = { master, POLLIN, 0 };
    int poll_result;
    do {
      poll_result = poll(&descriptor, 1, 10 * 1000);
    } while (poll_result < 0 && errno == EINTR);
    if (poll_result == 0) fail("terminal test timed out", output);
    if (poll_result < 0) fail("failed to poll pseudo-terminal", output);

    char buffer[256];
    ssize_t count;
    do {
      count = read(master, buffer, sizeof(buffer));
    } while (count < 0 && errno == EINTR);
    if (count <= 0) fail("terminal test closed the pseudo-terminal early", output);
    output.append(buffer, count);
    pending.append(buffer, count);

    size_t newline;
    while ((newline = pending.find('\n')) != std::string::npos) {
      std::string line = pending.substr(0, newline);
      pending.erase(0, newline + 1);
      if (!line.empty() && line.back() == '\r') line.pop_back();

      if (line == "RAW") {
        termios raw_mode;
        if (tcgetattr(master, &raw_mode) != 0) fail("failed to read raw mode", output);
        if ((raw_mode.c_lflag & (ECHO | ICANON | ISIG)) != 0) {
          fail("terminal was not placed in raw mode", output);
        }
        saw_raw = true;
        write_byte(master, 'x');
      } else if (line == "RESTORED") {
        termios restored_mode;
        if (tcgetattr(master, &restored_mode) != 0) fail("failed to read restored mode", output);
        if (!same_mode(initial_mode, restored_mode)) {
          fail("terminal mode was not restored", output);
        }
        saw_restored = true;
      } else if (line == "WATCHING") {
        winsize resized = {};
        resized.ws_col = 100;
        resized.ws_row = 30;
        if (ioctl(master, TIOCSWINSZ, &resized) != 0) {
          fail("failed to resize pseudo-terminal", output);
        }
        saw_watching = true;
      } else if (line == "DONE") {
        saw_done = true;
      }
    }
  }

  int status;
  pid_t waited;
  do {
    waited = waitpid(child, &status, 0);
  } while (waited < 0 && errno == EINTR);
  close(master);
  if (waited != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    fail("terminal test process failed", output);
  }
  if (!saw_raw || !saw_restored || !saw_watching) {
    fail("terminal test did not exercise every state", output);
  }
  return 0;
}
