import { describe, expect, it } from "vitest";
import { formatGhanaPhone, isValidGhanaPhone, normalizeGhanaPhone } from "@/lib/ghana-phone";

describe("normalizeGhanaPhone", () => {
  it("normalizes local numbers with a leading zero", () => {
    expect(normalizeGhanaPhone("024 123 4567")).toBe("+233241234567");
  });

  it("normalizes numbers that already include the country code", () => {
    expect(normalizeGhanaPhone("+233 24 123 4567")).toBe("+233241234567");
    expect(normalizeGhanaPhone("233241234567")).toBe("+233241234567");
  });

  it("rejects numbers that are too short", () => {
    expect(() => normalizeGhanaPhone("0241234")).toThrow("Enter a valid Ghana phone number");
  });
});

describe("isValidGhanaPhone", () => {
  it("returns true only for valid Ghana phone numbers", () => {
    expect(isValidGhanaPhone("0241234567")).toBe(true);
    expect(isValidGhanaPhone("not-a-phone")).toBe(false);
  });
});

describe("formatGhanaPhone", () => {
  it("formats valid numbers in a readable way", () => {
    expect(formatGhanaPhone("0241234567")).toBe("+233 24 123 4567");
  });

  it("falls back to the trimmed original value for invalid numbers", () => {
    expect(formatGhanaPhone(" invalid ")).toBe("invalid");
  });
});
