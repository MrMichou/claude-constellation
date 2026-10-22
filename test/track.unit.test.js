// Unit tests for the pure helpers of hooks/track.js (exported when the file is required).
import { describe, it, expect } from "vitest";
import os from "node:os";
import { createRequire } from "node:module";
import { TRACK } from "./helpers.js";

const { shortPath, clip, describeTool, tmuxSessions, linkKeys } = createRequire(import.meta.url)(TRACK);

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
