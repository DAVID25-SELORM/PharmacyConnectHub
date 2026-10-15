import { beforeEach, describe, expect, it, vi } from "vitest";

const rpc = vi.hoisted(() => vi.fn());
vi.mock("@/integrations/supabase/client", () => ({ supabase: { from: () => ({}), rpc } }));

import {
  expiredNote,
  fetchGuardStatus,
  guardAdvice,
  setGuardMode,
  type GuardStatus,
} from "./expiry-guard";

beforeEach(() => rpc.mockReset());

const status = (over: Partial<GuardStatus> = {}): GuardStatus => ({
  mode: "observe",
  changed_at: null,
  products_with_expired_units: 0,
  expired_units: 0,
  orderable_products_with_expired_units: 0,
  products_where_batches_exceed_stock: 0,
  would_have_blocked_7_days: 0,
  would_have_blocked_30_days: 0,
  events: [],
  ...over,
});

describe("what to do next", () => {
  it("says the guard is off and offers to observe", () => {
    const a = guardAdvice(status({ mode: "off" }));
    expect(a.tone).toBe("attention");
    expect(a.headline).toContain("off");
    expect(a.points[0]).toContain("observing");
  });

  it("says enforcing looks safe only when nothing would be refused and nothing is out of step", () => {
    const a = guardAdvice(status());
    expect(a.tone).toBe("good");
    expect(a.headline).toBe("Nothing would have been refused. Enforcing looks safe.");
  });

  it("warns about stock that does not match its batches before anything is enforced", () => {
    const a = guardAdvice(status({ products_where_batches_exceed_stock: 3 }));
    expect(a.tone).toBe("attention");
    expect(a.points.join(" ")).toContain("3 products have more units in batches than in stock");
    expect(guardAdvice(status({ products_where_batches_exceed_stock: 1 })).points[0]).toContain(
      "1 product has",
    );
  });

  it("lists what would have been refused, and orderable products holding expired units", () => {
    const a = guardAdvice(
      status({ would_have_blocked_7_days: 2, orderable_products_with_expired_units: 4 }),
    );
    expect(a.tone).toBe("attention");
    expect(a.points.join(" ")).toContain(
      "4 products are still orderable while holding expired units",
    );
    expect(a.points.join(" ")).toContain("2 sales would have been refused");
    expect(guardAdvice(status({ would_have_blocked_7_days: 1 })).points.join(" ")).toContain(
      "1 sale would have",
    );
  });

  it("when enforced, says so and still flags what is out of step", () => {
    expect(guardAdvice(status({ mode: "enforce" }))).toMatchObject({
      tone: "good",
      headline: "Expired units cannot be sold.",
    });
    const a = guardAdvice(status({ mode: "enforce", products_where_batches_exceed_stock: 2 }));
    expect(a.tone).toBe("attention");
    expect(a.points[0]).toContain("2 products");
  });
});

describe("a wholesaler's stock line", () => {
  it("says nothing when nothing is expired, or when the figure is not known", () => {
    expect(expiredNote(40, 0)).toBeNull();
    expect(expiredNote(40, null)).toBeNull();
    expect(expiredNote(40, undefined)).toBeNull();
  });
  it("says how many are past their date, never more than the stock", () => {
    expect(expiredNote(40, 8)).toBe("8 of these are past their expiry date");
    expect(expiredNote(40, 1)).toBe("1 of these is past their expiry date");
    expect(expiredNote(5, 20)).toBe("5 of these are past their expiry date");
    expect(expiredNote(0, 20)).toBeNull();
  });
});

describe("talking to the database", () => {
  it("reads the status", async () => {
    rpc.mockResolvedValue({ data: status({ mode: "enforce" }), error: null });
    expect((await fetchGuardStatus(10))?.mode).toBe("enforce");
    expect(rpc).toHaveBeenCalledWith("admin_expiry_guard_status", { p_limit: 10 });
  });

  it.each([
    [{ code: "PGRST202", message: "Could not find the function public.admin_expiry_guard_status" }],
    [
      {
        code: "42883",
        message: "function public.admin_expiry_guard_status(integer) does not exist",
      },
    ],
  ])("returns nothing when the database update has not been applied: %j", async (error) => {
    rpc.mockResolvedValue({ data: null, error });
    expect(await fetchGuardStatus()).toBeNull();
  });

  it("still raises a real error", async () => {
    rpc.mockResolvedValue({
      data: null,
      error: { code: "42501", message: "Administrators only." },
    });
    await expect(fetchGuardStatus()).rejects.toThrow("Administrators only.");
  });

  it("switches the mode with the reason, and shows the database's refusal as it is", async () => {
    rpc.mockResolvedValue({ data: "enforce", error: null });
    expect(await setGuardMode("enforce", "Two weeks of observing were clean")).toBe("enforce");
    expect(rpc).toHaveBeenCalledWith("admin_set_expiry_guard_mode", {
      p_mode: "enforce",
      p_reason: "Two weeks of observing were clean",
    });
    rpc.mockResolvedValue({
      data: null,
      error: { message: "Give a reason of at least 5 characters." },
    });
    await expect(setGuardMode("off", "no")).rejects.toThrow(
      "Give a reason of at least 5 characters.",
    );
  });
});
