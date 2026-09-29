// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import { run } from "./toit.mjs";

const PROGRAMS = ["hello", "tasks", "dom", "fetch", "fib", "throw"];

const nav = document.getElementById("programs");
const runButton = document.getElementById("run");
const status = document.getElementById("status");
const source = document.getElementById("source");
const stage = document.getElementById("stage");
const output = document.getElementById("output");

let selected = null;

function append(line, kind) {
  const span = document.createElement("span");
  span.className = kind;
  span.textContent = line + "\n";
  output.append(span);
}

async function select(name) {
  selected = name;
  for (const button of nav.children) {
    button.setAttribute("aria-current", String(button.dataset.name === name));
  }
  source.textContent = await (await fetch(`programs/${name}.toit`)).text();
  stage.hidden = true;
  output.textContent = "";
  status.textContent = "";
}

// Runs the program and returns its exit code and output lines.
async function runProgram(name) {
  const lines = [];
  output.textContent = "";
  stage.hidden = true;
  status.textContent = "Running…";
  runButton.disabled = true;
  const start = performance.now();
  try {
    const response = await fetch(`programs/${name}.snapshot`);
    const snapshot = new Uint8Array(await response.arrayBuffer());
    const code = await run(snapshot, {
      args: ["from", "the", "browser"],
      stdout: (line) => { lines.push(line); append(line, "out"); },
      stderr: (line) => { lines.push(line); append(line, "err"); },
      // Functions the Toit programs call with 'js.call'.
      functions: {
        setStage: (text) => {
          stage.hidden = false;
          stage.textContent = text;
        },
        fetchJson: async (url) => (await fetch(url)).json(),
      },
    });
    const elapsed = Math.round(performance.now() - start);
    status.textContent = `Exited with code ${code} after ${elapsed} ms.`;
    return { code, lines };
  } finally {
    runButton.disabled = false;
  }
}

for (const name of PROGRAMS) {
  const button = document.createElement("button");
  button.type = "button";
  button.dataset.name = name;
  button.textContent = `${name}.toit`;
  button.addEventListener("click", () => select(name));
  nav.append(button);
}
runButton.addEventListener("click", () => runProgram(selected));

await select(PROGRAMS[0]);

// For automated tests: '?autorun=hello,tasks' runs the programs and posts
// the results to '/__report'.
const params = new URLSearchParams(location.search);
if (params.has("autorun")) {
  const results = {};
  for (const name of params.get("autorun").split(",")) {
    await select(name);
    try {
      results[name] = await runProgram(name);
    } catch (e) {
      results[name] = { error: String(e) };
    }
  }
  await fetch("/__report", { method: "POST", body: JSON.stringify(results) });
}
