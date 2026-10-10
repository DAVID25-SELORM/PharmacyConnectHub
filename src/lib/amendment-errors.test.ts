import { describe, expect, it } from "vitest";
import { amendmentError } from "./amendment-errors";

describe("amendmentError", () => {
  it("passes the database's own message through", () => {
    expect(
      amendmentError({ message: "A change is already awaiting a response on this order." }),
    ).toBe("A change is already awaiting a response on this order.");
  });

  it("explains an action that has been switched off", () => {
    expect(
      amendmentError({ message: "permission denied for function propose_price_amendment" }),
    ).toMatch(/switched off for now/);
  });

  it("falls back to a plain message", () => {
    expect(amendmentError(null)).toBe("Something went wrong. Please try again.");
    expect(amendmentError({ message: "" })).toBe("Something went wrong. Please try again.");
  });
});
