const { test, describe } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

describe("QML Security & Rich-Text Injection Prevention", () => {
  const rootDir = path.resolve(__dirname, "..");

  // Helper to extract all Text { ... } blocks from a QML file
  function extractTextBlocks(filePath) {
    const code = fs.readFileSync(filePath, "utf8");
    const blocks = [];
    const regex = /\bText\s*\{/g;
    let match;

    while ((match = regex.exec(code)) !== null) {
      const startIdx = match.index;
      let braceCount = 0;
      let endIdx = -1;
      let i = code.indexOf("{", startIdx);

      for (; i < code.length; i++) {
        if (code[i] === "{") braceCount++;
        else if (code[i] === "}") {
          braceCount--;
          if (braceCount === 0) {
            endIdx = i;
            break;
          }
        }
      }

      if (endIdx !== -1) {
        const raw = code.slice(startIdx, endIdx + 1);
        const textMatch = raw.match(/\btext:\s*([^;\n\r]+)/);
        const textExpr = textMatch ? textMatch[1].trim() : "";
        const hasPlainText = /textFormat:\s*Text\.PlainText/.test(raw);
        const lineNumber = code.slice(0, startIdx).split("\n").length;

        blocks.push({
          filePath,
          fileName: path.basename(filePath),
          lineNumber,
          raw,
          textExpr,
          hasPlainText
        });
      }
    }
    return blocks;
  }

  test("RecentsCommander.qml enforces Text.PlainText on all dynamic Text sinks", () => {
    const qmlPath = path.join(rootDir, "RecentsCommander.qml");
    assert.ok(fs.existsSync(qmlPath), "RecentsCommander.qml must exist");

    const blocks = extractTextBlocks(qmlPath);
    assert.ok(blocks.length > 0, "Should find Text blocks in RecentsCommander.qml");

    // Dynamic sinks that must enforce Text.PlainText
    const requiredDynamicKeywords = [
      "model.title",
      "model.subtitle",
      "model.relativeTime",
      "model.sectionTitle",
      "model.sectionCount",
      "root.filterText",
      "root.toastMessage"
    ];

    for (const keyword of requiredDynamicKeywords) {
      const matchingBlocks = blocks.filter(b => b.textExpr.includes(keyword));
      assert.ok(
        matchingBlocks.length > 0,
        `Expected at least one Text block binding to '${keyword}'`
      );

      for (const block of matchingBlocks) {
        assert.equal(
          block.hasPlainText,
          true,
          `Text block at ${block.fileName}:${block.lineNumber} binding to '${block.textExpr}' must declare 'textFormat: Text.PlainText' to prevent rich-text/HTML injection`
        );
      }
    }
  });

  test("All dynamic Text bindings across any QML files must declare textFormat: Text.PlainText", () => {
    const qmlFiles = fs.readdirSync(rootDir).filter(f => f.endsWith(".qml"));
    assert.ok(qmlFiles.length > 0, "Must find QML files in project");

    for (const file of qmlFiles) {
      const filePath = path.join(rootDir, file);
      const blocks = extractTextBlocks(filePath);

      for (const block of blocks) {
        // Detect if text expression references dynamic data from model, root properties, or items
        const isDynamic =
          /\b(model\.|root\.|item\.|tl\.|data\.)/.test(block.textExpr) ||
          /\b(title|subtitle|filterText|toastMessage)\b/.test(block.textExpr);

        if (isDynamic) {
          assert.equal(
            block.hasPlainText,
            true,
            `Security violation in ${block.fileName}:${block.lineNumber}: dynamic text binding '${block.textExpr}' must have 'textFormat: Text.PlainText'`
          );
        }
      }
    }
  });

  test("Service.qml sanitizes window titles and app IDs against control characters", () => {
    const servicePath = path.join(rootDir, "Service.qml");
    const content = fs.readFileSync(servicePath, "utf8");

    // Ensure control characters and newlines are sanitized in incoming window metadata
    assert.ok(
      content.includes(".replace(/[\\r\\n\\t]/g, \" \")"),
      "Service.qml must sanitize \\r, \\n, \\t from client-provided window metadata"
    );
  });
});
