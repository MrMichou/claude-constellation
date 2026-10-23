// Tests for bin/constellation-promview-login against a fake Promview: the browser leg is
// played by fetching the printed sign-in URL, the secret store by a fake secret-tool that
// records its arguments and the token it gets on stdin.
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { execSync, spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { tmpHome, ROOT } from "./helpers.js";

const LOGIN = path.join(ROOT, "bin", "constellation-promview-login");

// Fake Promview: login redirects to the loopback callback with a code, exchange trades it.
function fakePromview({ exchangeStatus = 200 } = {}) {
  const seen = [];
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://x");
    seen.push(`${req.method} ${url.pathname}`);
    if (url.pathname === "/api/v1/auth/oidc/login") {
      res.writeHead(302, { Location: `${url.searchParams.get("desktop_redirect")}?code=c0de` }).end();
    } else if (url.pathname === "/api/v1/auth/desktop/exchange") {
      let body = "";
      req.on("data", (d) => (body += d));
      req.on("end", () => {
        const ok = JSON.parse(body).code === "c0de" && exchangeStatus === 200;
        res.writeHead(ok ? 200 : exchangeStatus || 400, { "Content-Type": "application/json" })
          .end(ok ? '{"token":"s3cret"}' : "{}");
      });
    } else if (url.pathname === "/api/v1/me") {
      const ok = req.headers.authorization === "Bearer s3cret";
      res.writeHead(ok ? 200 : 401).end(ok ? '{"username":"oncall"}' : "");
    } else res.writeHead(404).end();
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () =>
    resolve({ url: `http://127.0.0.1:${server.address().port}`, seen, close: () => server.close() })));
}

// Run the command; once it prints the sign-in URL, follow it like a browser would.
function login(args, env) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [LOGIN, "--no-browser", ...args], { env: { ...process.env, ...env } });
    let stdout = "", stderr = "", followed = false;
    child.stdout.on("data", async (d) => {
      stdout += d;
      const m = stdout.match(/(http:\/\/\S+oidc\/login\S+)/);
      if (m && !followed) { followed = true; await fetch(m[1]).catch(() => {}); }
    });
    child.stderr.on("data", (d) => (stderr += d));
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

describe("constellation-promview-login", () => {
  let h, pv, store, fake, bin;
  beforeEach(async () => {
    h = tmpHome();
    bin = path.join(h.home, "bin");
    fs.mkdirSync(bin);
    fs.symlinkSync(execSync("command -v curl", { shell: "/bin/sh" }).toString().trim(), path.join(bin, "curl"));
    store = path.join(h.home, "stored");
    fake = path.join(h.home, "secret-tool");
    fs.writeFileSync(fake, `#!/bin/sh\necho "$@" > '${store}.args'\n/bin/cat > '${store}'\n`, { mode: 0o755 });
  });
  afterEach(() => { pv && pv.close(); h.cleanup(); });

  const env = () => ({ HOME: h.home, PROMVIEW_URL: "", CONSTELLATION_SECRET_TOOL: fake,
    XDG_CONFIG_HOME: path.join(h.home, ".config"), PATH: bin }); // curl only, no awesome-client: leave the real Awesome alone

  it("trades the browser's code for a session token and stores it for the HUD", async () => {
    pv = await fakePromview();
    const r = await login([pv.url + "/"], env());
    expect(r.stderr).toBe("");
    expect(r.code).toBe(0);
    expect(r.stdout).toMatch(/Signed in as oncall/);
    expect(fs.readFileSync(store, "utf8")).toBe("s3cret");
    expect(fs.readFileSync(store + ".args", "utf8").trim())
      .toBe(`store --label=Promview session (claude-constellation) service claude-constellation-promview server ${pv.url}`);
    expect(pv.seen).toContain("POST /api/v1/auth/desktop/exchange");
  });

  it("takes the url from promview.conf", async () => {
    pv = await fakePromview();
    const conf = path.join(h.home, ".config", "claude-constellation", "promview.conf");
    fs.mkdirSync(path.dirname(conf), { recursive: true });
    fs.writeFileSync(conf, `# Promview\nurl = "${pv.url}"\ninterval = 30\n`);
    const r = await login([], env());
    expect(r.code).toBe(0);
    expect(fs.readFileSync(store, "utf8")).toBe("s3cret");
  });

  it("fails without a url, and when the exchange is refused, storing nothing", async () => {
    expect((await login([], env())).stderr).toMatch(/no Promview url/);
    pv = await fakePromview({ exchangeStatus: 403 });
    const r = await login([pv.url], env());
    expect(r.code).toBe(1);
    expect(r.stderr).toMatch(/exchange failed.*403/);
    expect(fs.existsSync(store)).toBe(false);
  });
});
