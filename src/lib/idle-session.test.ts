import { describe, expect, it } from "vitest";
import {
  ADMIN_IDLE_MS,
  BUSINESS_IDLE_MS,
  IDLE_WARNING_MS,
  idleLimitFor,
  idleStatus,
  readLastActivity,
  secondsLeft,
  writeLastActivity,
} from "@/lib/idle-session";

describe("idleLimitFor", () => {
  it("gives platform admins a shorter limit", () => {
    expect(idleLimitFor(["admin"])).toBe(ADMIN_IDLE_MS);
    expect(idleLimitFor(["pharmacy"])).toBe(BUSINESS_IDLE_MS);
    expect(idleLimitFor([])).toBe(BUSINESS_IDLE_MS);
    expect(ADMIN_IDLE_MS).toBeLessThan(BUSINESS_IDLE_MS);
  });
});

describe("idleStatus", () => {
  const limit = 10 * 60 * 1000;
  it("is active while recently used", () => {
    expect(idleStatus(1_000, 1_000, limit)).toBe("active");
    expect(idleStatus(limit - IDLE_WARNING_MS - 1, 0, limit)).toBe("active");
  });
  it("warns in the last two minutes", () => {
    expect(idleStatus(limit - IDLE_WARNING_MS, 0, limit)).toBe("warning");
    expect(idleStatus(limit - 1, 0, limit)).toBe("warning");
  });
  it("expires at the limit, including after the computer slept", () => {
    expect(idleStatus(limit, 0, limit)).toBe("expired");
    expect(idleStatus(limit * 10, 0, limit)).toBe("expired");
  });
});

describe("secondsLeft", () => {
  it("counts down and never goes negative", () => {
    expect(secondsLeft(0, 0, 60_000)).toBe(60);
    expect(secondsLeft(59_001, 0, 60_000)).toBe(1);
    expect(secondsLeft(90_000, 0, 60_000)).toBe(0);
  });
});

describe("activity storage", () => {
  it("round-trips and falls back when empty, invalid or blocked", () => {
    const store = new Map<string, string>();
    const storage = {
      getItem: (k: string) => store.get(k) ?? null,
      setItem: (k: string, v: string) => void store.set(k, v),
    };
    expect(readLastActivity(storage, 5)).toBe(5);
    writeLastActivity(storage, 1234);
    expect(readLastActivity(storage, 5)).toBe(1234);
    store.set("drugxone.last_activity", "junk");
    expect(readLastActivity(storage, 7)).toBe(7);
    const blocked = {
      getItem: () => {
        throw new Error("blocked");
      },
      setItem: () => {
        throw new Error("blocked");
      },
    };
    expect(readLastActivity(blocked, 9)).toBe(9);
    expect(() => writeLastActivity(blocked, 1)).not.toThrow();
  });
});
