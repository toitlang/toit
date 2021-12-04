// Copyright (C) 2020 Toitware ApS.
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

#include <stdlib.h>

#ifdef __linux__
#include <cstddef>
#include <stdio.h>
#include <unistd.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <sys/prctl.h>
#include <sys/syscall.h>

#include "sandbox.h"
#endif

namespace toit {

#if defined(__linux__) && !defined(__arm__)
static int COMPILER_SYSCALLS[] = {
  SYS_brk,
  SYS_rt_sigreturn,
  SYS_read,
  SYS_write,
  SYS_exit,
  SYS_exit_group,
  SYS_close,
#if BUILD_32
  SYS_fstat64,
  SYS__llseek,
  SYS_mmap2,
#else
  SYS_fstat,
  SYS_lseek,
  SYS_mmap,
#endif
  SYS_rt_sigaction,
  SYS_time,
  SYS_pipe,
  SYS_pipe2,
  SYS_set_robust_list,
  SYS_mprotect,
  SYS_madvise,
  SYS_munmap,
  SYS_futex,
  SYS_epoll_create1,
  SYS_epoll_ctl,
  SYS_epoll_wait,
  SYS_getpid,
  SYS_getuid,
  SYS_geteuid,
  SYS_getgid,
  SYS_gettid,
  SYS_getrandom,
  SYS_rt_sigprocmask,
  SYS_getsockopt,
  SYS_fadvise64,
  SYS_shutdown,
  SYS_poll,
  -1
};

static int MOST_SYSCALLS[] = {
  SYS_open,
  SYS_openat,
  SYS_readlink,
  SYS_readlinkat,
  SYS_clone,
  SYS_getppid,
  SYS_kill,
#if BUILD_32
  SYS_waitpid,
  SYS_fstat64,
  SYS_lstat64,
  SYS_stat64,
  SYS_mmap2,
  SYS_accept4,
  SYS_fcntl64,
  // This is a common entry point for several socket calls on 32 bit kernels.
  // There are now separate entry points, but this one is still used sometimes.
  SYS_socketcall,
#elif BUILD_64
  SYS_wait4,
  SYS_fstat,
  SYS_lstat,
  SYS_stat,
  SYS_mmap,
  SYS_prlimit64,
  SYS_newfstatat,
  SYS_accept,
  SYS_fcntl,
#else
# error "Neither BUILD_32 nor BUILD_64!"
#endif
  SYS_munmap,
  SYS_getcwd,
  SYS_statfs,
  SYS_umask,
  SYS_mkdir,
  SYS_mkdirat,
  SYS_fchdir,
  SYS_dup,
  SYS_dup2,
  SYS_arch_prctl,
  SYS_prctl,
  SYS_set_tid_address,
  SYS_execve,
  SYS_access,
  SYS_ioctl,
  SYS_getdents,
  SYS_unlinkat,
  SYS_socket,
  SYS_setsockopt,
  SYS_bind,
  SYS_listen,
  SYS_getsockname,
  SYS_sendto,
  SYS_recvmsg,
  SYS_connect,
  SYS_recvfrom,
  SYS_fadvise64,
  -1
};

static int SANDBOX_SYSCALLS[] = {
  SYS_brk,
  SYS_rt_sigreturn,
  SYS_read,
  SYS_write,
  SYS_exit,
  SYS_exit_group,
  SYS_close,
#if BUILD_32
  SYS__llseek,
#else
  SYS_lseek,
#endif
  SYS_rt_sigaction,
  SYS_time,
  SYS_pipe,
  SYS_pipe2,
  SYS_set_robust_list,
  SYS_mprotect,
  SYS_madvise,
  SYS_futex,
  SYS_epoll_create1,
  SYS_epoll_ctl,
  SYS_epoll_wait,
  SYS_getpid,
  SYS_getuid,
  SYS_geteuid,
  SYS_getegid,
  SYS_getgid,
  SYS_gettid,
  SYS_getrandom,
  SYS_rt_sigprocmask,
  SYS_getsockopt,
  SYS_fadvise64,
  SYS_shutdown,
  SYS_poll,
  -1
};
#endif

void enable_sandbox(int flags) {
#if defined(__linux__) && !defined(__arm__)
  const int MAX_INSTRUCTIONS = 300;
  const int MAX_SYSCALLS = 1500;
  sock_filter* instructions = reinterpret_cast<sock_filter*>(calloc(MAX_INSTRUCTIONS, sizeof(sock_filter)));
  if (!instructions) abort();
  bool* allowed = reinterpret_cast<bool*>(calloc(MAX_SYSCALLS, sizeof(bool)));
  if (!allowed) abort();

  if ((flags & ALLOW_SANDBOX_CALLS) != 0) {
    for (const int* p = SANDBOX_SYSCALLS; *p != -1; p++) {
      int call = *p;
      if (call < 0 || call >= MAX_SYSCALLS) abort();
      allowed[call] = true;
    }
  }
  if ((flags & ALLOW_COMPILER_CALLS) != 0) {
    for (const int* p = COMPILER_SYSCALLS; *p != -1; p++) {
      int call = *p;
      if (call < 0 || call >= MAX_SYSCALLS) abort();
      allowed[call] = true;
    }
  }

  if ((flags & ALLOW_MOST_CALLS) != 0) {
    for (const int* p = MOST_SYSCALLS; *p != -1; p++) {
      int call = *p;
      if (call < 0 || call >= MAX_SYSCALLS) abort();
      allowed[call] = true;
    }
  }

  int number_of_allowed = 0;
  for (int i = 0; i < MAX_SYSCALLS; i++) {
    if (allowed[i]) number_of_allowed++;
  }
  // There's a limit to the reach of a relative jump in the BPF bytecodes, so
  // we have a limit here.
  if (number_of_allowed >= 256) abort();

  int program_counter = 0;
  // Load architecture number.
  instructions[program_counter++] = BPF_STMT(BPF_LD | BPF_W | BPF_ABS, (offsetof(seccomp_data, arch)));

#if BUILD_32
  unsigned int expected_architecture = AUDIT_ARCH_I386;
#else
  unsigned int expected_architecture = AUDIT_ARCH_X86_64;
#endif
  // Skip next instruction if the architecture is as expected.
  instructions[program_counter++] = BPF_JUMP(BPF_JMP | BPF_JEQ, expected_architecture, 1, 0);

  // Abort if architecture is not as expected.  Note: Using fork-exec the
  // filter list is inherited by subprocesses that may be a different
  // architecture.  Currently this will safely fail at this point.  Normally
  // exec is not allowed by a sandbox anyway, so the issue does not arise, but
  // we could instead have both filter lists in the same BPF program and switch
  // between them here so we always get the syscall filter associated with the
  // current architecture.
  // TODO(florian, erik): change this to SECCOMP_RET_KILL_PROCESS.
  instructions[program_counter++] = BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRAP);

  // Load syscall number.
  instructions[program_counter++] = BPF_STMT(BPF_LD | BPF_W | BPF_ABS, (offsetof(seccomp_data, nr)));

  uint8 jump_distance = number_of_allowed;
  // For each allowed syscall, jump to the allow command.

  for (uint32 i = 0; i < MAX_SYSCALLS; i++) {
    if (allowed[i]) {
      instructions[program_counter++] = BPF_JUMP(BPF_JMP | BPF_JEQ, i, jump_distance, 0);
      if (program_counter >= MAX_INSTRUCTIONS) abort();
      jump_distance--;
    }
  }

  if (jump_distance != 0) abort();

  // For all syscalls not on the allow-list, trap the process.
  // TODO(florian, erik): change this to SECCOMP_RET_KILL_PROCESS.
  instructions[program_counter++] = BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRAP);
  if (program_counter >= MAX_INSTRUCTIONS) abort();

  // This is the target of the allow-jumps.
  instructions[program_counter++] = BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);

  if (program_counter > MAX_INSTRUCTIONS) abort();

  const sock_fprog filter_descriptor = {
    static_cast<unsigned short>(program_counter),
    const_cast<sock_filter*>(&instructions[0])
  };

  int ret;

  ret = prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0, 0);
  if (ret != 0) {
    perror("PR_SET_NO_NEW_PRIVS");
    abort();
  }

  ret = prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &filter_descriptor);
  if (ret != 0) {
    perror("PR_SET_SECCOMP");
    abort();
  }
#else
  abort();  // The BPF syscall sandbox is only supported on Linux.
#endif // __linux__
}

}
