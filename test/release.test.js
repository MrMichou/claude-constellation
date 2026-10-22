// Unit tests for the pure helpers of scripts/release.js (exported when the file is required).
import { describe, it, expect } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { ROOT } from "./helpers.js";

const { nextVersion, cutChangelog, releaseNotes } = createRequire(import.meta.url)(
  path.join(ROOT, "scripts", "release.js"),
);

const CHANGELOG = `# Changelog

Intro.

## [Unreleased]

### Added
- New thing.

## [0.1.0] - 2026-10-01

### Fixed
- Old bug.
`;

describe("nextVersion", () => {
  it("bumps patch, minor and major", () => {
    expect(nextVersion("1.2.3", "patch")).toBe("1.2.4");
    expect(nextVersion("1.2.3", "minor")).toBe("1.3.0");
    expect(nextVersion("1.2.3", "major")).toBe("2.0.0");
  });

  it("accepts an explicit version, equal to the current one for a first tag", () => {
    expect(nextVersion("0.1.0", "0.1.0")).toBe("0.1.0");
    expect(nextVersion("0.1.0", "0.10.0")).toBe("0.10.0");
  });

  it("rejects going backwards and malformed versions", () => {
    expect(() => nextVersion("0.2.0", "0.1.9")).toThrow(/older/);
    expect(() => nextVersion("0.1.0", "v0.2.0")).toThrow(/X\.Y\.Z/);
    expect(() => nextVersion("0.1.0", "next")).toThrow(/X\.Y\.Z/);
  });
});

describe("cutChangelog", () => {
  it("moves the Unreleased entries under the new version and keeps older ones", () => {
    const out = cutChangelog(CHANGELOG, "0.2.0", "2026-10-22");
    expect(out).toContain("## [Unreleased]\n\n## [0.2.0] - 2026-10-22\n\n### Added\n- New thing.\n\n## [0.1.0]");
    expect(out.startsWith("# Changelog\n\nIntro.\n")).toBe(true);
    expect(releaseNotes(out, "0.1.0")).toBe("### Fixed\n- Old bug.");
  });

  it("refuses an empty Unreleased section, a duplicate version or a missing section", () => {
    const empty = cutChangelog(CHANGELOG, "0.2.0", "2026-10-22");
    expect(() => cutChangelog(empty, "0.3.0", "2026-10-22")).toThrow(/empty/);
    expect(() => cutChangelog(CHANGELOG, "0.1.0", "2026-10-22")).toThrow(/already/);
    expect(() => cutChangelog("# Changelog\n", "0.2.0", "2026-10-22")).toThrow(/no ## \[Unreleased\]/);
  });
});

describe("releaseNotes", () => {
  it("returns the section body without its heading", () => {
    expect(releaseNotes(CHANGELOG, "Unreleased")).toBe("### Added\n- New thing.");
  });

  it("fails for an unknown version", () => {
    expect(() => releaseNotes(CHANGELOG, "9.9.9")).toThrow(/no changelog entries/);
  });

  it("finds every released version of the real CHANGELOG.md", () => {
    const real = fs.readFileSync(path.join(ROOT, "CHANGELOG.md"), "utf8");
    expect(real).toMatch(/^## \[Unreleased\]$/m);
    for (const [, v] of real.matchAll(/^## \[(\d+\.\d+\.\d+)\] - \d{4}-\d{2}-\d{2}$/gm)) {
      expect(releaseNotes(real, v)).not.toBe("");
    }
  });
});
