import { describe, expect, it } from "vitest";
import { subscriptionToRow, vapidKeyToBytes } from "@/lib/web-push";

describe("vapidKeyToBytes", () => {
  it("decodes base64url keys, with or without padding", () => {
    // bytes 251, 255, 190 encode to "-_--" in base64url ("+/++" in base64)
    expect(Array.from(vapidKeyToBytes("-_--"))).toEqual([251, 255, 190]);
    expect(Array.from(vapidKeyToBytes("AQID"))).toEqual([1, 2, 3]);
    expect(Array.from(vapidKeyToBytes("AQI"))).toEqual([1, 2]);
  });
});

describe("subscriptionToRow", () => {
  const when = new Date("2026-11-18T10:00:00.000Z");

  it("maps a browser subscription to a row owned by the user", () => {
    const row = subscriptionToRow(
      {
        toJSON: () => ({
          endpoint: "https://push.example/abc",
          keys: { p256dh: "pk", auth: "ak" },
        }),
      },
      "user-1",
      "Test Browser",
      when,
    );
    expect(row).toEqual({
      user_id: "user-1",
      endpoint: "https://push.example/abc",
      p256dh: "pk",
      auth: "ak",
      user_agent: "Test Browser",
      last_seen_at: "2026-11-18T10:00:00.000Z",
    });
  });

  it("rejects a subscription without keys", () => {
    expect(
      subscriptionToRow(
        { toJSON: () => ({ endpoint: "https://push.example/abc" }) },
        "user-1",
        null,
        when,
      ),
    ).toBeNull();
  });
});
