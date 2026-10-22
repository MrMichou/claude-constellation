#!/usr/bin/env node
// Cuts a release, following the claude-status-bar-awesomewm model:
//  - moves CHANGELOG.md's [Unreleased] section under "## [X.Y.Z] - YYYY-MM-DD"
//  - bumps the version in package.json / package-lock.json
//  - commits "chore: release X.Y.Z" and creates the annotated tag vX.Y.Z
// Pushing the tag (git push origin main --follow-tags) triggers .github/workflows/release.yml,
// which re-runs CI and publishes the GitHub release with the changelog section as notes.
// Usage: node scripts/release.js <patch|minor|major|X.Y.Z> [--dry-run]
//        node scripts/release.js notes <X.Y.Z>   (prints that version's changelog section)

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const ROOT = path.join(__dirname, "..");
const CHANGELOG = path.join(ROOT, "CHANGELOG.md");
const SEMVER = /^(\d+)\.(\d+)\.(\d+)$/;

function parse(v) {
  const m = SEMVER.exec(v);
  if (!m) throw new Error(`not a X.Y.Z version: ${v}`);
  return m.slice(1).map(Number);
}

function compare(a, b) {
  const [pa, pb] = [parse(a), parse(b)];
  for (let i = 0; i < 3; i++) if (pa[i] !== pb[i]) return pa[i] - pb[i];
  return 0;
}

// Next version from the current one: a bump keyword, or an explicit X.Y.Z that must not go
// backwards (equal is allowed so a version already in package.json can get its first tag).
function nextVersion(current, spec) {
  const [major, minor, patch] = parse(current);
  if (spec === "major") return `${major + 1}.0.0`;
  if (spec === "minor") return `${major}.${minor + 1}.0`;
  if (spec === "patch") return `${major}.${minor}.${patch + 1}`;
  if (compare(spec, current) < 0) throw new Error(`${spec} is older than the current ${current}`);
  return spec;
}

// Index of the "## [name]" heading and of the next "## " heading (or end of text).
function section(text, name) {
  const lines = text.split("\n");
  const start = lines.findIndex((l) => l.startsWith(`## [${name}]`));
  if (start < 0) return null;
  let end = lines.findIndex((l, i) => i > start && l.startsWith("## "));
  if (end < 0) end = lines.length;
  return { lines, start, end, body: lines.slice(start + 1, end).join("\n").trim() };
}

// Moves the [Unreleased] entries under a new version heading, leaving [Unreleased] empty.
function cutChangelog(text, version, date) {
  const s = section(text, "Unreleased");
  if (!s) throw new Error("CHANGELOG.md has no ## [Unreleased] section");
  if (!s.body) throw new Error("the [Unreleased] section is empty: nothing to release");
  if (section(text, version)) throw new Error(`CHANGELOG.md already has a [${version}] section`);
  const head = s.lines.slice(0, s.start + 1);
  const tail = s.lines.slice(s.end);
  return [...head, "", `## [${version}] - ${date}`, "", s.body, "", ...tail].join("\n");
}

function releaseNotes(text, version) {
  const s = section(text, version);
  if (!s || !s.body) throw new Error(`no changelog entries for ${version}`);
  return s.body;
}

const git = (...args) => execFileSync("git", args, { cwd: ROOT, encoding: "utf8" }).trim();
const readJson = (f) => JSON.parse(fs.readFileSync(f, "utf8"));
const writeJson = (f, o) => fs.writeFileSync(f, JSON.stringify(o, null, 2) + "\n");

function release(spec, dryRun) {
  const pkgPath = path.join(ROOT, "package.json");
  const lockPath = path.join(ROOT, "package-lock.json");
  const pkg = readJson(pkgPath);
  const version = nextVersion(pkg.version, spec);
  const tag = `v${version}`;

  const problems = [
    git("rev-parse", "--abbrev-ref", "HEAD") !== "main" && "release from main only",
    git("status", "--porcelain") && "working tree not clean: commit or stash first",
    git("tag", "--list", tag) && `tag ${tag} already exists`,
  ].filter(Boolean);
  if (problems.length && !dryRun) throw new Error(problems.join("; "));

  const date = new Date().toISOString().slice(0, 10);
  const changelog = cutChangelog(fs.readFileSync(CHANGELOG, "utf8"), version, date);
  console.log(`Releasing ${pkg.version} -> ${version}\n\n${releaseNotes(changelog, version)}\n`);
  if (dryRun) return console.log(["(dry run: nothing written)", ...problems.map((p) => `warning: ${p}`)].join("\n"));

  execFileSync("npm", ["test"], { cwd: ROOT, stdio: "inherit" });

  fs.writeFileSync(CHANGELOG, changelog);
  writeJson(pkgPath, { ...pkg, version });
  if (fs.existsSync(lockPath)) {
    const lock = readJson(lockPath);
    lock.version = version;
    if (lock.packages && lock.packages[""]) lock.packages[""].version = version;
    writeJson(lockPath, lock);
  }
  git("add", "CHANGELOG.md", "package.json", ...(fs.existsSync(lockPath) ? ["package-lock.json"] : []));
  git("commit", "-q", "-m", `chore: release ${version}`);
  git("tag", "-a", tag, "-m", tag);
  console.log(`Created commit and tag ${tag}. Publish with:\n  git push origin main --follow-tags`);
}

if (require.main === module) {
  const [cmd, arg] = process.argv.slice(2);
  try {
    if (cmd === "notes") console.log(releaseNotes(fs.readFileSync(CHANGELOG, "utf8"), arg));
    else if (cmd) release(cmd, process.argv.includes("--dry-run"));
    else throw new Error("usage: release.js <patch|minor|major|X.Y.Z> [--dry-run] | notes <X.Y.Z>");
  } catch (e) {
    console.error(`release: ${e.message}`);
    process.exit(1);
  }
} else {
  module.exports = { nextVersion, cutChangelog, releaseNotes };
}
