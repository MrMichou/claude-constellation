// Tests for bin/constellation-grafana-token against a fake Grafana: the token is piped on stdin,
// the secret store is a fake secret-tool that records its arguments and what it gets on stdin.
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { execSync, spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { tmpHome, ROOT } from "./helpers.js";

const CMD = path.join(ROOT, "bin", "constellation-grafana-token");

// Fake Grafana: /api/org answers for the right token only.
function fakeGrafana() {
  const seen = [];
  const server = http.createServer((req, res) => {
    seen.push(`${req.method} ${req.url} ${req.headers.authorization || ""}`);
    if (req.url === "/api/org") {
      const ok = req.headers.authorization === "Bearer glsa_good";
      res.writeHead(ok ? 200 : 401, { "Content-Type": "application/json" }).end(ok ? '{"id":1,"name":"Ludia"}' : "{}");
    } else res.writeHead(404).end();
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () =>
    resolve({ url: `http://127.0.0.1:${server.address().port}`, seen, close: () => server.close() })));
}

function run(args, env, stdin) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [CMD, ...args], { env: { ...process.env, ...env } });
    let stdout = "", stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("close", (code) => resolve({ code, stdout, stderr }));
    child.stdin.end(stdin || "");
  });
}

describe("constellation-grafana-token", () => {
  let h, gf, store, fake, bin;
  beforeEach(() => {
    h = tmpHome();
    bin = path.join(h.home, "bin");
    fs.mkdirSync(bin);
    fs.symlinkSync(execSync("command -v curl", { shell: "/bin/sh" }).toString().trim(), path.join(bin, "curl"));
    store = path.join(h.home, "stored");
    fake = path.join(h.home, "secret-tool");
    fs.writeFileSync(fake, `#!/bin/sh\necho "$@" > '${store}.args'\n/bin/cat > '${store}'\n`, { mode: 0o755 });
  });
  afterEach(() => { gf && gf.close(); h.cleanup(); });

  const env = () => ({ HOME: h.home, GRAFANA_URL: "", CONSTELLATION_SECRET_TOOL: fake,
    XDG_CONFIG_HOME: path.join(h.home, ".config"), PATH: bin }); // curl only, no awesome-client

  it("checks the token and stores it for the HUD, never on a command line", async () => {
    gf = await fakeGrafana();
    const r = await run([gf.url + "/"], env(), "glsa_good\n");
    expect(r.stderr).toBe("");
    expect(r.code).toBe(0);
    expect(r.stdout).toMatch(/Token stored for .* \(org Ludia\)/);
    expect(fs.readFileSync(store, "utf8")).toBe("glsa_good");
    expect(fs.readFileSync(store + ".args", "utf8").trim())
      .toBe(`store --label=Grafana token (claude-constellation) service claude-constellation-grafana server ${gf.url}`);
  });

  it("takes the url from grafana.conf, before the graph sections", async () => {
    gf = await fakeGrafana();
    const conf = path.join(h.home, ".config", "claude-constellation", "grafana.conf");
    fs.mkdirSync(path.dirname(conf), { recursive: true });
    fs.writeFileSync(conf, `# Grafana\nurl = "${gf.url}"   # main\n\n[CPU]\nurl = http://elsewhere\n`);
    const r = await run([], env(), "glsa_good");
    expect(r.code).toBe(0);
    expect(fs.readFileSync(store, "utf8")).toBe("glsa_good");
  });

  it("refuses a token Grafana rejects, and runs without a url, storing nothing", async () => {
    expect((await run([], env(), "x")).stderr).toMatch(/no Grafana url/);
    gf = await fakeGrafana();
    const r = await run([gf.url], env(), "glsa_bad");
    expect(r.code).toBe(1);
    expect(r.stderr).toMatch(/refused the token/);
    expect(fs.existsSync(store)).toBe(false);
  });

  it("clears the stored token", async () => {
    const r = await run(["--clear", "http://g"], env());
    expect(r.code).toBe(0);
    expect(fs.readFileSync(store + ".args", "utf8").trim()).toBe("clear service claude-constellation-grafana server http://g");
  });
});
