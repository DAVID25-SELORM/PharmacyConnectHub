import { describe, expect, it } from "vitest";
import { adminsWithoutMfa, type AdminMfaStatus } from "@/lib/admin-mfa-policy";

describe("adminsWithoutMfa", () => {
  it("lists only admins without a verified authenticator app", () => {
    const status: AdminMfaStatus = {
      required: false,
      admins: [
        { user_id: "1", email: "a@x.com", enrolled: true },
        { user_id: "2", email: "b@x.com", enrolled: false },
        { user_id: "3", email: "c@x.com", enrolled: false },
      ],
    };
    expect(adminsWithoutMfa(status)).toEqual(["b@x.com", "c@x.com"]);
  });

  it("is empty when everyone is set up", () => {
    expect(
      adminsWithoutMfa({
        required: true,
        admins: [{ user_id: "1", email: "a@x.com", enrolled: true }],
      }),
    ).toEqual([]);
  });
});
