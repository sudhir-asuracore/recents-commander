const { test, describe } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

describe("Plugin Manifest & File Structure", () => {
  const rootDir = path.resolve(__dirname, "..");
  const manifestPath = path.join(rootDir, "manifest.json");

  test("manifest.json exists and is valid JSON", () => {
    assert.ok(fs.existsSync(manifestPath), "manifest.json must exist in root");
    const raw = fs.readFileSync(manifestPath, "utf8");
    assert.doesNotThrow(() => JSON.parse(raw), "manifest.json must be valid JSON");
  });

  test("manifest contains all required metadata fields", () => {
    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));

    assert.equal(typeof manifest.schemaVersion, "number");
    assert.ok(manifest.schemaVersion >= 1);
    assert.equal(typeof manifest.id, "string");
    assert.match(manifest.id, /^[a-z0-9_.-]+$/i);
    assert.equal(typeof manifest.name, "string");
    assert.ok(manifest.name.length > 0);
    assert.equal(typeof manifest.version, "string");
    assert.match(manifest.version, /^\d+\.\d+\.\d+/);
    assert.equal(typeof manifest.author, "string");
    assert.equal(typeof manifest.license, "string");
    assert.ok(Array.isArray(manifest.kinds) && manifest.kinds.length > 0);
    assert.equal(typeof manifest.entryPoints, "object");
  });

  test("all declared entryPoint files exist on disk", () => {
    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
    const entryPoints = manifest.entryPoints;

    for (const [kind, filename] of Object.entries(entryPoints)) {
      const filePath = path.join(rootDir, filename);
      assert.ok(
        fs.existsSync(filePath),
        `Entry point file '${filename}' for kind '${kind}' must exist`
      );
    }
  });

  test("barWidget configuration is present when bar-widget kind is declared", () => {
    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
    if (manifest.kinds.includes("bar-widget")) {
      assert.ok(manifest.barWidget, "barWidget section must be defined");
      assert.equal(typeof manifest.barWidget.displayName, "string");
      assert.equal(typeof manifest.barWidget.description, "string");
    }
  });

  test("RecentsModel.js library file exists and has valid pragma", () => {
    const modelPath = path.join(rootDir, "RecentsModel.js");
    assert.ok(fs.existsSync(modelPath), "RecentsModel.js must exist");
    const content = fs.readFileSync(modelPath, "utf8");
    assert.ok(
      content.startsWith(".pragma library"),
      "RecentsModel.js must start with .pragma library for QML singleton usage"
    );
  });
});
