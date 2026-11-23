import { describe, expect, it } from "vitest";
import { interpretAssurance, mfaErrorMessage, parseTotpCode, type MfaFactor } from "@/lib/mfa";

const factor: MfaFactor = { id: "f1", friendlyName: "Phone", createdAt: "2026-11-22T00:00:00Z" };

describe("interpretAssurance", () => {
  it("does not challenge someone with no authenticator app", () => {
    const state = interpretAssurance("aal1", "aal1", []);
    expect(state).toMatchObject({ enrolled: false, needsChallenge: false, factorId: null });
  });

  it("challenges an enrolled person who has only used their password", () => {
    const state = interpretAssurance("aal1", "aal2", [factor]);
    expect(state).toMatchObject({ enrolled: true, needsChallenge: true, factorId: "f1" });
  });

  it("does not challenge again once the code was verified", () => {
    expect(interpretAssurance("aal2", "aal2", [factor]).needsChallenge).toBe(false);
  });

  it("never challenges when the provider returns no levels", () => {
    expect(interpretAssurance(undefined, undefined, [factor]).needsChallenge).toBe(false);
  });
});

describe("parseTotpCode", () => {
  it("accepts six digits with spaces or dashes", () => {
    expect(parseTotpCode("123456")).toBe("123456");
    expect(parseTotpCode(" 123 456 ")).toBe("123456");
    expect(parseTotpCode("123-456")).toBe("123456");
  });

  it("rejects anything else", () => {
    for (const bad of ["", "12345", "1234567", "12345a", "abcdef"]) {
      expect(parseTotpCode(bad), bad).toBeNull();
    }
  });
});

describe("mfaErrorMessage", () => {
  it("explains a wrong code in plain words", () => {
    expect(
      mfaErrorMessage({ code: "mfa_verification_failed", message: "Invalid TOTP code" }),
    ).toMatch(/current 6-digit code/);
  });

  it("explains rate limiting", () => {
    expect(mfaErrorMessage({ code: "over_request_rate_limit" })).toMatch(/Too many attempts/);
  });

  it("falls back to a generic message", () => {
    expect(mfaErrorMessage(null)).toMatch(/try again/i);
  });
});
