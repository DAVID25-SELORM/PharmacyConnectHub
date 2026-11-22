import { describe, expect, it } from "vitest";
import {
  PRIVACY_VERSION,
  acceptedBoth,
  consentMetadata,
  daysUntilDue,
  exportFilename,
  signedUpWithConsent,
} from "@/lib/privacy";

describe("consent helpers", () => {
  it("records the current version in sign-up metadata and recognises it later", () => {
    const metadata = consentMetadata();
    expect(metadata).toEqual({ consent_version: PRIVACY_VERSION });
    expect(signedUpWithConsent(metadata)).toBe(true);
    expect(signedUpWithConsent({ consent_version: "2020-01-01" })).toBe(false);
    expect(signedUpWithConsent(undefined)).toBe(false);
  });

  it("needs both documents at the current version", () => {
    const both = [
      { document: "privacy_notice", version: PRIVACY_VERSION },
      { document: "terms", version: PRIVACY_VERSION },
    ];
    expect(acceptedBoth(both)).toBe(true);
    expect(acceptedBoth([both[0]])).toBe(false);
    expect(acceptedBoth([])).toBe(false);
    expect(acceptedBoth(both.map((row) => ({ ...row, version: "older" })))).toBe(false);
  });
});

describe("exportFilename", () => {
  it("names the file with the date", () => {
    expect(exportFilename(new Date("2026-11-22T10:00:00Z"))).toBe(
      "drugxone-my-data-2026-11-22.json",
    );
  });
});

describe("daysUntilDue", () => {
  const now = new Date("2026-11-22T00:00:00Z");
  it("counts days left and goes negative when late", () => {
    expect(daysUntilDue("2026-12-22T00:00:00Z", now)).toBe(30);
    expect(daysUntilDue("2026-11-21T00:00:00Z", now)).toBe(-1);
  });
});
