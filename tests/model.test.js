const { test, describe } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

describe("RecentsModel.js Core Logic & Data Handling", () => {
  const modelFile = path.resolve(__dirname, "../RecentsModel.js");
  const rawCode = fs.readFileSync(modelFile, "utf8").replace(".pragma library", "");

  const context = {
    console,
    Date,
    Math,
    Array,
    String,
    Qt: {
      formatDate: (d, fmt) => d.toISOString().slice(0, 10)
    }
  };

  vm.createContext(context);
  vm.runInContext(
    rawCode +
      "; this.Model = { createEmptyState, parseState, serializeState, recordApp, recordDirectory, removeApp, removeDirectory, filterRecents, sortEntries, formatRelativeTime };",
    context
  );

  const Model = context.Model;

  test("createEmptyState returns valid initial state", () => {
    const s = Model.createEmptyState();
    assert.equal(s.version, 1);
    assert.ok(Array.isArray(s.apps) && s.apps.length === 0);
    assert.ok(Array.isArray(s.directories) && s.directories.length === 0);
    assert.ok(typeof s.lastUpdated === "string");
  });

  test("parseState handles corrupt or invalid data gracefully", () => {
    assert.equal(Model.parseState(null).apps.length, 0);
    assert.equal(Model.parseState("not json").apps.length, 0);
    assert.equal(Model.parseState("{}").apps.length, 0);
    assert.equal(Model.parseState("{\"apps\": \"not-array\"}").apps.length, 0);
  });

  test("recordApp and serializeState preserve pure MRU descending order", () => {
    let state = Model.createEmptyState();

    // Record App A
    state = Model.recordApp(state, { id: "app-a", name: "App A" });
    const timeA = new Date(state.apps[0].lastOpened).getTime();

    // Fast-forward 100ms
    const timeB = new Date(Date.now() + 100).toISOString();
    state.apps.push({
      id: "app-b",
      name: "App B",
      icon: "app-b",
      description: "",
      lastOpened: timeB,
      openCount: 1
    });

    // Re-sort via sortEntries
    state.apps = Model.sortEntries(state.apps);
    assert.equal(state.apps[0].id, "app-b");
    assert.equal(state.apps[1].id, "app-a");

    // Serialization must also preserve MRU
    const serialized = Model.serializeState(state);
    const parsed = JSON.parse(serialized);
    assert.equal(parsed.apps[0].id, "app-b");
    assert.equal(parsed.apps[1].id, "app-a");
  });

  test("recordApp and filterRecents handle HTML-like and XSS payloads safely", () => {
    let state = Model.createEmptyState();
    const maliciousTitle = "<script>alert('xss')</script>";
    const maliciousDesc = "<img src='x' onerror='alert(1)'>";
    const maliciousPath = "/home/sid/<b>bold_dir</b>/<svg onload=alert(2)>";

    state = Model.recordApp(state, {
      id: "evil-app",
      name: maliciousTitle,
      description: maliciousDesc
    });

    state = Model.recordDirectory(state, maliciousPath);

    // Stored as literal strings without corrupting state
    assert.equal(state.apps[0].name, maliciousTitle);
    assert.equal(state.apps[0].description, maliciousDesc);
    assert.ok(state.directories[0].path.includes("bold_dir"));

    // filterRecents with special chars, regex chars, and HTML tags must not throw
    const specialQueries = [
      "<script>",
      ".*",
      "[a-z]+",
      "\\",
      "\"'--",
      "alert(1)",
      "<b>"
    ];

    for (const q of specialQueries) {
      assert.doesNotThrow(() => {
        const res = Model.filterRecents(state, q, "all", "/home/sid", 20);
        assert.ok(Array.isArray(res.flatList));
      }, `Filtering with query '${q}' should not throw error`);
    }

    // Direct match for HTML string
    const match = Model.filterRecents(state, "script", "all", "/home/sid", 20);
    assert.equal(match.flatList[0].id, "evil-app");
    assert.equal(match.flatList[0].title, maliciousTitle);
  });

  test("removeApp and removeDirectory prune items correctly", () => {
    let state = Model.createEmptyState();
    state = Model.recordApp(state, { id: "app-1", name: "App 1" });
    state = Model.recordDirectory(state, "/home/sid/test");

    assert.equal(state.apps.length, 1);
    assert.equal(state.directories.length, 1);

    state = Model.removeApp(state, "app-1");
    assert.equal(state.apps.length, 0);

    state = Model.removeDirectory(state, "/home/sid/test");
    assert.equal(state.directories.length, 0);
  });
});
