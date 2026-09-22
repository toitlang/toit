// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Optional Linux test tool. Adapter policy is an independently compiled Toit
// program; this boundary only owns the lock, processes, signals and deadlines.
#include <sys/file.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <cerrno>
#include <chrono>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

namespace {
volatile sig_atomic_t interrupted = 0;
void interrupt(int signal) { if (!interrupted) interrupted = signal; }

long long milliseconds() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now().time_since_epoch()).count();
}

struct Result {
  int code;
  std::string output;
};

Result run(const std::vector<std::string>& command, bool capture,
           int timeout_ms, bool restoring = false) {
  int output[2] = {-1, -1};
  if (capture && pipe2(output, O_CLOEXEC) != 0) return {125, ""};
  if (capture) {
    int result;
    do { result = fcntl(output[0], F_SETFL, O_NONBLOCK); } while (result < 0 && errno == EINTR);
    if (result < 0) {
      close(output[0]);
      close(output[1]);
      return {125, ""};
    }
  }
  std::vector<char*> arguments;
  for (const auto& value : command) arguments.push_back(const_cast<char*>(value.c_str()));
  arguments.push_back(nullptr);
  pid_t pid = fork();
  if (pid == 0) {
    if (setpgid(0, 0) != 0) _exit(125);
    signal(SIGINT, SIG_DFL);
    signal(SIGTERM, SIG_DFL);
    if (capture) {
      close(output[0]);
      if (dup2(output[1], STDOUT_FILENO) < 0) _exit(125);
      close(output[1]);
    }
    execvp(arguments[0], arguments.data());
    perror("BLE supervisor: exec");
    _exit(127);
  }
  if (capture) close(output[1]);
  if (pid < 0) {
    if (capture) close(output[0]);
    return {125, ""};
  }
  // The child also sets its group before exec, closing the parent/exec race.
  if (setpgid(pid, pid) < 0 && errno != EACCES && errno != ESRCH) {
    kill(pid, SIGKILL);
    while (waitpid(pid, nullptr, 0) < 0 && errno == EINTR) {}
    if (capture) close(output[0]);
    return {125, ""};
  }
  const auto started = milliseconds();
  long long stopping = 0;
  int forced_code = 0;
  int status = 0;
  std::string captured;
  auto drain = [&]() {
    if (!capture) return;
    char buffer[256];
    ssize_t size;
    while ((size = read(output[0], buffer, sizeof(buffer))) > 0) {
      if (captured.size() + size > 1024) {
        forced_code = 125;
        break;
      }
      captured.append(buffer, size);
    }
  };
  while (true) {
    drain();
    pid_t waited = waitpid(pid, &status, WNOHANG);
    if (waited == pid) break;
    if (waited < 0 && errno != EINTR) { forced_code = 125; break; }
    auto now = milliseconds();
    if (!restoring && interrupted) forced_code = 128 + interrupted;
    if (timeout_ms && now - started >= timeout_ms && !forced_code) forced_code = 124;
    if (forced_code && !stopping) {
      stopping = now;
      kill(-pid, SIGTERM);
    }
    if (stopping && now - stopping >= 1000) kill(-pid, SIGKILL);
    if (stopping && now - stopping >= 4000) { forced_code = 125; break; }
    usleep(10000);
  }
  // A peer may exit while leaving a descendant alive. Clean and reap the whole
  // supervised group before returning, including adopted orphan descendants.
  kill(-pid, SIGKILL);
  const auto reap_deadline = milliseconds() + 3000;
  while (true) {
    pid_t child = waitpid(-pid, nullptr, WNOHANG);
    if (child > 0) continue;
    if (child < 0 && errno == ECHILD) break;
    if (child < 0 && errno != EINTR) { forced_code = 125; break; }
    if (milliseconds() >= reap_deadline) { forced_code = 125; break; }
    usleep(10000);
  }
  drain();
  if (capture) close(output[0]);
  int code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
  return {forced_code ? forced_code : code, captured};
}

int lock_adapter(const std::string& path) {
  const int flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK;
  int fd = open(path.c_str(), flags);
  if (fd < 0 && errno == ENOENT) {
    fd = open(path.c_str(), flags | O_CREAT | O_EXCL, 0600);
    if (fd < 0 && errno == EEXIST) fd = open(path.c_str(), flags);
  }
  if (fd < 0) return -1;
  struct stat info;
  if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || flock(fd, LOCK_EX | LOCK_NB) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}
}  // namespace

int main(int argc, char** argv) {
  if (argc < 7 || std::string(argv[5]) != "--") {
    fprintf(stderr, "Usage: ble-hci-supervisor INDEX ADDRESS VM POLICY_SNAPSHOT -- COMMAND [ARGS...]\n");
    return 2;
  }
  char* end = nullptr;
  errno = 0;
  long index = strtol(argv[1], &end, 10);
  if (errno || !*argv[1] || *end || index < 0 || index >= 0xffff) return 2;
  std::string address(argv[2]);
  if (address.size() != 17) return 2;
  std::string compact;
  for (size_t i = 0; i < address.size(); i++) {
    unsigned char character = address[i];
    if (i % 3 == 2) {
      if (character != ':') return 2;
    } else {
      if (!std::isxdigit(character)) return 2;
      compact += static_cast<char>(std::tolower(character));
    }
  }
  if (prctl(PR_SET_CHILD_SUBREAPER, 1) < 0) return 125;
  struct sigaction action = {};
  action.sa_handler = interrupt;
  sigemptyset(&action.sa_mask);
  if (sigaction(SIGINT, &action, nullptr) || sigaction(SIGTERM, &action, nullptr)) return 125;
  int lock = lock_adapter("/tmp/toit-hci-" + compact + ".lock");
  if (lock < 0) {
    fprintf(stderr, "BLE supervisor: adapter lock unavailable or unsafe\n");
    return 125;
  }
  auto policy = [&](const char* mode, bool restoring = false) {
    return run({argv[3], argv[4], argv[1], argv[2], mode}, true, 10000, restoring);
  };
  auto original = policy("state");
  if (original.code || (original.output != "on\n" && original.output != "off\n") || interrupted) {
    close(lock);
    fprintf(stderr, "BLE supervisor: initial adapter state unavailable; no power change attempted\n");
    return interrupted ? 128 + interrupted : 125;
  }
  auto off = policy("power-off");
  int child_code = 125;
  bool child_started = false;
  if (!off.code && off.output == "off\n" && !interrupted) {
    std::vector<std::string> command(argv + 6, argv + argc);
    child_started = true;
    child_code = run(command, false, 0).code;
  }
  auto restored = policy(original.output == "on\n" ? "power-on" : "power-off", true);
  bool restoration_ok = !restored.code && restored.output == original.output;
  fprintf(stderr, "BLE_SUPERVISOR child-started=%s child-exit=%d restoration-verified=%s signal=%d\n",
          child_started ? "true" : "false", child_code,
          restoration_ok ? "true" : "false", static_cast<int>(interrupted));
  close(lock);
  if (!restoration_ok) return 125;
  if (interrupted) return 128 + interrupted;
  return child_code;
}
