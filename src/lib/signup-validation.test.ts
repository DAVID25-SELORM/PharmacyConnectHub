import { describe, expect, it } from "vitest";
import { getSignupSchema } from "@/lib/signup-validation";
import { buildSignupPayload } from "@/lib/signup-payload";

const form = {
  ownerFullName: "Test Owner",
  ownerPhone: "0241234567",
  businessName: "Test Pharmacy",
  businessPhone: "0241234567",
  businessEmail: "public@example.com",
  licenseNumber: "PCG-123",
  city: "Accra",
  region: "Greater Accra",
  gpsAddress: "",
  locationDescription: "",
  workingHours: "",
  ownerEmail: "owner@example.com",
  password: "test-password",
  ownerIsSuperintendent: false,
  superintendentName: "Test Pharmacist",
  superintendentPhone: "0241234567",
  superintendentEmail: "pharmacist@example.com",
};

describe("signup validation", () => {
  it.each(["ownerPhone", "businessPhone", "superintendentPhone"] as const)(
    "accepts formatted %s longer than 20 characters and stores a normalized number",
    (field) => {
      const value = "+233 (0) 24  123  4567";
      expect(value.length).toBeGreaterThan(20);
      const parsed = getSignupSchema("pharmacy").parse({ ...form, [field]: value });
      const payload = buildSignupPayload(parsed, "pharmacy");
      expect(payload.metadata.phone).toBe("+233241234567");
      expect(payload.metadata.public_phone).toBe("+233241234567");
      expect(payload.metadata.superintendent_phone).toBe("+233241234567");
    },
  );

  it.each(["ownerPhone", "businessPhone", "superintendentPhone"] as const)(
    "identifies invalid or multiple numbers in %s",
    (field) => {
      for (const value of ["", "0241234", "0241234567 / 0201234567"]) {
        const result = getSignupSchema("pharmacy").safeParse({ ...form, [field]: value });
        expect(result.success).toBe(false);
        if (!result.success) {
          expect(result.error.issues[0].path).toEqual([field]);
          expect(result.error.issues[0].message).toMatch(/phone/i);
        }
      }
    },
  );

  it("ignores unused superintendent fields", () => {
    const stale = {
      ...form,
      superintendentPhone: "invalid".repeat(10),
      superintendentName: "x".repeat(101),
      superintendentEmail: "invalid",
    };
    expect(getSignupSchema("wholesaler").safeParse(stale).success).toBe(true);
    expect(
      getSignupSchema("pharmacy").safeParse({ ...stale, ownerIsSuperintendent: true }).success,
    ).toBe(true);
    expect(getSignupSchema("pharmacy").safeParse(stale).success).toBe(false);
  });
});
