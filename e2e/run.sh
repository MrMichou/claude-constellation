#!/bin/sh
# End-to-end test: install into a throwaway HOME, feed the hook commands the installer wrote into
# settings.json with Claude Code-shaped events (two sessions, one fanning out to subagents, some
# of them in parallel), then load the installed module and draw every layout from those files
# with each Lua that can run the lock-screen saver.
# Usage: e2e/run.sh [lua...]   (default: lua5.4 lua5.1 luajit; each needs lgi)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
HOME=$(mktemp -d)
export HOME
trap 'rm -rf "$HOME"' EXIT
luas=${*:-lua5.4 lua5.1 luajit}

echo "== install"
node "$root/install.js" >/dev/null

# hook <Event> <json>: runs the command installed for that event, as Claude Code would.
hook() {
  cmd=$(node -e '
    const h = require(process.env.HOME + "/.claude/settings.json").hooks[process.argv[1]] || [];
    const c = h.flatMap((g) => g.hooks).find((x) => /track\.js/.test(x.command));
    if (!c) { console.error("no hook installed for " + process.argv[1]); process.exit(1); }
    console.log(c.command);' "$1")
  printf '%s' "$2" | sh -c "$cmd"
}

echo "== hooks"
S1='"session_id":"e2e-main","cwd":"/work/monorepo"'
S2='"session_id":"e2e-other","cwd":"/work/api"'
hook SessionStart "{$S1}"
hook SessionStart "{$S2}"
hook UserPromptSubmit "{$S1}"
hook UserPromptSubmit "{$S2}"
hook PreToolUse "{$S2,\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/work/ci/deploy.yml\"}}"

# Ten general-purpose subagents started at once (a fan-out), plus seven other types: past 6
# running types the renderer merges the smallest groups into "+k agents".
i=0
while [ $i -lt 10 ]; do
  hook PreToolUse "{$S1,\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"general-purpose\",\"description\":\"migrate pkg$i\"}}"
  i=$((i + 1))
done
i=0
while [ $i -lt 10 ]; do
  hook SubagentStart "{$S1,\"agent_id\":\"gp$i\",\"agent_type\":\"general-purpose\"}" &
  i=$((i + 1))
done
wait
for t in Explore Plan code-reviewer test-writer docs-writer perf-auditor i18n-checker; do
  hook PreToolUse "{$S1,\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"$t\",\"description\":\"$t work\"}}"
  hook SubagentStart "{$S1,\"agent_id\":\"$t\",\"agent_type\":\"$t\"}"
done
hook PostToolUse "{$S1,\"tool_name\":\"Agent\"}"
hook Stop "{$S1}" # the parent ends its turn while its subagents work

# Subagent activity: tool calls, a permission, one finishing, one shared file with e2e-other.
hook PreToolUse "{$S1,\"agent_id\":\"gp0\",\"agent_type\":\"general-purpose\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/work/ci/deploy.yml\"}}"
hook PreToolUse "{$S1,\"agent_id\":\"Explore\",\"agent_type\":\"Explore\",\"tool_name\":\"Grep\",\"tool_input\":{\"pattern\":\"import\"}}"
hook PermissionRequest "{$S1,\"agent_id\":\"Plan\",\"agent_type\":\"Plan\",\"tool_name\":\"Bash\"}"
hook SubagentStop "{$S1,\"agent_id\":\"code-reviewer\",\"agent_type\":\"code-reviewer\"}"

node -e '
  const assert = require("assert");
  const s = require(process.env.HOME + "/.claude/constellation/e2e-main.json");
  const ids = Object.keys(s.agents);
  assert.strictEqual(ids.length, 17, "17 subagents, none lost to the parallel fan-out: " + ids);
  assert.strictEqual(s.state, "done", "subagent events must not change the session state");
  assert.ok(s.history.every((h) => h.tool === "Agent"), "subagent calls kept out of the session history");
  assert.strictEqual(s.agents.gp0.state, "tool");
  assert.strictEqual(s.agents.Plan.state, "permission");
  assert.strictEqual(s.agents["code-reviewer"].state, "done");
  assert.strictEqual(s.agents.Explore.label, "Explore work");
  assert.ok(s.links["file:/work/ci/deploy.yml"], "a subagent touching a file still links sessions");
  assert.ok(s.timeline.every((e) => e.e !== undefined), "subagents must not leave calls open");
  console.log("session files OK");'

module="$HOME/.config/awesome/ui/desktop/claude_constellation"
for lua in $luas; do
  echo "== render ($lua)"
  "$lua" "$root/e2e/render.lua" "$module" "$HOME/frames-$lua"
done

echo "== demo"
mkdir -p "$HOME/demo/wf" "$HOME/demo/layouts"
(cd "$HOME" && lua5.4 "$root/demo/record.lua" "$HOME/demo/wf" wallpaper 640 360 2 4 workflow \
  && lua5.4 "$root/demo/record.lua" "$HOME/demo/layouts" layouts 640 360 1 9)
echo "e2e OK"
