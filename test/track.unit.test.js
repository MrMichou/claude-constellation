// Unit tests for the pure helpers of hooks/track.js (exported when the file is required).
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { createRequire } from "node:module";
import { TRACK } from "./helpers.js";

const { shortPath, clip, describeTool, tmuxSessions, linkKeys, noteKey, bashNotes } = createRequire(import.meta.url)(TRACK);

describe("shortPath", () => {
  it("keeps short paths and abbreviates $HOME", () => {
    expect(shortPath("/etc/hosts")).toBe("/etc/hosts");
    expect(shortPath(os.homedir() + "/x")).toBe("~/x");
  });
  it("keeps only the last two components of long paths", () => {
    expect(shortPath("/a/b/c/d.txt")).toBe("…/c/d.txt");
  });
  it("returns an empty string for missing paths", () => {
    expect(shortPath(undefined)).toBe("");
  });
});

describe("clip", () => {
  it("keeps the first line only, trimmed", () => {
    expect(clip("  ls -la\nsecond line", 40)).toBe("ls -la");
  });
  it("truncates with an ellipsis to exactly n characters", () => {
    const out = clip("x".repeat(50), 10);
    expect(out).toHaveLength(10);
    expect(out.endsWith("…")).toBe(true);
  });
  it("tolerates null", () => {
    expect(clip(null, 5)).toBe("");
  });
});

describe("describeTool", () => {
  it.each([
    ["Read", { file_path: "/a/b/c/d.lua" }, "file", "…/c/d.lua"],
    ["Edit", { file_path: "/x.lua" }, "file", "/x.lua"],
    ["NotebookEdit", { notebook_path: "/n.ipynb" }, "file", "/n.ipynb"],
    ["Bash", { command: "git status\nmore" }, "shell", "git status"],
    ["Grep", { pattern: "TODO" }, "search", "TODO"],
    ["Glob", { pattern: "**/*.lua" }, "search", "**/*.lua"],
    ["WebFetch", { url: "https://docs.rs/foo?x=1" }, "web", "docs.rs"],
    ["WebFetch", { url: "not a url" }, "web", "not a url"],
    ["WebSearch", { query: "lgi cairo" }, "web", "lgi cairo"],
    ["Agent", { subagent_type: "Explore" }, "agent", "Explore"],
    ["Task", { description: "find things" }, "agent", "find things"],
    ["mcp__serena__find_symbol", {}, "mcp", "serena:find_symbol"],
    ["SomethingNew", {}, "other", "SomethingNew"],
  ])("%s -> %s", (tool, input, kind, target) => {
    expect(describeTool(tool, input)).toEqual({ kind, target });
  });
  it("tolerates a missing input", () => {
    expect(describeTool("Bash", undefined)).toEqual({ kind: "shell", target: "" });
  });
});

describe("tmuxSessions", () => {
  it.each([
    ["tmux send-keys -t work:1.2 ls Enter", ["work"]],
    ["tmux capture-pane -p -S -60 -t 0:0 | grep x", ["0"]],
    ["P=0:0; tmux send-keys -t $P -l 'hostname' Enter", ["0"]],
    ["P=dev:1; tmux send-keys -t ${P} Enter", ["dev"]],
    ["for p in 0:0.0 0:0.1; do tmux send-keys -t $p C-c; done", ["0"]],
    ["sleep 3; tmux capture-pane -p -t 0:0.0 -S -40", ["0"]],
    ["tmux send-keys -t 'a:1' x && tmux send-keys -t b x", ["a", "b"]],
    ["tmux attach -t =main", ["main"]],
  ])("finds the session driven by %s", (cmd, sessions) => {
    expect(tmuxSessions(cmd).sort()).toEqual(sessions);
  });

  it.each([
    ["tmux ls"],
    ["tmux ls; for s in $(tmux ls -F '#S'); do echo $s; done"],
    ["jq 'del(.links[\"tmux:0\"])' f.json"],
    ['echo "tmux send-keys -t 0:0" > notes.txt'],
    ["grep -t 0:0 file"],
    ["tmux send-keys -t $UNSET x"],
  ])("ignores %s", (cmd) => {
    expect(tmuxSessions(cmd)).toEqual([]);
  });
});

describe("linkKeys", () => {
  it("keys file tools by absolute path, labelled with the basename", () => {
    for (const t of ["Read", "Edit", "Write", "MultiEdit"]) {
      expect(linkKeys(t, { file_path: "/srv/app/deploy.yml" }))
        .toEqual([{ key: "file:/srv/app/deploy.yml", kind: "file", label: "deploy.yml" }]);
    }
  });
  it("keys tmux sessions driven by Bash", () => {
    expect(linkKeys("Bash", { command: "tmux send-keys -t 0:0 ls" }))
      .toEqual([{ key: "tmux:0", kind: "shell", label: "tmux 0" }]);
  });
  it("returns nothing for other tools or commands", () => {
    expect(linkKeys("Grep", { pattern: "x" })).toEqual([]);
    expect(linkKeys("Bash", { command: "ls -la" })).toEqual([]);
    expect(linkKeys("Read", {})).toEqual([]);
    expect(linkKeys("Bash", undefined)).toEqual([]);
  });
});

describe("noteKey", () => {
  it("keys a markdown note read or written by its absolute path", () => {
    expect(noteKey("Read", { file_path: "/v/Ideas/Brain.md" })).toEqual({ key: "/v/Ideas/Brain.md", op: "r" });
    for (const t of ["Edit", "Write", "MultiEdit"]) {
      expect(noteKey(t, { file_path: "/v/Brain.md" })).toEqual({ key: "/v/Brain.md", op: "w" });
    }
  });

  it("ignores other files, relative paths and other tools", () => {
    expect(noteKey("Read", { file_path: "/v/app.js" })).toBeNull();
    expect(noteKey("Read", { file_path: "notes/a.md" })).toBeNull();
    expect(noteKey("Bash", { command: "cat /v/a.md" })).toBeNull();
  });

  it("keys a note reached through an Obsidian MCP server by its vault path", () => {
    expect(noteKey("mcp__obsidian__obsidian_get_file_contents", { filepath: "Ideas/Brain.md" }))
      .toEqual({ key: "obsidian:Ideas/Brain.md", op: "r" });
    expect(noteKey("mcp__obsidian__obsidian_append_content", { filepath: "Log.md" }))
      .toEqual({ key: "obsidian:Log.md", op: "w" });
    expect(noteKey("mcp__obsidian__obsidian_get_file_contents", { filepath: "../etc/passwd" })).toBeNull();
    expect(noteKey("mcp__github__get_file", { path: "README.md" })).toBeNull();
  });
});

describe("bashNotes", () => {
  let v;
  beforeEach(() => {
    v = fs.mkdtempSync(path.join(os.tmpdir(), "vault-"));
    fs.mkdirSync(path.join(v, "wiki"));
    for (const f of ["hot.md", "wiki/A.md", "wiki/B.md"]) fs.writeFileSync(path.join(v, f), "x");
  });
  afterEach(() => fs.rmSync(v, { recursive: true, force: true }));

  it("reads notes named by a command, relative to its cwd and its own cd", () => {
    expect(bashNotes("sed -n 12,200p hot.md", v)).toEqual([{ key: path.join(v, "hot.md"), op: "r" }]);
    expect(bashNotes(`cd ${v}/wiki && grep -n foo A.md B.md`, "/elsewhere")).toEqual([
      { key: path.join(v, "wiki/A.md"), op: "r" }, { key: path.join(v, "wiki/B.md"), op: "r" }]);
  });

  it("follows ../ paths and VAR=value assignments", () => {
    expect(bashNotes("grep -n x ../hot.md", path.join(v, "wiki"))).toEqual([{ key: path.join(v, "hot.md"), op: "r" }]);
    fs.writeFileSync(path.join(v, "wiki/Suivi — 29 octobre.md"), "x");
    expect(bashNotes(`cd wiki && F="Suivi — 29 octobre.md"; wc -l "$F"; head -30 "\${F}"`, v))
      .toEqual([{ key: path.join(v, "wiki/Suivi — 29 octobre.md"), op: "r" }]);
    expect(bashNotes("D=wiki; cat $D/A.md", v)).toEqual([{ key: path.join(v, "wiki/A.md"), op: "r" }]);
  });

  it("marks redirect, tee, sed -i and cp/mv destinations as written", () => {
    expect(bashNotes("cat > wiki/New.md <<'EOF'\nsee Other.md\nEOF", v))
      .toEqual([{ key: path.join(v, "wiki/New.md"), op: "w" }]);
    expect(bashNotes("echo x >> hot.md", v)).toEqual([{ key: path.join(v, "hot.md"), op: "w" }]);
    expect(bashNotes("echo x | tee wiki/C.md", v)).toEqual([{ key: path.join(v, "wiki/C.md"), op: "w" }]);
    expect(bashNotes("sed -i 's/a/b/' hot.md", v)).toEqual([{ key: path.join(v, "hot.md"), op: "w" }]);
    expect(bashNotes("cp wiki/A.md wiki/D.md", v)).toEqual([
      { key: path.join(v, "wiki/A.md"), op: "r" }, { key: path.join(v, "wiki/D.md"), op: "w" }]);
  });

  it("ignores globs, variables, missing files, rm and commands without notes", () => {
    expect(bashNotes("ls *.md; cat $F.md; cat gone.md; rm hot.md", v)).toEqual([]);
    expect(bashNotes("cargo test", v)).toEqual([]);
    expect(bashNotes("cat hot.md", undefined)).toEqual([]);
  });
});
