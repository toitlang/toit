// Copyright (C) 2026 Toit contributors.
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

import encoding.json
import encoding.hex
import http
import http.server
import net
import net.modules.tcp

import .api as api
import .format as format

serve capture/format.Capture port/int -> none:
  network := net.open
  socket := tcp.TcpServerSocket network
  socket.listen "127.0.0.1" port
  actual-port := socket.local-address.port
  print (json.stringify {
    "event": "listening",
    "url": "http://127.0.0.1:$actual-port/",
    "api": "http://127.0.0.1:$actual-port/api/v1",
    "capture-id": capture.id,
  })
  server := http.Server --max-tasks=20
  server.listen socket:: | request/http.RequestIncoming writer/http.ResponseWriter |
    handle capture request writer

handle capture/format.Capture request/http.RequestIncoming writer/http.ResponseWriter -> none:
  if request.method != http.GET:
    write-error writer 405 "METHOD_NOT_ALLOWED" "Only GET is supported."
    return
  resource := request.query.resource
  if resource == "/":
    write-html writer INDEX-HTML_
    return
  if resource == "/api/v1":
    write-json writer 200 (api.discovery capture)
    return
  if resource == "/api/v1/openapi.json":
    write-json writer 200 api.openapi
    return
  if resource == "/api/v1/captures":
    write-json writer 200 {
      "items": [api.capture-summary capture],
      "offset": 0,
      "limit": 1,
      "total": 1,
      "next-offset": null,
    }
    return

  prefix := "/api/v1/captures/$(capture.id)"
  if resource == prefix:
    write-json writer 200 (api.capture-detail capture)
    return
  if resource == "$prefix/regions":
    catch-domain-error writer:
      offset := query-int request "offset" 0
      limit := query-int request "limit" api.DEFAULT-LIMIT
      write-json writer 200 (api.regions-page capture offset limit)
    return
  if resource.starts-with "$prefix/regions/":
    id := resource["$prefix/regions/".size..]
    catch-domain-error writer:
      write-json writer 200 (api.region-detail capture id)
    return
  if resource == "$prefix/memory":
    address-value := request.query.parameters.get "address"
    if not address-value or not address-value is string:
      write-error writer 400 "INVALID_ADDRESS" "The address query parameter must be one hexadecimal string."
      return
    catch-domain-error writer:
      length := query-int request "length" 256
      address := format.parse-address address-value
      write-json writer 200 (api.memory-read capture address length)
    return
  if resource == "$prefix/memory/search":
    pattern-value := request.query.parameters.get "hex"
    if not pattern-value or not pattern-value is string:
      write-error writer 400 "INVALID_SEARCH_PATTERN" "The hex query parameter must be one hexadecimal string."
      return
    catch-domain-error writer:
      pattern := hex.decode pattern-value
      limit := query-int request "limit" 100
      write-json writer 200 (api.memory-search capture pattern limit)
    return
  if resource.starts-with "$prefix/words/":
    address-value := resource["$prefix/words/".size..]
    catch-domain-error writer:
      address := format.parse-address address-value
      write-json writer 200 (api.word-detail capture address)
    return
  objects-prefix := "$prefix/objects/"
  edges-suffix := "/edges"
  inspect-suffix := "/inspect"
  if resource.starts-with objects-prefix and resource.ends-with inspect-suffix:
    address-value := resource[objects-prefix.size..resource.size - inspect-suffix.size]
    catch-domain-error writer:
      address := format.parse-address address-value
      object-heap := required-address-query request "object-heap"
      depth := query-int request "depth" api.DEFAULT-INSPECTION-DEPTH
      max-objects := query-int
          request
          "max-objects"
          api.DEFAULT-INSPECTION-OBJECTS
      max-elements := query-int
          request
          "max-elements"
          api.DEFAULT-INSPECTION-ELEMENTS
      write-json writer 200
          (api.inspect-object-detail
              capture
              object-heap
              address
              depth
              max-objects
              max-elements)
    return
  if resource.starts-with objects-prefix and resource.ends-with edges-suffix:
    address-value := resource[objects-prefix.size..resource.size - edges-suffix.size]
    catch-domain-error writer:
      address := format.parse-address address-value
      program := required-address-query request "program"
      offset := query-int request "offset" 0
      limit := query-int request "limit" api.DEFAULT-LIMIT
      write-json writer 200
          (api.object-edges-detail capture address program offset limit)
    return
  if resource.starts-with objects-prefix:
    address-value := resource[objects-prefix.size..]
    catch-domain-error writer:
      address := format.parse-address address-value
      program-value := request.query.parameters.get "program"
      program/int? := null
      if program-value:
        if not program-value is string: throw "INVALID_QUERY_PARAMETER"
        program = format.parse-address program-value
      write-json writer 200 (api.object-detail capture address program)
    return
  if resource.starts-with "$prefix/stacks/":
    address-value := resource["$prefix/stacks/".size..]
    catch-domain-error writer:
      address := format.parse-address address-value
      program-value := request.query.parameters.get "program"
      if not program-value or not program-value is string:
        throw "PROGRAM_REQUIRED"
      program := format.parse-address program-value
      write-json writer 200 (api.stack-detail capture address program)
    return
  if resource == "$prefix/heap-census":
    catch-domain-error writer:
      start := required-address-query request "start"
      end := required-address-query request "end"
      program := required-address-query request "program"
      offset := query-int request "offset" 0
      limit := query-int request "limit" api.DEFAULT-LIMIT
      space-kind-value := request.query.parameters.get "space-kind"
      space-kind/string? := null
      if space-kind-value:
        if not space-kind-value is string or
            (space-kind-value != "old-space" and space-kind-value != "new-space"):
          throw "INVALID_QUERY_PARAMETER"
        space-kind = space-kind-value
      write-json writer 200
          (api.heap-census
              capture
              start
              end
              program
              offset
              limit
              --space-kind=space-kind)
    return
  if resource == "$prefix/retainers":
    catch-domain-error writer:
      start := required-address-query request "start"
      end := required-address-query request "end"
      program := required-address-query request "program"
      target := required-address-query request "target"
      offset := query-int request "offset" 0
      limit := query-int request "limit" api.DEFAULT-LIMIT
      write-json writer 200
          (api.direct-retainers capture start end program target offset limit)
    return
  if resource == "$prefix/retention-path":
    catch-domain-error writer:
      object-heap := required-address-query request "object-heap"
      target := required-address-query request "target"
      max-nodes := query-int request "max-nodes" 10_000
      max-depth := query-int request "max-depth" 256
      write-json writer 200
          (api.process-retention-path
              capture
              object-heap
              target
              max-nodes
              max-depth)
    return
  if resource == "$prefix/retained-size":
    catch-domain-error writer:
      object-heap := required-address-query request "object-heap"
      target := required-address-query request "target"
      max-nodes := query-int request "max-nodes" 10_000
      offset := query-int request "offset" 0
      limit := query-int request "limit" api.DEFAULT-LIMIT
      write-json writer 200
          (api.process-retained-size
              capture
              object-heap
              target
              max-nodes
              offset
              limit)
    return
  if resource == "$prefix/transitive-size":
    catch-domain-error writer:
      object-heap := required-address-query request "object-heap"
      target := required-address-query request "target"
      max-nodes := query-int request "max-nodes" 10_000
      offset := query-int request "offset" 0
      limit := query-int request "limit" api.DEFAULT-LIMIT
      write-json writer 200
          (api.process-transitive-size
              capture
              object-heap
              target
              max-nodes
              offset
              limit)
    return
  if resource == "$prefix/runtime":
    catch-domain-error writer:
      write-json writer 200 (api.runtime-detail capture)
    return
  if resource == "$prefix/process-stacks":
    catch-domain-error writer:
      write-json writer 200 (api.process-stacks-detail capture)
    return
  if resource == "$prefix/process-variables":
    catch-domain-error writer:
      write-json writer 200 (api.process-variables-detail capture)
    return
  if resource == "$prefix/symbolize":
    catch-domain-error writer:
      program := required-address-query request "program"
      bci := required-int-query request "bci"
      write-json writer 200 (api.program-bci-detail capture program bci)
    return
  if resource == "$prefix/memory-accounting":
    catch-domain-error writer:
      write-json writer 200 (api.memory-accounting-detail capture)
    return
  if resource == "$prefix/attachments":
    catch-domain-error writer:
      offset := query-int request "offset" 0
      limit := query-int request "limit" api.DEFAULT-LIMIT
      write-json writer 200 (api.attachments-page capture offset limit)
    return
  if resource.starts-with "$prefix/attachments/":
    id := resource["$prefix/attachments/".size..]
    catch-domain-error writer:
      write-json writer 200 (api.attachment-detail capture id)
    return
  if resource == "$prefix/register-sets":
    catch-domain-error writer:
      offset := query-int request "offset" 0
      limit := query-int request "limit" api.DEFAULT-LIMIT
      write-json writer 200 (api.register-sets-page capture offset limit)
    return
  if resource.starts-with "$prefix/register-sets/":
    id := resource["$prefix/register-sets/".size..]
    catch-domain-error writer:
      write-json writer 200 (api.register-set-detail capture id)
    return
  write-error writer 404 "NOT_FOUND" "The requested API resource does not exist."

query-int request/http.RequestIncoming name/string default/int -> int:
  value := request.query.parameters.get name
  if not value: return default
  if not value is string: throw "INVALID_QUERY_PARAMETER"
  result/int? := null
  catch: result = int.parse value
  if result == null: throw "INVALID_QUERY_PARAMETER"
  return result

required-address-query request/http.RequestIncoming name/string -> int:
  value := request.query.parameters.get name
  if not value or not value is string: throw "INVALID_QUERY_PARAMETER"
  return format.parse-address value

required-int-query request/http.RequestIncoming name/string -> int:
  value := request.query.parameters.get name
  if not value or not value is string: throw "INVALID_QUERY_PARAMETER"
  result/int? := null
  catch: result = int.parse value
  if result == null: throw "INVALID_QUERY_PARAMETER"
  return result

write-json writer/http.ResponseWriter status/int value/any -> none:
  body := json.encode value
  writer.headers.set "Content-Type" "application/json"
  writer.headers.set "Content-Length" body.size.stringify
  writer.headers.set "Cache-Control" "no-store"
  writer.write-headers status
  writer.out.write body
  writer.close

write-error writer/http.ResponseWriter status/int code/string message/string -> none:
  write-json writer status {
    "error": {
      "code": code,
      "message": message,
    },
  }

write-domain-error writer/http.ResponseWriter exception/any -> none:
  code := "$exception"
  if code == "REGION_NOT_FOUND":
    write-error writer 404 code "The requested region does not exist."
  else if code == "ATTACHMENT_NOT_FOUND":
    write-error writer 404 code "The requested attachment does not exist."
  else if code == "REGISTER_SET_NOT_FOUND":
    write-error writer 404 code "The requested register set does not exist."
  else if code == "ADDRESS_NOT_CAPTURED":
    write-error writer 416 code "The requested range is not wholly contained in one captured region."
  else if code == "RUNTIME_LAYOUT_NOT_AVAILABLE":
    write-error writer 409 code "This capture has no exact runtime layout."
  else:
    write-error writer 400 code "The request parameters are invalid."

catch-domain-error writer/http.ResponseWriter [block] -> none:
  exception := catch: block.call
  if exception: write-domain-error writer exception

write-html writer/http.ResponseWriter content/string -> none:
  writer.headers.set "Content-Type" "text/html; charset=utf-8"
  writer.headers.set "Content-Length" content.byte-size.stringify
  writer.out.write content
  writer.close

INDEX-HTML_ ::= """
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Toit device inspector</title>
<style>
body { font: 15px system-ui, sans-serif; margin: 2rem auto; max-width: 80rem; padding: 0 1rem; color: #17212b }
section { margin: 2.2rem 0 }
table { border-collapse: collapse; width: 100% }
th, td { border-bottom: 1px solid #ccd5df; padding: .55rem; text-align: left; vertical-align: top }
th { color: #425466; font-size: .85rem }
code { background: #eef2f6; padding: .12rem .3rem }
button, select { font: inherit }
button { cursor: pointer; padding: .3rem .65rem }
button:disabled { cursor: default }
.number { font-variant-numeric: tabular-nums; text-align: right }
.muted, .empty { color: #637282 }
.partial { color: #9b4c00 }
.process-detail { background: #f7f9fb; padding: 1rem; margin: .25rem 0 1rem }
.process-detail h3 { margin-top: 0 }
.stack-frame { border: 1px solid #ccd5df; border-radius: .35rem; margin: .8rem 0; padding: .8rem }
.stack-frame h4 { margin: 0 0 .3rem }
.stack-frame h5 { margin: .75rem 0 .25rem }
.stack-frame p { margin: .25rem 0 .65rem }
.slot-kind { font-size: .78rem; font-weight: 600; text-transform: uppercase }
.slot-name { font-weight: 600 }
.slot-value code { white-space: nowrap }
.value-mode { align-items: center; display: flex; gap: .45rem; margin: .6rem 0 }
.value-mode input { margin: 0 }
.source-location { font-family: ui-monospace, monospace; font-size: .88rem }
.heap-detail { background: #f7f9fb; padding: 1rem; margin: .25rem 0 1rem }
.heap-detail h3 { margin-top: 0 }
.heap-detail h4 { margin-bottom: .4rem }
.heap-controls { align-items: center; display: flex; flex-wrap: wrap; gap: .6rem; margin: .8rem 0 }
.heap-controls select { max-width: 30rem; padding: .3rem }
.class-bytes { min-width: 12rem }
.class-bar { background: #dbe5ee; display: inline-block; height: .6rem; margin-right: .5rem; min-width: 1px }
.object-link { white-space: nowrap }
.error { color: #a1260d }
</style>
<main>
  <h1>Toit device inspector</h1>
  <p id="status">Loading API…</p>
  <p id="runtime-phase"></p>
  <p id="scope"></p>
  <div id="capture">
    <section>
      <h2>Processes and stacks</h2>
      <p class="muted">Inspect each captured task's published stack, including named parameters and locals, operand-stack values, and source positions.</p>
      <label class="value-mode"><input id="human-values" type="checkbox" checked> Human-readable values</label>
      <label class="value-mode"><input id="physical-stack" type="checkbox"> Show physical stack placement</label>
      <p id="process-state">Loading processes…</p>
      <table id="process-table" hidden>
        <thead><tr><th>Container</th><th>Group</th><th>Process</th><th>State</th><th>Priority</th><th>Task</th><th>Stack</th><th class="number">Globals</th><th class="number">GCs</th><th></th></tr></thead>
        <tbody id="processes"></tbody>
      </table>
    </section>
    <section>
      <h2>System memory accounting</h2>
      <p class="muted">Combines dynamic allocator blocks, typed native roots, Toit process heaps, external payloads, and envelope-declared static or SDK-reserved regions. Coverage is shown explicitly; a component total is never implied for undeclared firmware regions.</p>
      <p id="accounting-state">Loading system memory accounting…</p>
      <table id="accounting-summary" hidden>
        <thead><tr><th>Captured evidence</th><th>Allocator capacity</th><th>Allocated payload</th><th>Free</th><th>Allocator overhead</th><th>Owned/shared</th><th>Unexplained</th><th>Leak candidates</th><th>Coverage</th></tr></thead>
        <tbody id="accounting-summary-body"></tbody>
      </table>
      <h3 id="component-memory-title" hidden>Modeled memory by current owner</h3>
      <p class="muted">A dash in a static or SDK-reserved column means that category is not declared for the component; it does not mean zero bytes.</p>
      <table id="component-memory-table" hidden>
        <thead><tr><th>Component</th><th class="number">Records</th><th class="number">Current modeled bytes</th><th class="number">Dynamic/runtime</th><th class="number">Static linked</th><th class="number">SDK reserved</th><th class="number">Nested allocator reserve</th><th class="number">Live inside reserve</th><th class="number">Shared bytes</th></tr></thead>
        <tbody id="component-memory"></tbody>
      </table>
      <h3>Firmware static and reserved regions</h3>
      <p id="physical-memory-state" class="muted">Loading firmware physical-memory declarations…</p>
      <table id="physical-memory-table" hidden>
        <thead><tr><th>Region</th><th>Component</th><th>Kind</th><th>Range</th><th class="number">Bytes</th><th>Current state</th><th>Evidence</th></tr></thead>
        <tbody id="physical-memory"></tbody>
      </table>
      <h3 id="storage-memory-title" hidden>Memory by storage</h3>
      <table id="storage-memory-table" hidden>
        <thead><tr><th>Storage</th><th class="number">Allocations</th><th class="number">Bytes</th></tr></thead>
        <tbody id="storage-memory"></tbody>
      </table>
      <details id="allocation-tag-coverage" hidden>
        <summary>Allocator tag coverage</summary>
        <p class="muted">Every firmware allocation category is listed, including untagged and unknown memory. Byte totals only become authoritative after allocator blocks are enumerated.</p>
        <table><thead><tr><th>Tag</th><th>Component</th><th class="number">Allocations</th><th class="number">Bytes</th><th>Status</th></tr></thead><tbody id="allocation-tags"></tbody></table>
      </details>
      <details id="ownership-root-coverage" hidden>
        <summary>Ownership-root coverage</summary>
        <p class="muted">Root categories are independent of allocator tags. Missing roots keep unreachable allocations in the unexplained state.</p>
        <table><thead><tr><th>Root category</th><th>Status</th><th>Retention</th><th class="number">Unresolved</th></tr></thead><tbody id="ownership-roots"></tbody></table>
      </details>
      <details id="allocation-evidence" hidden>
        <summary>Allocation ownership evidence</summary>
        <p class="muted">Allocation tags describe where memory was allocated; current owners come from decoded strong roots and ownership edges. An unexplained allocation is not a leak while root coverage is partial.</p>
        <div class="heap-controls">
          <label>State <select id="allocation-state-filter"><option value="">all</option><option>owned</option><option>shared</option><option>unexplained</option><option>leak-candidate</option></select></label>
          <label>Search <input id="allocation-search" type="search" placeholder="address, tag, owner, or kind"></label>
        </div>
        <p id="allocation-evidence-state" class="muted"></p>
        <table><thead><tr><th>Address</th><th class="number">Bytes</th><th>Storage</th><th>Allocation tag</th><th>Current owner</th><th>State</th><th>Evidence</th></tr></thead><tbody id="allocation-evidence-body"></tbody></table>
      </details>
      <p><a id="accounting-json" target="_blank" rel="noopener">Accounting JSON</a></p>
    </section>
    <section>
      <h2>Toit heap breakdown</h2>
      <p class="muted">Expand a named container's heap space to see its classes and objects, then find the named root and field path that keep an object reachable.</p>
      <p id="heap-state">Loading heap spaces…</p>
      <table id="heap-table" hidden>
        <thead><tr><th>Container</th><th>Group</th><th>Process</th><th>Space</th><th>GC view</th><th class="number">Objects</th><th class="number">Object bytes</th><th class="number">Free bytes</th><th class="number">External bytes</th><th class="number">Unused bytes</th><th></th></tr></thead>
        <tbody id="heaps"></tbody>
      </table>
    </section>
    <section>
      <h2>Native resources</h2>
      <p id="resource-state" class="empty">No native resources were captured for the selected processes.</p>
      <table id="resource-table" hidden><thead><tr><th>Process</th><th>Group</th><th>Resource</th><th>State</th><th>Fields</th></tr></thead><tbody id="resources"></tbody></table>
    </section>
    <section>
      <h2>Regions</h2>
      <p id="region-state" class="empty">No captured memory regions.</p>
      <table id="region-table" hidden><thead><tr><th>Name</th><th>Address</th><th class="number">Size</th><th>Kind</th><th>SHA-256</th></tr></thead><tbody id="regions"></tbody></table>
    </section>
  </div>
</main>
<script>
const PAGE_SIZE = 50;
let humanValues = true;
let showPhysicalStack = false;

(async () => {
  const getJson = async url => {
    const response = await fetch(url);
    const value = await response.json();
    if (!response.ok) throw new Error(value.error?.message || ('HTTP ' + response.status));
    return value;
  };
  const addCell = (row, value, className) => {
    const cell = document.createElement('td');
    cell.textContent = value == null ? '—' : String(value);
    if (className) cell.className = className;
    row.appendChild(cell);
    return cell;
  };
  const formatNumber = value => value == null ? '—' : Number(value).toLocaleString();
  document.querySelector('#human-values').addEventListener('change', event => {
    humanValues = event.target.checked;
    for (const element of document.querySelectorAll('[data-value-view]')) {
      element.hidden = element.dataset.valueView !== (humanValues ? 'human' : 'raw');
    }
  });
  document.querySelector('#physical-stack').addEventListener('change', event => {
    showPhysicalStack = event.target.checked;
    for (const element of document.querySelectorAll('[data-stack-physical]')) {
      element.hidden = !showPhysicalStack;
    }
  });
  const discovery = await getJson('/api/v1');
  const capture = await getJson(discovery.links.capture);
  const regions = await getJson(capture.links.regions);
  const runtimeResponse = await fetch(capture.links.runtime);
  const runtime = runtimeResponse.ok ? await runtimeResponse.json() : null;
  const accountingResponse = await fetch(capture.links['memory-accounting']);
  const accounting = accountingResponse.ok ? await accountingResponse.json() : null;
  const status = document.querySelector('#status');
  status.textContent = 'Capture ' + capture.id + ' — ' + capture.completeness.state;
  status.className = capture.completeness.state === 'partial' ? 'partial' : '';
  const runtimePhase = document.querySelector('#runtime-phase');
  if (runtime?.['runtime-state']) {
    const state = runtime['runtime-state'];
    const checkpoint = state.checkpoint?.name;
    runtimePhase.textContent = 'Runtime phase: ' + state.phase +
      (checkpoint ? ' at ' + checkpoint : '') + ' — ' +
      (state['normal-heap-census-safe']
        ? 'normal heap interpretation is safe'
        : 'transitional heap; phase-specific evidence only');
    runtimePhase.className = state['normal-heap-census-safe'] ? '' : 'partial';
  } else {
    runtimePhase.textContent = 'Runtime phase unavailable; normal heap invariants are not assumed.';
    runtimePhase.className = 'partial';
  }
  const accountingState = document.querySelector('#accounting-state');
  document.querySelector('#accounting-json').href = capture.links['memory-accounting'];
  if (accounting) {
    const summary = accounting.summary;
    const allocatorSummary = accounting.allocator?.summary || {};
    const summaryRow = document.createElement('tr');
    for (const value of [
      accounting['captured-region-bytes'],
      allocatorSummary['capacity-bytes'],
      allocatorSummary['allocated-payload-bytes'],
      allocatorSummary['free-bytes'],
      allocatorSummary['overhead-bytes'],
      summary['modeled-reachable-bytes'],
      summary['modeled-unreachable-bytes'],
      summary['leak-candidate-bytes'],
    ]) addCell(summaryRow, formatNumber(value), 'number');
    const coverage = accounting.coverage;
    addCell(summaryRow, coverage['allocator-blocks'] + ' allocator blocks; ' +
      coverage['root-set'] + ' roots; ' +
      coverage['physical-memory-regions'] + ' physical regions');
    document.querySelector('#accounting-summary-body').appendChild(summaryRow);
    document.querySelector('#accounting-summary').hidden = false;
    accountingState.textContent = accounting.state === 'complete'
      ? 'All modeled allocations and ownership roots were enumerated. Static/reserved totals remain limited to components declared by the envelope. Unreachable allocations are leak candidates, not confirmed leaks.'
      : 'Partial accounting: unexplained bytes are not leak claims. Missing allocator, root, or firmware-region coverage can hide both owners and allocations.';
    accountingState.className = accounting.state === 'complete' ? '' : 'partial';

    const componentBody = document.querySelector('#component-memory');
    for (const component of accounting.components || []) {
      const row = document.createElement('tr');
      addCell(row, component.component);
      addCell(row, formatNumber(component['allocation-count']), 'number');
      addCell(row, formatNumber(component['exclusive-bytes']), 'number');
      addCell(row, formatNumber(component['dynamic-and-runtime-bytes']), 'number');
      addCell(row, formatNumber(component['static-linked-bytes']), 'number');
      addCell(row, formatNumber(component['sdk-reserved-bytes']), 'number');
      addCell(row, formatNumber(component['reserved-capacity-bytes']), 'number');
      addCell(row, formatNumber(component['live-bytes-inside-reserves']), 'number');
      addCell(row, formatNumber(component['shared-bytes']), 'number');
      componentBody.appendChild(row);
    }
    if (componentBody.children.length) {
      document.querySelector('#component-memory-title').hidden = false;
      document.querySelector('#component-memory-table').hidden = false;
    }

    const physical = accounting['physical-memory'] || {};
    const physicalState = document.querySelector('#physical-memory-state');
    const declaredComponents = physical['declared-components'] || [];
    if (physical.state === 'not-enumerated') {
      physicalState.textContent = 'No static/reserved firmware-region declarations are available for this envelope. Dynamic allocation rows are not subsystem totals.';
      physicalState.className = 'partial';
    } else {
      physicalState.textContent = 'Declared components: ' + declaredComponents.join(', ') +
        '. Current owner bytes: ' + formatNumber(physical['owned-bytes']) +
        '; released to allocator: ' + formatNumber(physical['released-to-allocator-bytes']) +
        '; unknown release state: ' + formatNumber(physical['unknown-state-bytes']) +
        '. Coverage is partial until every firmware component declares its static and reserved regions.';
      physicalState.className = physical.coverage === 'complete' ? '' : 'partial';
    }
    const physicalBody = document.querySelector('#physical-memory');
    for (const region of physical.regions || []) {
      const row = document.createElement('tr');
      addCell(row, region.name || region.id);
      addCell(row, region.component);
      addCell(row, region.kind);
      addCell(row, region.start + '–' + region.end, 'mono');
      addCell(row, formatNumber(region.size), 'number');
      addCell(row, region.state);
      addCell(row, region.evidence);
      physicalBody.appendChild(row);
    }
    document.querySelector('#physical-memory-table').hidden = !physicalBody.children.length;

    const storageBody = document.querySelector('#storage-memory');
    for (const storage of accounting.storage || []) {
      const row = document.createElement('tr');
      addCell(row, storage.storage);
      addCell(row, formatNumber(storage['allocation-count']), 'number');
      addCell(row, formatNumber(storage.bytes), 'number');
      storageBody.appendChild(row);
    }
    if (storageBody.children.length) {
      document.querySelector('#storage-memory-title').hidden = false;
      document.querySelector('#storage-memory-table').hidden = false;
    }

    const tagBody = document.querySelector('#allocation-tags');
    for (const tag of accounting['allocation-tag-catalog'] || []) {
      const row = document.createElement('tr');
      addCell(row, tag.id + ' · ' + tag.name);
      addCell(row, tag.component);
      addCell(row, formatNumber(tag['allocation-count']), 'number');
      addCell(row, formatNumber(tag.bytes), 'number');
      addCell(row, tag.coverage);
      tagBody.appendChild(row);
    }
    document.querySelector('#allocation-tag-coverage').hidden = !tagBody.children.length;
    const rootBody = document.querySelector('#ownership-roots');
    for (const root of accounting['root-coverage'] || []) {
      const row = document.createElement('tr');
      addCell(row, root.category);
      addCell(row, root.state);
      addCell(row, root.retention);
      addCell(row, formatNumber(root['unresolved-count']), 'number');
      rootBody.appendChild(row);
    }
    document.querySelector('#ownership-root-coverage').hidden = !rootBody.children.length;
    renderAllocationEvidence(accounting);
  } else {
    accountingState.textContent = 'System accounting requires a runtime layout matched to this firmware.';
    accountingState.className = 'error';
  }
  const scope = capture['capture-scope'];
  if (scope) {
    const sourceMemory = scope['source-memory'];
    const psram = sourceMemory ? (sourceMemory['psram-readable'] ? 'PSRAM readable' : 'PSRAM unavailable') : 'PSRAM capability unknown';
    document.querySelector('#scope').textContent = scope.kind === 'process-group'
      ? 'Selected process group ' + scope.selected.id + ' — ' + scope.unresolved.length + ' unresolved ownership dependencies — ' + psram
      : 'Full-device capture scope';
    const resourceBody = document.querySelector('#resources');
    let resourceCount = 0;
    for (const process of scope.selected?.processes || []) {
      for (const group of process['resource-groups'] || []) {
        for (const resource of group.resources || []) {
          const row = document.createElement('tr');
          for (const value of [process.id, group['dynamic-type'] || 'unknown', resource['dynamic-type'] || 'unknown', resource.state, JSON.stringify(resource.fields || {})]) {
            addCell(row, value);
          }
          resourceBody.appendChild(row);
          resourceCount++;
        }
      }
    }
    if (resourceCount) {
      document.querySelector('#resource-state').hidden = true;
      document.querySelector('#resource-table').hidden = false;
    }
  }
  if (runtime) {
    const processBody = document.querySelector('#processes');
    let processCount = 0;
    for (const group of runtime['process-groups'] || []) {
      for (const process of group.processes || []) {
        const objectHeap = process['object-heap'] || {};
        const task = objectHeap.task || {};
        const stackWord = task.stack || {};
        const stackAddress = stackWord['object-address'];
        const program = objectHeap.program || group.program;
        const globals = objectHeap.globals || {};
        const row = document.createElement('tr');
        addCell(row, viewerContainerName(group));
        addCell(row, group.id);
        addCell(row, process.id);
        addCell(row, process.state);
        addCell(row, process.priority);
        addCell(row, task.address || objectHeap['task-reference']);
        addCell(row, stackAddress);
        addCell(row, globals.total, 'number');
        addCell(row, objectHeap['gc-count'], 'number');
        const action = addCell(row, '');
        const button = document.createElement('button');
        button.type = 'button';
        const variablesAvailable = (globals.items || []).length > 0;
        button.textContent = stackAddress && program
          ? 'Inspect variables'
          : (variablesAvailable ? 'Inspect globals' : 'Variables unavailable');
        button.disabled = (!stackAddress || !program) && !variablesAvailable;
        button.setAttribute('aria-expanded', 'false');
        action.replaceChildren(button);
        processBody.appendChild(row);

        const detailRow = document.createElement('tr');
        detailRow.hidden = true;
        const detailCell = document.createElement('td');
        detailCell.colSpan = 10;
        detailRow.appendChild(detailCell);
        processBody.appendChild(detailRow);
        let initialized = false;
        button.addEventListener('click', () => {
          detailRow.hidden = !detailRow.hidden;
          button.textContent = detailRow.hidden ? (stackAddress && program ? 'Inspect variables' : 'Inspect globals') : 'Hide variables';
          button.setAttribute('aria-expanded', String(!detailRow.hidden));
          if (!initialized) {
            initialized = true;
            renderProcessVariables(detailCell, capture, group, process, stackAddress, program, globals);
          }
        });
        processCount++;
      }
    }
    const processState = document.querySelector('#process-state');
    if (processCount) {
      processState.hidden = true;
      document.querySelector('#process-table').hidden = false;
    } else {
      processState.textContent = 'No decoded processes are available in this capture.';
      processState.className = 'empty';
    }

    const heapBody = document.querySelector('#heaps');
    let heapCount = 0;
    for (const group of runtime['process-groups'] || []) {
      for (const process of group.processes || []) {
        for (const [name, space] of Object.entries(process['object-heap'] || {})) {
          if (!name.endsWith('-space') || !space.census) continue;
          const census = space.census;
          const row = document.createElement('tr');
          addCell(row, viewerContainerName(group));
          addCell(row, group.id);
          addCell(row, process.id);
          addCell(row, name);
          const gcView = space['gc-view'] || census['space-view'] || {};
          const gcViewCell = addCell(row,
            (gcView.role || name) + ' · ' + (gcView['object-state'] || 'unknown'));
          if (!census.authoritative) gcViewCell.className = 'partial';
          for (const value of [census['object-count'], census['object-bytes'], census['free-bytes'], census['external-payload-bytes'], census['unused-after-sentinel-bytes']]) addCell(row, formatNumber(value), 'number');
          const action = addCell(row, '');
          const button = document.createElement('button');
          button.type = 'button';
          button.textContent = 'View details';
          action.appendChild(button);
          heapBody.appendChild(row);
          const detailRow = document.createElement('tr');
          detailRow.hidden = true;
          const detailCell = document.createElement('td');
          detailCell.colSpan = 11;
          detailRow.appendChild(detailCell);
          heapBody.appendChild(detailRow);
          let initialized = false;
          button.addEventListener('click', () => {
            detailRow.hidden = !detailRow.hidden;
            button.textContent = detailRow.hidden ? 'View details' : 'Hide details';
            if (!initialized) {
              initialized = true;
              renderHeapDetail(detailCell, capture, group, process, name, space);
            }
          });
          heapCount++;
        }
      }
    }
    const heapState = document.querySelector('#heap-state');
    if (heapCount) {
      heapState.hidden = true;
      document.querySelector('#heap-table').hidden = false;
    } else {
      heapState.textContent = 'No decoded heap spaces are available in this capture.';
      heapState.className = 'empty';
    }
  } else {
    const processState = document.querySelector('#process-state');
    processState.textContent = 'Runtime process decoding is unavailable for this capture.';
    processState.className = 'error';
    const heapState = document.querySelector('#heap-state');
    heapState.textContent = 'Runtime heap decoding is unavailable for this capture.';
    heapState.className = 'error';
  }
  const body = document.querySelector('#regions');
  for (const region of regions.items) {
    const row = document.createElement('tr');
    addCell(row, region.name);
    addCell(row, region.address);
    addCell(row, formatNumber(region.size), 'number');
    addCell(row, region.kind);
    addCell(row, region.sha256.slice(0, 16) + '…');
    body.appendChild(row);
  }
  if (regions.items.length) {
    document.querySelector('#region-state').hidden = true;
    document.querySelector('#region-table').hidden = false;
  }
})().catch(error => {
  const message = 'API error: ' + error;
  document.querySelector('#status').textContent = message;
  for (const selector of ['#process-state', '#accounting-state', '#heap-state']) {
    const state = document.querySelector(selector);
    if (!state.hidden && state.textContent.startsWith('Loading ')) {
      state.textContent = message;
      state.className = 'error';
    }
  }
});

async function renderProcessVariables(parent, capture, group, process, stackAddress, program, globals) {
  const panel = document.createElement('div');
  panel.className = 'process-detail';
  parent.appendChild(panel);
  const title = document.createElement('h3');
  title.textContent = 'Group ' + group.id + ', process ' + process.id;
  panel.appendChild(title);
  const objectHeap = process['object-heap']?.address;
  renderGlobals(panel, capture, program, objectHeap, globals);
  if (!stackAddress || !program) return;
  const stackTitle = document.createElement('h3');
  stackTitle.textContent = 'Stack ' + stackAddress;
  panel.appendChild(stackTitle);
  const state = document.createElement('p');
  state.textContent = 'Loading stack frames…';
  panel.appendChild(state);
  const stackUrl = capture.links.stack.replace(
    '{address}{?program}',
    encodeURIComponent(stackAddress) + '?program=' + encodeURIComponent(program)
  );
  try {
    const stack = await getViewerJson(stackUrl);
    state.className = stack.state === 'published' ? '' : 'partial';
    state.textContent = stack.state === 'published'
      ? formatViewerNumber(stack['frame-count']) + ' frames, ' + formatViewerNumber(stack['used-slots']) + ' used slots' + (stack['local-names-available'] ? ', named variables available' : ', snapshot frame-debug metadata unavailable')
      : 'Stack state: ' + stack.state + '. The active interpreter owns its current stack pointer, so captured heap fields alone cannot recover frames.';
    const jsonLink = document.createElement('a');
    jsonLink.href = stackUrl;
    jsonLink.target = '_blank';
    jsonLink.rel = 'noopener';
    jsonLink.textContent = 'Stack JSON';
    panel.appendChild(jsonLink);

    for (const diagnostic of stack.diagnostics || []) {
      const note = document.createElement('p');
      note.className = 'partial';
      note.textContent = diagnostic;
      panel.appendChild(note);
    }
    for (const frame of stack.frames || []) renderStackFrame(panel, capture, program, objectHeap, frame);
    if ((stack['unframed-slots'] || []).length) {
      const heading = document.createElement('h4');
      heading.textContent = 'Unframed live values';
      panel.appendChild(heading);
      renderStackSlots(panel, capture, program, objectHeap, stack['unframed-slots']);
    }
  } catch (error) {
    state.textContent = 'Could not load stack: ' + error.message;
    state.className = 'error';
  }
}

function renderAllocationEvidence(accounting) {
  const details = document.querySelector('#allocation-evidence');
  const body = document.querySelector('#allocation-evidence-body');
  const state = document.querySelector('#allocation-evidence-state');
  const stateFilter = document.querySelector('#allocation-state-filter');
  const search = document.querySelector('#allocation-search');
  const allocations = [...(accounting.allocations || [])].sort((a, b) => b.size - a.size);
  const rootsByAllocation = new Map();
  for (const root of accounting.roots || []) {
    const allocationId = root['target-allocation-id'];
    if (!allocationId) continue;
    if (!rootsByAllocation.has(allocationId)) rootsByAllocation.set(allocationId, []);
    rootsByAllocation.get(allocationId).push(root);
  }
  const render = () => {
    body.replaceChildren();
    const wantedState = stateFilter.value;
    const needle = search.value.trim().toLowerCase();
    const filtered = allocations.filter(allocation => {
      if (wantedState && allocation.state !== wantedState) return false;
      if (!needle) return true;
      const tag = allocation['allocator-tag'] || {};
      const semantic = allocation.semantic || [];
      const haystack = [
        allocation.address,
        allocation.id,
        allocation.kind,
        allocation.storage,
        allocation.state,
        tag.name,
        tag.component,
        ...(allocation.owners || []),
        ...semantic.flatMap(item => [item.kind, item.space, item['dynamic-type'], item['source-object-address']]),
      ].filter(Boolean).join(' ').toLowerCase();
      return haystack.includes(needle);
    });
    const visible = filtered.slice(0, 250);
    for (const allocation of visible) {
      const row = document.createElement('tr');
      addViewerCell(row, allocation.address, 'object-link');
      addViewerCell(row, formatViewerNumber(allocation.size), 'number');
      addViewerCell(row, allocation.storage || 'unknown');
      const tag = allocation['allocator-tag'] || {};
      addViewerCell(row, tag.name ? tag.name + ' → ' + (tag.component || 'unknown') : 'not decoded');
      addViewerCell(row, (allocation.owners || []).join(', ') || '—');
      addViewerCell(row, allocation.state);
      const evidence = [];
      for (const item of allocation.semantic || []) {
        let label = item.kind || item.evidence || 'semantic range';
        if (item.space) label += ' · ' + item.space;
        if (item['dynamic-type']) label += ' · ' + item['dynamic-type'];
        if (item['source-object-address']) label += ' from object ' + item['source-object-address'];
        evidence.push(label);
      }
      if (allocation['reserved-capacity']) {
        evidence.push('reserved allocator capacity · ' + formatViewerNumber(allocation['nested-heap-live-bytes']) +
          ' live · ' + formatViewerNumber(allocation['nested-heap-free-bytes']) + ' free · ' +
          formatViewerNumber(allocation['nested-heap-overhead-bytes']) + ' overhead');
      }
      for (const root of rootsByAllocation.get(allocation.id) || []) {
        let label = (root.kind || 'root') + ' → ' + root.component;
        if (root['source-object-address']) label += ' from object ' + root['source-object-address'];
        evidence.push(label);
      }
      if (!evidence.length) evidence.push(allocation.evidence || allocation.kind || '—');
      addViewerCell(row, evidence.join('; '));
      body.appendChild(row);
    }
    state.textContent = 'Showing ' + visible.length + ' of ' + filtered.length +
      ' matching allocations, largest first' + (filtered.length > visible.length ? ' (limited to 250)' : '') + '.';
  };
  stateFilter.addEventListener('change', render);
  search.addEventListener('input', render);
  render();
  details.hidden = !allocations.length;
}

function renderGlobals(parent, capture, program, objectHeap, globals) {
  const heading = document.createElement('h3');
  heading.textContent = 'Globals';
  parent.appendChild(heading);
  const metadata = globals['program-layout'] || {};
  const note = document.createElement('p');
  note.className = metadata.state === 'matched' ? 'muted' : 'partial';
  if (metadata.state === 'matched') {
    note.textContent = 'Names from matched snapshot layout v' + metadata['format-version'] + '.' +
      (metadata['frame-variable-names-available'] ? '' : ' This capture snapshot has no frame-debug metadata, so parameters and locals cannot be named.');
  } else {
    note.textContent = 'Global names unavailable: ' + (metadata.reason || 'program layout unavailable') + '.';
  }
  parent.appendChild(note);
  const items = globals.items || [];
  if (!items.length) {
    const empty = document.createElement('p');
    empty.className = 'empty';
    empty.textContent = 'No captured global variables.';
    parent.appendChild(empty);
    return;
  }
  const table = document.createElement('table');
  const head = document.createElement('thead');
  const headRow = document.createElement('tr');
  for (const label of ['Global', 'Value', 'Storage', 'Keeps RAM alive', 'Transitive memory', 'Slot']) {
    const cell = document.createElement('th');
    cell.textContent = label;
    headRow.appendChild(cell);
  }
  head.appendChild(headRow);
  table.appendChild(head);
  const body = document.createElement('tbody');
  for (const value of items) {
    const row = document.createElement('tr');
    addViewerCell(row, value['qualified-name'] || value.name || ('global-' + value.index), 'slot-name');
    renderViewerValueCell(row, capture, program, value);
    addViewerCell(row, value['target-storage'] || 'immediate');
    addViewerCell(row, value['keeps-alive'] ? 'yes' : 'no');
    renderTransitiveSizeCell(row, capture, objectHeap, value);
    addViewerCell(row, value.address);
    body.appendChild(row);
  }
  table.appendChild(body);
  parent.appendChild(table);
}

function renderStackFrame(parent, capture, program, objectHeap, frame) {
  const section = document.createElement('section');
  section.className = 'stack-frame';
  parent.appendChild(section);
  const method = frame.method || {};
  const heading = document.createElement('h4');
  heading.textContent = 'Frame ' + frame.index + ' · ' + frame.kind + ' · ' + (method.name || 'unknown method');
  section.appendChild(heading);
  const details = document.createElement('p');
  details.className = 'muted';
  const parts = [];
  const source = method.source;
  if (source) parts.push(formatViewerSource(source));
  if (method.instruction) parts.push(method.instruction.name + ' at bytecode ' + method.instruction['relative-bci']);
  parts.push('BCI ' + frame['absolute-bci']);
  details.textContent = parts.join(' · ');
  section.appendChild(details);
  if (frame['symbolization-diagnostic']) {
    const diagnostic = document.createElement('p');
    diagnostic.className = 'partial';
    diagnostic.textContent = frame['symbolization-diagnostic'];
    section.appendChild(diagnostic);
  }
  const groups = viewerFrameSlotGroups(frame);
  if (groups.some(group => group.slots.length)) {
    for (const group of groups) {
      if (!group.slots.length) continue;
      const groupHeading = document.createElement('h5');
      groupHeading.textContent = group.title;
      section.appendChild(groupHeading);
      if (group.key === 'parameters' && group.slots.some(slot => slot['physical-frame-index'] !== frame.index)) {
        const storage = document.createElement('p');
        storage.className = 'muted';
        storage.dataset.stackPhysical = '';
        storage.hidden = !showPhysicalStack;
        storage.textContent = 'These values belong to this callee frame; their words are physically stored in the caller frame segment.';
        section.appendChild(storage);
      }
      renderStackSlots(section, capture, program, objectHeap, group.slots);
    }
  } else {
    const empty = document.createElement('p');
    empty.className = 'empty';
    empty.textContent = 'No live values were decoded for this frame.';
    section.appendChild(empty);
  }
}

function viewerFrameSlotGroups(frame) {
  if (Array.isArray(frame['argument-slots'])) {
    const hasVariableClassification =
      Array.isArray(frame['local-slots']) || Array.isArray(frame['operand-slots']);
    const operands = frame['operand-slots'] || [];
    const callRoles = new Set(['pending-parameter', 'call-receiver', 'call-argument']);
    const pendingCall = operands.filter(slot => callRoles.has(slot['bytecode-role']));
    const remainingOperands = operands.filter(slot => !callRoles.has(slot['bytecode-role']));
    const target = frame['pending-call']?.target?.name;
    const groups = [
      {key: 'parameters', title: 'Parameters', slots: frame['argument-slots'] || []},
    ];
    if (hasVariableClassification) {
      groups.push(
        {key: 'locals', title: 'Locals', slots: frame['local-slots'] || []},
        {key: 'stack-blocks', title: 'Stack blocks', slots: frame['block-anchor-slots'] || []},
        {key: 'vm-control', title: 'VM control state', slots: frame['vm-control-slots'] || []},
        {key: 'pending-call', title: target ? 'Parameters for pending call to ' + target : 'Pending call values', slots: pendingCall},
        {key: 'operands', title: 'Operands', slots: remainingOperands},
      );
    } else {
      groups.push(
        {key: 'stack-blocks', title: 'Stack blocks', slots: frame['block-anchor-slots'] || []},
        {key: 'vm-control', title: 'VM control state', slots: frame['vm-control-slots'] || []},
        {key: 'unclassified', title: 'Unclassified locals and operands', slots: frame['local-or-operand-slots'] || []},
      );
    }
    return groups;
  }
  const classified = [
    ...(frame['argument-slots'] || []),
    ...(frame['local-or-operand-slots'] || []),
  ];
  return [{key: 'values', title: 'Live values', slots: classified.length ? classified : (frame.slots || [])}];
}

function renderStackSlots(parent, capture, program, objectHeap, slots) {
  const table = document.createElement('table');
  const head = document.createElement('thead');
  const headRow = document.createElement('tr');
  for (const label of ['Kind', 'Name', 'Value', 'Transitive memory', 'Logical slot', 'Physical placement', 'Declaration', 'Confidence']) {
    const cell = document.createElement('th');
    cell.textContent = label;
    if (label === 'Physical placement') {
      cell.dataset.stackPhysical = '';
      cell.hidden = !showPhysicalStack;
    }
    headRow.appendChild(cell);
  }
  head.appendChild(headRow);
  table.appendChild(head);
  const body = document.createElement('tbody');
  for (const slot of slots) {
    const row = document.createElement('tr');
    addViewerCell(row, viewerSlotKind(slot), 'slot-kind');
    const displayName = slot.name || slot['pending-parameter-name'] || slot['bytecode-role-name'];
    addViewerCell(row, displayName || '—', displayName ? 'slot-name' : 'muted');
    renderStackValueCell(row, capture, program, slot);
    renderTransitiveSizeCell(row, capture, objectHeap, slot);
    addViewerCell(row, viewerLogicalSlot(slot));
    const physical = addViewerCell(row, viewerPhysicalSlot(slot));
    physical.dataset.stackPhysical = '';
    physical.hidden = !showPhysicalStack;
    addViewerCell(row, slot.declaration ? formatViewerSource(slot.declaration) : '—', 'source-location');
    addViewerCell(row, slot['bytecode-role-confidence'] || slot['role-confidence'] || slot.evidence);
    body.appendChild(row);
  }
  table.appendChild(body);
  parent.appendChild(table);
}

function viewerSlotKind(slot) {
  if (slot['bytecode-role'] === 'pending-parameter') return 'pending parameter';
  if (slot['bytecode-role']) return slot['bytecode-role'].replaceAll('-', ' ');
  if (slot.role === 'vm-control' && slot['control-role']) return slot['control-role'].replaceAll('-', ' ');
  if (slot.role === 'parameter' && slot['parameter-kind']) return slot['parameter-kind'];
  return slot.role || slot['candidate-kind'] || 'unknown';
}

function viewerLogicalSlot(slot) {
  if (slot['parameter-index'] != null) return 'parameter ' + slot['parameter-index'];
  if (slot['pending-parameter-index'] != null) return 'pending parameter ' + slot['pending-parameter-index'];
  if (slot['local-stack-height'] != null) return 'local ' + slot['local-stack-height'];
  if (slot['operand-stack-index'] != null) return 'operand ' + slot['operand-stack-index'];
  return slot.role || 'live value';
}

function viewerPhysicalSlot(slot) {
  if (slot['stack-index'] == null) return '—';
  const frame = slot['physical-frame-index'];
  const owner = frame == null ? '' : 'frame ' + frame + ' · ';
  return owner + 'stack slot ' + slot['stack-index'] + ' at ' + slot.address;
}

function renderStackValueCell(row, capture, program, slot) {
  renderViewerValueCell(row, capture, program, slot);
}

function renderViewerValueCell(row, capture, program, value) {
  const cell = addViewerCell(row, '', 'slot-value');
  const human = document.createElement('span');
  human.dataset.valueView = 'human';
  human.hidden = !humanValues;
  const raw = document.createElement('code');
  raw.dataset.valueView = 'raw';
  raw.hidden = humanValues;
  raw.textContent = value.raw || String(value.value ?? '—');
  if (value['object-address']) {
    const link = document.createElement('a');
    link.href = capture.links.self + '/objects/' + encodeURIComponent(value['object-address']) + '?program=' + encodeURIComponent(program);
    link.target = '_blank';
    link.rel = 'noopener';
    link.textContent = value.display || value['object-address'];
    human.appendChild(link);
  } else {
    const text = document.createElement('code');
    text.textContent = value.display || (value.value == null ? (value.raw || '—') : String(value.value));
    human.appendChild(text);
  }
  cell.append(human, raw);
  if (value['candidate-kind']) {
    const kind = document.createElement('span');
    kind.className = 'muted';
    kind.textContent = ' · ' + value['candidate-kind'];
    cell.appendChild(kind);
  }
}

function renderTransitiveSizeCell(row, capture, objectHeap, value) {
  const cell = addViewerCell(row, '');
  const target = value['object-address'];
  if (!target) {
    cell.textContent = 'No heap object';
    cell.className = 'muted';
    return;
  }
  if (!objectHeap || !capture.links['transitive-size']) {
    cell.textContent = 'Heap unavailable';
    cell.className = 'partial';
    return;
  }
  const button = document.createElement('button');
  button.type = 'button';
  button.textContent = 'Compute transitive';
  button.title = 'Count this object and all objects reachable from it, including objects shared with other roots.';
  cell.replaceChildren(button);
  button.addEventListener('click', async () => {
    button.disabled = true;
    button.textContent = 'Computing…';
    const url = capture.links['transitive-size'].split('{')[0] +
      '?object-heap=' + encodeURIComponent(objectHeap) +
      '&target=' + encodeURIComponent(target);
    try {
      const result = await getViewerJson(url);
      const summary = document.createElement('span');
      if (result.status === 'target-not-in-process-heap') {
        summary.className = 'partial';
        summary.textContent = 'Not in this process heap';
      } else if (result.status === 'target-not-decoded') {
        summary.className = 'partial';
        summary.textContent = 'Target object could not be decoded';
      } else {
        summary.className = result.authoritative ? '' : 'partial';
        summary.textContent = formatViewerNumber(result['transitive-object-bytes']) +
          ' object bytes + ' +
          formatViewerNumber(result['transitive-external-payload-bytes']) +
          ' external, ' +
          formatViewerNumber(result['transitive-object-count']) +
          ' objects' + (result.authoritative ? '' : ' (partial)');
      }
      const jsonLink = document.createElement('a');
      jsonLink.href = url;
      jsonLink.target = '_blank';
      jsonLink.rel = 'noopener';
      jsonLink.textContent = 'JSON';
      cell.replaceChildren(summary, document.createTextNode(' · '), jsonLink);
    } catch (error) {
      cell.textContent = 'Could not compute: ' + error.message;
      cell.className = 'error';
    }
  });
}

function formatViewerSource(source) {
  if (!source) return '—';
  let result = source.path || 'unknown source';
  if (source.line != null) result += ':' + source.line;
  if (source.column != null) result += ':' + source.column;
  return result;
}

function renderHeapDetail(parent, capture, group, process, name, space) {
  const census = space.census;
  const panel = document.createElement('div');
  panel.className = 'heap-detail';
  parent.appendChild(panel);
  const title = document.createElement('h3');
  title.textContent = viewerContainerName(group) + ' · group ' + group.id +
    ' · process ' + process.id + ' · ' + name;
  panel.appendChild(title);

  const runtimeState = census['runtime-state'];
  if (runtimeState && !census.authoritative) {
    const phaseNote = document.createElement('p');
    phaseNote.className = 'partial';
    phaseNote.textContent = 'Phase-specific view: ' + runtimeState.phase +
      (runtimeState.checkpoint?.name ? ' at ' + runtimeState.checkpoint.name : '') +
      '. Normal reachability and retained-size actions are disabled because the heap is transitional.';
    panel.appendChild(phaseNote);
  }

  const liveness = census['by-gc-liveness'] || [];
  if (liveness.length) {
    const livenessNote = document.createElement('p');
    livenessNote.textContent = 'GC evidence: ' + liveness.map(entry =>
      formatViewerNumber(entry.count) + ' ' + entry.state + ' objects (' +
      formatViewerNumber(entry.bytes) + ' bytes)').join(', ');
    panel.appendChild(livenessNote);
  }

  const classTitle = document.createElement('h4');
  classTitle.textContent = 'Classes';
  panel.appendChild(classTitle);
  const classes = [...(census['by-class'] || [])].sort((a, b) => b.bytes - a.bytes);
  if (!classes.length) {
    const empty = document.createElement('p');
    empty.className = 'empty';
    empty.textContent = 'No source classes were identified in this space.';
    panel.appendChild(empty);
  } else {
    const table = document.createElement('table');
    const head = document.createElement('thead');
    const headRow = document.createElement('tr');
    for (const value of ['Class', 'Runtime type', 'Objects', 'Bytes', 'Share']) {
      const cell = document.createElement('th');
      cell.textContent = value;
      headRow.appendChild(cell);
    }
    head.appendChild(headRow);
    table.appendChild(head);
    const body = document.createElement('tbody');
    const total = Math.max(1, census['object-bytes'] || 0);
    for (const entry of classes) {
      const row = document.createElement('tr');
      addViewerCell(row, entry['class-name'] || ('class-' + entry['class-id']));
      addViewerCell(row, entry.type || 'unknown');
      addViewerCell(row, formatViewerNumber(entry.count), 'number');
      addViewerCell(row, formatViewerNumber(entry.bytes), 'number');
      const shareCell = addViewerCell(row, '', 'class-bytes');
      const bar = document.createElement('span');
      bar.className = 'class-bar';
      bar.style.width = Math.max(1, Math.round(100 * entry.bytes / total)) + '%';
      shareCell.appendChild(bar);
      shareCell.appendChild(document.createTextNode((100 * entry.bytes / total).toFixed(1) + '%'));
      body.appendChild(row);
    }
    table.appendChild(body);
    panel.appendChild(table);
  }

  const objectTitle = document.createElement('h4');
  objectTitle.textContent = 'Objects';
  panel.appendChild(objectTitle);
  const objectNote = document.createElement('p');
  objectNote.className = 'muted';
  objectNote.textContent = 'Root path shows one decoded strong-root path, including named globals, locals, parameters, fields, and elements. An object may have additional paths.';
  panel.appendChild(objectNote);
  const chunks = (space.chunks || []).filter(chunk => chunk.start && chunk.end);
  if (!chunks.length || !process['object-heap']?.program) {
    const empty = document.createElement('p');
    empty.className = 'empty';
    empty.textContent = chunks.length ? 'The process program pointer is unavailable.' : 'No captured chunks are available for this space.';
    panel.appendChild(empty);
    return;
  }

  const controls = document.createElement('div');
  controls.className = 'heap-controls';
  panel.appendChild(controls);
  const chunkSelect = document.createElement('select');
  chunkSelect.setAttribute('aria-label', 'Heap chunk');
  chunks.forEach((chunk, index) => {
    const option = document.createElement('option');
    option.value = String(index);
    option.textContent = 'Chunk ' + (index + 1) + ': ' + chunk.start + '–' + chunk.end + ' (' + formatViewerNumber(chunk.size) + ' bytes)';
    chunkSelect.appendChild(option);
  });
  controls.appendChild(chunkSelect);
  const previous = document.createElement('button');
  previous.type = 'button';
  previous.textContent = 'Previous';
  controls.appendChild(previous);
  const next = document.createElement('button');
  next.type = 'button';
  next.textContent = 'Next';
  controls.appendChild(next);
  const page = document.createElement('span');
  page.className = 'muted';
  controls.appendChild(page);
  const objectState = document.createElement('p');
  objectState.textContent = 'Loading objects…';
  panel.appendChild(objectState);
  const table = document.createElement('table');
  table.hidden = true;
  const head = document.createElement('thead');
  const headRow = document.createElement('tr');
  for (const value of ['Index', 'Address', 'Class', 'Runtime type', 'Bytes', 'State', 'GC liveness', 'External payload', 'Root path', 'Retained']) {
    const cell = document.createElement('th');
    cell.textContent = value;
    headRow.appendChild(cell);
  }
  head.appendChild(headRow);
  table.appendChild(head);
  const objectBody = document.createElement('tbody');
  table.appendChild(objectBody);
  panel.appendChild(table);
  let offset = 0;
  let loading = false;
  let nextOffset = null;

  const load = async () => {
    if (loading) return;
    loading = true;
    previous.disabled = true;
    next.disabled = true;
    table.hidden = true;
    objectState.hidden = false;
    objectState.className = '';
    objectState.textContent = 'Loading objects…';
    objectBody.replaceChildren();
    const chunk = chunks[Number(chunkSelect.value)];
    const program = process['object-heap'].program;
    const url = capture.links['heap-census'].split('{')[0] + '?start=' + encodeURIComponent(chunk.start) + '&end=' + encodeURIComponent(chunk.end) + '&program=' + encodeURIComponent(program) + '&space-kind=' + encodeURIComponent(name) + '&offset=' + offset + '&limit=' + PAGE_SIZE;
    try {
      const result = await getViewerJson(url);
      nextOffset = result['next-offset'];
      page.textContent = result.total ? 'Objects ' + (offset + 1) + '–' + (offset + result.items.length) + ' of ' + result.total : 'No objects';
      previous.disabled = offset === 0;
      next.disabled = nextOffset == null;
      if (!result.items.length) {
        objectState.textContent = 'No objects were decoded in this chunk.';
        objectState.className = 'empty';
      } else {
        for (const item of result.items) {
          const row = document.createElement('tr');
          addViewerCell(row, item.index, 'number');
          const addressCell = addViewerCell(row, '');
          const link = document.createElement('a');
          link.className = 'object-link';
          link.href = capture.links.self + '/objects/' + encodeURIComponent(item.address) + '?program=' + encodeURIComponent(program);
          link.textContent = item.address;
          link.target = '_blank';
          link.rel = 'noopener';
          addressCell.appendChild(link);
          addViewerCell(row, item['class-name'] || (item['class-id'] == null ? '—' : 'class-' + item['class-id']));
          addViewerCell(row, item.type);
          addViewerCell(row, formatViewerNumber(item.size), 'number');
          addViewerCell(row, item.state);
          addViewerCell(row, item['gc-liveness']?.state || '—',
            item['gc-liveness']?.state === 'dead' ||
              item['gc-liveness']?.state === 'dead-unforwarded'
                ? 'partial'
                : '');
          const external = item.external ? formatViewerNumber(item['external-size']) + ' bytes at ' + item['external-address'] + (item['external-content-captured'] ? '' : ' (not captured)') : '—';
          addViewerCell(row, external);
          const rootCell = addViewerCell(row, '');
          const retainedCell = addViewerCell(row, '');
          if (!result.authoritative) {
            rootCell.textContent = 'Unavailable during ' + result['runtime-state'].phase;
            rootCell.className = 'partial';
            retainedCell.textContent = 'Unavailable during ' + result['runtime-state'].phase;
            retainedCell.className = 'partial';
            objectBody.appendChild(row);
            continue;
          }
          if (item.state !== 'normal-header') {
            rootCell.textContent = 'Not a live object';
            rootCell.className = 'partial';
            retainedCell.textContent = 'Not a live object';
            retainedCell.className = 'partial';
            objectBody.appendChild(row);
            continue;
          }
          const rootButton = document.createElement('button');
          rootButton.type = 'button';
          rootButton.textContent = 'Find root path';
          rootCell.replaceChildren(rootButton);
          rootButton.addEventListener('click', async () => {
            rootButton.disabled = true;
            rootButton.textContent = 'Searching…';
            const heap = process['object-heap'].address;
            const rootUrl = capture.links['retention-path'].split('{')[0] + '?object-heap=' + encodeURIComponent(heap) + '&target=' + encodeURIComponent(item.address);
            try {
              const result = await getViewerJson(rootUrl);
              const summary = document.createElement('span');
              if (result.status === 'found') {
                const root = result.path.root || {};
                const parts = [(root.kind || 'root') + ' ' + (root.label || root.target || 'unknown')];
                for (const edge of result.path.edges || []) {
                  parts.push(edge.kind === 'stack-slot' && edge.name
                    ? (edge.role || 'stack value') + ' ' + edge.name
                    : (edge.label || edge.kind || ('offset ' + edge.offset)));
                }
                summary.textContent = parts.join(' → ');
              } else {
                summary.className = 'partial';
                summary.textContent = result['search-complete']
                  ? 'Not reachable from decoded roots'
                  : 'No path found in the partial root graph';
              }
              const jsonLink = document.createElement('a');
              jsonLink.href = rootUrl;
              jsonLink.target = '_blank';
              jsonLink.rel = 'noopener';
              jsonLink.textContent = 'JSON';
              rootCell.replaceChildren(summary, document.createTextNode(' · '), jsonLink);
            } catch (error) {
              rootCell.textContent = 'Could not find root: ' + error.message;
              rootCell.className = 'error';
            }
          });
          const retainedButton = document.createElement('button');
          retainedButton.type = 'button';
          retainedButton.textContent = 'Compute retained';
          retainedCell.replaceChildren(retainedButton);
          retainedButton.addEventListener('click', async () => {
            retainedButton.disabled = true;
            retainedButton.textContent = 'Computing…';
            const heap = process['object-heap'].address;
            const retainedUrl = capture.links['retained-size'].split('{')[0] + '?object-heap=' + encodeURIComponent(heap) + '&target=' + encodeURIComponent(item.address);
            try {
              const retained = await getViewerJson(retainedUrl);
              const summary = document.createElement('span');
              if (retained.status === 'not-reachable-from-strong-roots') {
                summary.className = 'partial';
                summary.textContent = 'Not reachable from decoded strong roots; retained size is unavailable';
              } else {
                summary.className = retained.authoritative ? '' : 'partial';
                summary.textContent = formatViewerNumber(retained['retained-object-bytes']) + ' object bytes + ' + formatViewerNumber(retained['retained-external-payload-bytes']) + ' external, ' + formatViewerNumber(retained['retained-object-count']) + ' objects' + (retained.authoritative ? '' : ' (partial)');
              }
              const jsonLink = document.createElement('a');
              jsonLink.href = retainedUrl;
              jsonLink.target = '_blank';
              jsonLink.rel = 'noopener';
              jsonLink.textContent = 'JSON';
              retainedCell.replaceChildren(summary, document.createTextNode(' · '), jsonLink);
            } catch (error) {
              retainedCell.textContent = 'Could not compute: ' + error.message;
              retainedCell.className = 'error';
            }
          });
          objectBody.appendChild(row);
        }
        objectState.hidden = true;
        table.hidden = false;
      }
    } catch (error) {
      objectState.textContent = 'Could not load objects: ' + error.message;
      objectState.className = 'error';
      page.textContent = '';
    } finally {
      loading = false;
    }
  };
  chunkSelect.addEventListener('change', () => { offset = 0; load(); });
  previous.addEventListener('click', () => { offset = Math.max(0, offset - PAGE_SIZE); load(); });
  next.addEventListener('click', () => { if (nextOffset != null) { offset = nextOffset; load(); } });
  load();
}

function viewerContainerName(group) {
  const container = group.container || {};
  return container.name || container['snapshot-name'] ||
    container['snapshot-attachment-id'] || 'unknown container';
}

function addViewerCell(row, value, className) {
  const cell = document.createElement('td');
  cell.textContent = value == null ? '—' : String(value);
  if (className) cell.className = className;
  row.appendChild(cell);
  return cell;
}

function formatViewerNumber(value) {
  return value == null ? '—' : Number(value).toLocaleString();
}

async function getViewerJson(url) {
  const response = await fetch(url);
  const value = await response.json();
  if (!response.ok) throw new Error(value.error?.message || ('HTTP ' + response.status));
  return value;
}
</script>
</html>
"""
