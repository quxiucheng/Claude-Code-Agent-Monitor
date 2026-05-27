/**
 * @file Verifies the idempotent ALTER TABLE migration adds a transcript_path
 * column to sessions and that a fresh db.js load on an existing DB does not
 * throw or duplicate the column.
 */

const { describe, it, before, after } = require("node:test");
const assert = require("node:assert/strict");
const path = require("path");
const fs = require("fs");
const os = require("os");

let TEST_DB;

before(() => {
  TEST_DB = path.join(os.tmpdir(), `dashboard-tp-migration-${Date.now()}-${process.pid}.db`);
  process.env.DASHBOARD_DB_PATH = TEST_DB;
});

after(() => {
  try { fs.unlinkSync(TEST_DB); } catch {}
  try { fs.unlinkSync(TEST_DB + "-wal"); } catch {}
  try { fs.unlinkSync(TEST_DB + "-shm"); } catch {}
});

describe("sessions.transcript_path migration", () => {
  it("adds transcript_path column on first load", () => {
    delete require.cache[require.resolve("../db")];
    const { db } = require("../db");
    const cols = db.prepare("PRAGMA table_info(sessions)").all();
    const names = cols.map((c) => c.name);
    assert.ok(
      names.includes("transcript_path"),
      `expected transcript_path; got: ${names.join(",")}`
    );
  });

  it("is idempotent — loading db.js a second time does not throw", () => {
    delete require.cache[require.resolve("../db")];
    assert.doesNotThrow(() => require("../db"));
  });

  it("transcript_path is nullable and accepts an UPDATE", () => {
    const { db, stmts } = require("../db");
    stmts.insertSession.run("s-tp-1", "name", "active", "/tmp/proj", "claude", null);
    db.prepare("UPDATE sessions SET transcript_path = ? WHERE id = ?").run(
      "/tmp/foo.jsonl",
      "s-tp-1"
    );
    const row = db
      .prepare("SELECT transcript_path FROM sessions WHERE id = ?")
      .get("s-tp-1");
    assert.equal(row.transcript_path, "/tmp/foo.jsonl");
  });
});
