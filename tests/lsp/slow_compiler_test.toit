// Copyright (C) 2020 Toitware ApS. All rights reserved.

import .lsp_client show LspClient run_client_test
import .mock_compiler
import expect show *
import monitor

main args:
  run_client_test args --use_mock: test it
  run_client_test args --use_toitlsp --use_mock: test it

test client/LspClient:
  // We want to send multiple requests overlapping each other, so we
  //   must not automatically wait for idle.
  client.always_wait_for_idle = false
  mock_compiler := MockCompiler client

  uri := "untitled:Untitled-1"
  path := client.to_path uri

  mutex := monitor.Mutex
  response_counter := 0
  last_clean_diagnostics := -1
  last_error_diagnostics := -1
  client.install_handler "textDocument/publishDiagnostics":: |params|
    // The mutex makes it cleaner to do the checks below with clean data.
    // Without any printing/logging we don't need it, but it's safer to
    //   prepare for such code.
    mutex.do:
      diagnostics_uri := params["uri"]
      if diagnostics_uri == uri:
        if params["diagnostics"].is_empty:
          last_clean_diagnostics = response_counter
        else:
          last_error_diagnostics = response_counter
        response_counter++

  sleep_us := 10
  first_diagnostics_was_ignored := false
  while sleep_us < 1000_000:
    deps := []
    error_diagnostics := [
      MockDiagnostic --path=path "Unresolved identifier: 'foo' RESPONSE FROM MOCK" 1 2 1 5,
    ]
    clean_diagnostics := []

    error_mock_data := MockData error_diagnostics deps
    mock_compiler.set_mock_data --path=path error_mock_data
    error_answer := mock_compiler.build_analysis_answer --delay_us=sleep_us --path=path

    clean_mock_data := MockData clean_diagnostics deps
    mock_compiler.set_mock_data --path=path clean_mock_data
    clean_answer := mock_compiler.build_analysis_answer --delay_us=sleep_us --path=path

    mock_compiler.set_analysis_result error_answer

    client.wait_for_idle

    current_response_counter := response_counter

    client.send_did_open --uri=uri --text="""
      Completely ignored content.
    """

    // Give the server a chance to launch the mock-compiler with the error-mock data.
    sleep --ms=sleep_us / 1000 / 2

    mock_compiler.set_analysis_result clean_answer

    client.send_did_change --uri=uri """
      Also completely ignored
    """

    client.wait_for_idle

    client.send_did_close --path=path

    mutex.do:
      expect last_clean_diagnostics >= current_response_counter
      // Sometimes the mock-update happened before the mock-compiler was run,
      //   and we get two clean diagnostics.
      // The test only succeeds if we end up with just one diagnostic.
      if response_counter == current_response_counter + 1:
        expect last_error_diagnostics < current_response_counter
        first_diagnostics_was_ignored = true
        break
    sleep_us *= 2
  expect first_diagnostics_was_ignored

  client.wait_for_idle
