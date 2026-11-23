import { describe, expect, it } from "vitest";
import { checkPassword, PASSWORD_MAX_LENGTH, PASSWORD_MIN_LENGTH } from "@/lib/password-policy";

describe("checkPassword", () => {
  it("accepts a normal mixed password", () => {
    expect(checkPassword("Tamale-River-48").ok).toBe(true);
    expect(checkPassword("bluefish92kite").ok).toBe(true);
  });

  it("accepts a long passphrase without numbers or symbols", () => {
    expect(checkPassword("correct horse battery staple").ok).toBe(true);
    expect(checkPassword("sixteencharsonlyz").ok).toBe(true);
  });

  it("refuses passwords that are too short", () => {
    const result = checkPassword("Ab1!xyz");
    expect(result.ok).toBe(false);
    expect(result.issues[0]).toContain(String(PASSWORD_MIN_LENGTH));
  });

  it("refuses passwords that are too long to be fully hashed", () => {
    const result = checkPassword("aB3".repeat(30) + "xQ");
    expect(result.ok).toBe(false);
    expect(result.issues.join(" ")).toContain(String(PASSWORD_MAX_LENGTH));
  });

  it("refuses common passwords even with digits or symbols added", () => {
    for (const bad of [
      "password123!",
      "Password2024",
      "welcome12345",
      "Pharmacy@123",
      "qwertyuiop",
    ]) {
      expect(checkPassword(bad).ok, bad).toBe(false);
    }
  });

  it("refuses repeated and sequential passwords", () => {
    expect(checkPassword("aaaaaaaaaaaa").ok).toBe(false);
    expect(checkPassword("abcabcabcabc").ok).toBe(false);
    expect(checkPassword("1234567890").ok).toBe(false);
    expect(checkPassword("abcdefghijk1").ok).toBe(false);
  });

  it("refuses passwords built from the email or name", () => {
    expect(checkPassword("kwame.mensah2024", { email: "kwame.mensah@mail.com" }).ok).toBe(false);
    expect(checkPassword("Mensah-Pharma-77", { name: "Kwame Mensah" }).ok).toBe(false);
    expect(
      checkPassword("Tamale-River-48", { email: "kwame@mail.com", name: "Kwame Mensah" }).ok,
    ).toBe(true);
  });

  it("requires a second character type below passphrase length", () => {
    expect(checkPassword("zebrakitepool").ok).toBe(false);
    expect(checkPassword("zebrakite-pool").ok).toBe(true);
  });

  it("scores stronger passwords higher", () => {
    const weak = checkPassword("short");
    const fair = checkPassword("bluefish92kite");
    const strong = checkPassword("Tamale-River-48-sunrise!");
    expect(weak.score).toBeLessThan(fair.score);
    expect(fair.score).toBeLessThanOrEqual(strong.score);
    expect(strong.label).toBe("Strong");
  });

  it("scores an empty field as zero", () => {
    expect(checkPassword("").score).toBe(0);
  });
});
