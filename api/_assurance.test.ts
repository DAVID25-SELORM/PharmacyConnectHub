import { describe, expect, it } from "vitest";
import { adminSessionAllowed, sessionAssuranceLevel, tokenAssuranceLevel } from "./_assurance.js";

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

describe("sessionAssuranceLevel: a session opened on a remembered device", () => {
  const claims = { aal: "aal1", sub: "user-1", session_id: "session-1" };
  const database = (answer: { data: unknown; error: { message: string } | null }) => {
    const calls: unknown[] = [];
    return {
      calls,
      client: {
        rpc: async (fn: string, args: Record<string, unknown>) => {
          calls.push([fn, args]);
          return answer;
        },
      },
    };
  };

  it("counts as two-step when the database says the device is still remembered", async () => {
    const db = database({ data: true, error: null });
    expect(await sessionAssuranceLevel(db.client, token(claims))).toBe("aal2");
    expect(db.calls).toEqual([
      ["mfa_remembered_session_ok", { p_user_id: "user-1", p_session_id: "session-1" }],
    ]);
  });

  it("does not when the database says no, cannot answer, or does not know the function yet", async () => {
    for (const answer of [
      { data: false, error: null },
      { data: null, error: { message: "Could not find the function" } },
      { data: "true", error: null },
    ]) {
      expect(await sessionAssuranceLevel(database(answer).client, token(claims))).toBe("aal1");
    }
    const throwing = { rpc: async () => Promise.reject(new Error("network")) };
    expect(await sessionAssuranceLevel(throwing, token(claims))).toBe("aal1");
  });

  it("asks nothing for a code-verified session or a token without a person and session", async () => {
    const db = database({ data: true, error: null });
    expect(await sessionAssuranceLevel(db.client, token({ ...claims, aal: "aal2" }))).toBe("aal2");
    expect(await sessionAssuranceLevel(db.client, token({ aal: "aal1", sub: "user-1" }))).toBe(
      "aal1",
    );
    expect(await sessionAssuranceLevel(db.client, "not-a-token")).toBe("aal1");
    expect(db.calls).toEqual([]);
  });
});
