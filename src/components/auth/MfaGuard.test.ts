import { describe, expect, it } from "vitest";
import { isOpenPath } from "@/components/auth/MfaGuard";

describe("isOpenPath", () => {
  it("treats sign-in and public pages as open", () => {
    for (const path of [
      "/",
      "/login",
      "/signup",
      "/forgot-password",
      "/reset-password",
      "/help",
      "/privacy",
      "/terms/",
    ]) {
      expect(isOpenPath(path), path).toBe(true);
    }
  });

  it("guards every private page", () => {
    for (const path of [
      "/dashboard",
      "/wholesaler",
      "/pharmacy/inventory",
      "/admin",
      "/security",
      "/settings",
      "/pay/return",
    ]) {
      expect(isOpenPath(path), path).toBe(false);
    }
  });
});
