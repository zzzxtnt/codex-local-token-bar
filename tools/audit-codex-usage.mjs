#!/usr/bin/env node

// Development-only parity probe for CC Switch's session_usage_codex.rs.
// It intentionally reads only token_count/session metadata, never prompts or credentials.

import fs from "node:fs";
import path from "node:path";

const codexRoot = process.argv[2] || path.join(process.env.HOME, ".codex");
const day = process.argv[3] || new Date().toLocaleDateString("en-CA");
const dayStart = new Date(`${day}T00:00:00`).getTime();
const dayEnd = new Date(`${day}T24:00:00`).getTime();
const roots = [path.join(codexRoot, "sessions"), path.join(codexRoot, "archived_sessions")];

function walk(directory, output) {
  if (!fs.existsSync(directory)) return;
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const target = path.join(directory, entry.name);
    if (entry.isDirectory()) walk(target, output);
    else if (entry.name.endsWith(".jsonl")) output.push(target);
  }
}

const allFiles = [];
for (const root of roots) walk(root, allFiles);
const rolloutIndex = new Map();
for (const file of allFiles) {
  const match = file.match(/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/i);
  if (!match) continue;
  const id = match[1].toLowerCase();
  if (!rolloutIndex.has(id)) rolloutIndex.set(id, []);
  rolloutIndex.get(id).push(file);
}

const selectedFiles = allFiles.filter((file) => fs.statSync(file).mtimeMs >= dayStart);
const cache = new Map();

function counters(value) {
  if (!value || typeof value !== "object") return null;
  const keys = ["input_tokens", "cached_input_tokens", "cache_read_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens"];
  if (!keys.some((key) => Object.hasOwn(value, key))) return null;
  return {
    input: Number(value.input_tokens || 0),
    cached: Number(value.cached_input_tokens ?? value.cache_read_input_tokens ?? 0),
    output: Number(value.output_tokens || 0),
  };
}

function counterSignature(value) {
  if (!value || typeof value !== "object") return null;
  return [
    value.input_tokens ?? null,
    value.cached_input_tokens ?? value.cache_read_input_tokens ?? null,
    value.output_tokens ?? null,
    value.reasoning_output_tokens ?? null,
    value.total_tokens ?? null,
  ];
}

function tokenSignature(info) {
  const total = counterSignature(info.total_token_usage);
  const last = counterSignature(info.last_token_usage);
  return total || last ? JSON.stringify([total, last]) : null;
}

function parse(file) {
  if (cache.has(file)) return cache.get(file);
  const result = { rootId: null, rootTimestamp: null, rootMetaSeen: false, parentId: null, deferred: false, events: [] };
  cache.set(file, result);
  const match = file.match(/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/i);
  result.rootId = match?.[1]?.toLowerCase() || null;

  let highWater = null;
  const signaturesBySource = new Map();
  let previousSignature = null;
  let eventIndex = 0;

  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    if (!line.includes('"event_msg"') && !line.includes('"turn_context"') && !line.includes('"session_meta"')) continue;
    if (line.includes('"event_msg"') && !line.includes('"token_count"')) continue;
    let value;
    try { value = JSON.parse(line); } catch { continue; }

    if (value.type === "session_meta" && !result.rootMetaSeen) {
      result.rootMetaSeen = true;
      result.rootTimestamp = Date.parse(value.timestamp);
      const payload = value.payload || {};
      const forked = payload.forked_from_id || null;
      const spawned = payload.source?.subagent?.thread_spawn?.parent_thread_id || null;
      if (forked && spawned && forked !== spawned) result.deferred = true;
      else result.parentId = (forked || spawned || null)?.toLowerCase() || null;
      const metaId = (payload.id || payload.thread_id || payload.threadId || "").toLowerCase();
      if (metaId && result.rootId && metaId !== result.rootId) result.deferred = true;
      if (result.parentId === result.rootId) result.deferred = true;
      continue;
    }

    if (value.type !== "event_msg" || value.payload?.type !== "token_count" || !value.payload.info) continue;
    const info = value.payload.info;
    const signature = tokenSignature(info);
    if (!signature) continue;
    const total = counters(info.total_token_usage);
    const last = counters(info.last_token_usage);
    if (!total && !last) continue;

    const source = value.payload.rate_limits?.limit_id || "__default__";
    const duplicate = Boolean(total) && (signaturesBySource.get(source) === signature || previousSignature === signature);
    if (total) signaturesBySource.set(source, signature);
    previousSignature = signature;

    let delta;
    if (duplicate) delta = { input: 0, cached: 0, output: 0 };
    else if (last) delta = { ...last };
    else if (!highWater) delta = { ...total };
    else delta = {
      input: Math.max(0, total.input - highWater.input),
      cached: Math.max(0, total.cached - highWater.cached),
      output: Math.max(0, total.output - highWater.output),
    };

    if (total) {
      highWater = highWater ? {
        input: Math.max(highWater.input, total.input),
        cached: Math.max(highWater.cached, total.cached),
        output: Math.max(highWater.output, total.output),
      } : { ...total };
    }
    delta.cached = Math.min(delta.cached, delta.input);
    const nonzero = delta.input !== 0 || delta.cached !== 0 || delta.output !== 0;
    if (nonzero) eventIndex += 1;
    result.events.push({
      signature,
      delta,
      eventIndex: nonzero ? eventIndex : null,
      timestamp: Date.parse(value.timestamp),
    });
  }
  return result;
}

function parentSignatures(parentId, cutoff) {
  const candidates = rolloutIndex.get(parentId);
  if (!candidates?.length || !Number.isFinite(cutoff)) return null;
  const snapshots = candidates.map((file) => parse(file).events
    .filter((event) => Number.isFinite(event.timestamp) && event.timestamp <= cutoff)
    .map((event) => event.signature));
  const first = JSON.stringify(snapshots[0]);
  return snapshots.every((snapshot) => JSON.stringify(snapshot) === first) ? snapshots[0] : null;
}

function replayPrefix(events, parent) {
  let offset = 0;
  let matched = 0;
  for (const event of events) {
    const relative = parent.slice(offset).indexOf(event.signature);
    if (relative < 0) break;
    offset += relative + 1;
    matched += 1;
  }
  return matched;
}

const requestIds = new Set();
let input = 0;
let cached = 0;
let output = 0;
let deferredFiles = 0;
for (const file of selectedFiles.sort()) {
  const parsed = parse(file);
  if (!parsed.rootId || !parsed.rootMetaSeen || parsed.deferred) {
    deferredFiles += 1;
    continue;
  }
  let prefix = 0;
  if (parsed.parentId) {
    const signatures = parentSignatures(parsed.parentId, parsed.rootTimestamp);
    if (!signatures) {
      deferredFiles += 1;
      continue;
    }
    prefix = replayPrefix(parsed.events, signatures);
  }
  for (let index = 0; index < parsed.events.length; index += 1) {
    const event = parsed.events[index];
    if (index < prefix || event.eventIndex == null) continue;
    if (!Number.isFinite(event.timestamp) || event.timestamp < dayStart || event.timestamp >= dayEnd) continue;
    const requestId = `codex_session:thread-v1:${parsed.rootId}:${event.eventIndex}`;
    if (requestIds.has(requestId)) continue;
    requestIds.add(requestId);
    input += event.delta.input;
    cached += event.delta.cached;
    output += event.delta.output;
  }
}

console.log(JSON.stringify({ day, files: selectedFiles.length, deferredFiles, requests: requestIds.size, input, cached, output, realTotal: input + output }, null, 2));
