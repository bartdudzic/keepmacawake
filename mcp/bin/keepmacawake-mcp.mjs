#!/usr/bin/env node
// Starts the Keep Mac Awake MCP server on stdin and stdout.
import { serveStdio } from "@modelcontextprotocol/server/stdio";
import { createServer, version } from "../src/server.mjs";

if (process.argv.includes("--version")) {
  console.log(version);
} else {
  serveStdio(() => createServer());
}
