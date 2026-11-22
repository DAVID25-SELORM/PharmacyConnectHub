import { describe, expect, it } from "vitest";
import { adminSessionAllowed, tokenAssuranceLevel } from "./_assurance.js";

function token(payload: object) {
  const part = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url");
  return `${part({ alg: "HS256" })}.${part(payload)}.signature`;
}

describe("tokenAssuranceLevel", () => {
  it("reads aal2 from a verified-code session", () => {
    expect(tokenAssuranceLevel(token({ aal: "aal2" }))).toBe("aal2");
  });

  it("treats everything else as aal1", () => {
    expect(tokenAssuranceLevel(token({ aal: "aal1" }))).toBe("aal1");
    expect(tokenAssuranceLevel(token({}))).toBe("aal1");
    expect(tokenAssuranceLevel("not-a-token")).toBe("aal1");
    expect(tokenAssuranceLevel("")).toBe("aal1");
  });
});

describe("adminSessionAllowed", () => {
  it("passes the token's level to the database and returns its answer", async () => {
    const calls: unknown[] = [];
    const client = {
      rpc: async (fn: string, args: Record<string, unknown>) => {
        calls.push([fn, args]);
        return { data: args.p_aal === "aal2", error: null };
      },
    };
    expect(await adminSessionAllowed(client, token({ aal: "aal2" }))).toBe(true);
    expect(await adminSessionAllowed(client, token({ aal: "aal1" }))).toBe(false);
    expect(calls[0]).toEqual(["admin_mfa_ok", { p_aal: "aal2" }]);
  });

  it("refuses when the database cannot answer", async () => {
    const client = { rpc: async () => ({ data: null, error: { message: "down" } }) };
    expect(await adminSessionAllowed(client, token({ aal: "aal2" }))).toBe(false);
  });
});
