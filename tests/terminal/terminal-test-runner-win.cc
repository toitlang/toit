// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#include <windows.h>

#include <stdio.h>
#include <stdlib.h>

#include <cstdint>
#include <string>
#include <vector>

static void fail(const char* message, const std::string& output = "") {
  fprintf(stderr, "%s (error %lu)\n", message, GetLastError());
  if (!output.empty()) fprintf(stderr, "terminal output:\n%s\n", output.c_str());
  exit(1);
}

static void close_if_valid(HANDLE handle) {
  if (handle != NULL && handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
}

static void write_byte(HANDLE handle, char value) {
  DWORD written = 0;
  if (!WriteFile(handle, &value, 1, &written, NULL) || written != 1) {
    fail("failed to write to pseudoconsole");
  }
}

int main(int argc, char** argv) {
  if (argc != 3) fail("usage: terminal-test-runner TOIT_RUN TEST");

  HANDLE input_read = NULL;
  HANDLE input_write = NULL;
  HANDLE output_read = NULL;
  HANDLE output_write = NULL;
  if (!CreatePipe(&input_read, &input_write, NULL, 0) ||
      !CreatePipe(&output_read, &output_write, NULL, 0)) {
    fail("failed to create pseudoconsole pipes");
  }

  COORD initial_size = {80, 24};
  HPCON pseudoconsole = NULL;
  HRESULT result = CreatePseudoConsole(
      initial_size,
      input_read,
      output_write,
      0,
      &pseudoconsole);
  if (FAILED(result)) {
    SetLastError(HRESULT_CODE(result));
    fail("failed to create pseudoconsole");
  }

  SIZE_T attribute_bytes = 0;
  InitializeProcThreadAttributeList(NULL, 1, 0, &attribute_bytes);
  std::vector<uint8_t> attribute_storage(attribute_bytes);

  STARTUPINFOEXA startup = {};
  startup.StartupInfo.cb = sizeof(startup);
  startup.lpAttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(
      attribute_storage.data());
  if (!InitializeProcThreadAttributeList(
          startup.lpAttributeList,
          1,
          0,
          &attribute_bytes) ||
      !UpdateProcThreadAttribute(
          startup.lpAttributeList,
          0,
          PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
          pseudoconsole,
          sizeof(pseudoconsole),
          NULL,
          NULL)) {
    fail("failed to prepare pseudoconsole process attributes");
  }

  std::string command_line = "\"" + std::string(argv[1]) + "\" \"" + argv[2] + "\"";
  PROCESS_INFORMATION process = {};
  if (!CreateProcessA(
          argv[1],
          &command_line[0],
          NULL,
          NULL,
          FALSE,
          EXTENDED_STARTUPINFO_PRESENT,
          NULL,
          NULL,
          &startup.StartupInfo,
          &process)) {
    fail("failed to start terminal test");
  }

  close_if_valid(input_read);
  close_if_valid(output_write);
  input_read = output_write = NULL;

  std::string output;
  bool sent_input = false;
  bool resized = false;
  bool saw_done = false;
  ULONGLONG deadline = GetTickCount64() + 10 * 1000;

  while (!saw_done && GetTickCount64() < deadline) {
    DWORD available = 0;
    if (!PeekNamedPipe(output_read, NULL, 0, NULL, &available, NULL)) {
      fail("failed to inspect pseudoconsole output", output);
    }
    if (available > 0) {
      char buffer[512];
      DWORD count = 0;
      DWORD to_read = available < sizeof(buffer) ? available : sizeof(buffer);
      if (!ReadFile(output_read, buffer, to_read, &count, NULL)) {
        fail("failed to read pseudoconsole output", output);
      }
      output.append(buffer, count);
    }

    if (!sent_input && output.find("RAW") != std::string::npos) {
      write_byte(input_write, 'x');
      sent_input = true;
    }
    if (!resized && output.find("WATCHING") != std::string::npos) {
      COORD resized_size = {100, 30};
      result = ResizePseudoConsole(pseudoconsole, resized_size);
      if (FAILED(result)) {
        SetLastError(HRESULT_CODE(result));
        fail("failed to resize pseudoconsole", output);
      }
      resized = true;
    }
    saw_done = output.find("DONE") != std::string::npos;

    if (!saw_done && WaitForSingleObject(process.hProcess, 0) == WAIT_OBJECT_0) {
      fail("terminal test exited before completion", output);
    }
    if (!saw_done) Sleep(10);
  }

  if (!saw_done) fail("terminal test timed out", output);
  if (WaitForSingleObject(process.hProcess, 5 * 1000) != WAIT_OBJECT_0) {
    fail("terminal test did not exit", output);
  }

  DWORD exit_code = 0;
  if (!GetExitCodeProcess(process.hProcess, &exit_code) || exit_code != 0) {
    fail("terminal test process failed", output);
  }
  if (!sent_input || !resized) {
    fail("terminal test did not exercise every state", output);
  }

  DeleteProcThreadAttributeList(startup.lpAttributeList);
  close_if_valid(process.hThread);
  close_if_valid(process.hProcess);
  close_if_valid(input_write);
  close_if_valid(output_read);
  ClosePseudoConsole(pseudoconsole);
  return 0;
}
