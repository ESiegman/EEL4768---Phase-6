#!/usr/bin/env node
"use strict";

// netlistsvg recursively splits wide/repeated buses, which can exhaust
// Node's main-thread stack on cache netlists. Run its unchanged CLI in a
// worker with an explicit stack, preserving the supplied circuit/netlist.
const { realpathSync } = require("node:fs");
const { Worker } = require("node:worker_threads");

const [cli, ...args] = process.argv.slice(2);
if (!cli || args.length === 0) {
    console.error("usage: render_schematic.cjs <netlistsvg-cli> <netlist.json> [-o output.svg]");
    process.exit(1);
}
const worker = new Worker(realpathSync(cli), {
    argv: args,
    resourceLimits: { stackSizeMb: 64 },
});
worker.on("error", (error) => {
    console.error(error);
    process.exitCode = 1;
});
worker.on("exit", (code) => {
    if (code !== 0) process.exitCode = code;
});
