#!/usr/bin/env node
// A stand-in for the keepmacawake command in tests. It never touches the Mac:
// it appends its arguments to $FAKE_KMA_DIR/calls.jsonl and answers from
// $FAKE_KMA_DIR/replies.json, which maps "status", "start" and "stop" to
// { "exit": N, "reply": {...}, "delayMs": N }.
import { appendFileSync, readFileSync } from "node:fs";
import { join } from "node:path";

const dir = process.env.FAKE_KMA_DIR;
const args = process.argv.slice(2);
appendFileSync(join(dir, "calls.jsonl"), JSON.stringify(args) + "\n");
const replies = JSON.parse(readFileSync(join(dir, "replies.json"), "utf8"));
const answer = replies[args[0]] ?? { exit: 2, reply: { result: "error", error: { code: "invalid_arguments", message: "Unknown command." } } };
setTimeout(() => {
  if (answer.reply !== undefined) process.stdout.write(JSON.stringify(answer.reply) + "\n");
  process.exit(answer.exit ?? 0);
}, answer.delayMs ?? 0);
