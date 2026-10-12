import { describe, expect, it } from "vitest";
import { stateDetail, stateMessage } from "./billing";
import {
  ACTIVATION_PHRASE,
  ENFORCEMENT_LABELS,
  NOTICE_EVENT_LABELS,
  NOTICE_LABELS,
  blockers,
  canActivate,
  rolloutStage,
  shadowSummary,
  type Readiness,
} from "./billing-rollout";

const now = new Date("2026-10-12T10:00:00Z");

describe("the activation switch", () => {
  const ok = { ready: true, phrase: ACTIVATION_PHRASE, reason: "Approved at the launch meeting" };
  it("needs readiness, the exact phrase and a reason", () => {
    expect(canActivate(ok)).toBe(true);
    expect(canActivate({ ...ok, ready: false })).toBe(false);
    expect(canActivate({ ...ok, phrase: "activate billing" })).toBe(false);
    expect(canActivate({ ...ok, phrase: "" })).toBe(false);
    expect(canActivate({ ...ok, reason: "ok" })).toBe(false);
  });
  it("tolerates stray spaces around the phrase but not inside it", () => {
    expect(canActivate({ ...ok, phrase: `  ${ACTIVATION_PHRASE}  ` })).toBe(true);
    expect(canActivate({ ...ok, phrase: "ACTIVATE  BILLING" })).toBe(false);
  });
  it("lists only the blocking items that fail", () => {
    const r: Pick<Readiness, "checks"> = {
      checks: [
        { key: "a", label: "Books agree", blocking: true, ok: true, detail: "" },
        { key: "b", label: "The scheduled run is running", blocking: true, ok: false, detail: "" },
        { key: "c", label: "14 days of shadow", blocking: false, ok: false, detail: "" },
      ],
    };
    expect(blockers(r)).toEqual(["The scheduled run is running"]);
  });
});

describe("shadow history in words", () => {
  it("says when there is none", () => {
    expect(
      shadowSummary({
        since: null,
        days: 0,
        businesses: 0,
        orders_assessed: 0,
        estimated_revenue: 0,
      }),
    ).toBe("No shadow billing data yet.");
  });
  it("counts days, orders and businesses with the right singular and plural", () => {
    expect(
      shadowSummary({
        since: "2026-10-11T00:00:00Z",
        days: 1,
        businesses: 1,
        orders_assessed: 1,
        estimated_revenue: 5,
      }),
    ).toBe("1 day of shadow data: 1 order across 1 business.");
    expect(
      shadowSummary({
        since: "2026-09-01T00:00:00Z",
        days: 41,
        businesses: 7,
        orders_assessed: 130,
        estimated_revenue: 900,
      }),
    ).toBe("41 days of shadow data: 130 orders across 7 businesses.");
  });
});

describe("where a business stands in the rollout", () => {
  const base = { effective_mode: "shadow", billing_mode: "shadow", status: "active" };
  it("is held back until it is put live", () => {
    expect(rolloutStage({ ...base, activated_at: null }, now)).toEqual({
      label: "Held back (shadow)",
      tone: "held",
    });
  });
  it("is live from its go-live moment, and 'going live soon' before it", () => {
    expect(
      rolloutStage(
        {
          ...base,
          effective_mode: "active",
          billing_mode: null,
          activated_at: "2026-10-01T00:00:00Z",
        },
        now,
      ).tone,
    ).toBe("live");
    expect(
      rolloutStage(
        {
          ...base,
          effective_mode: "active",
          billing_mode: null,
          activated_at: "2026-10-14T00:00:00Z",
        },
        now,
      ),
    ).toEqual({ label: "Going live soon", tone: "scheduled" });
  });
  it("is off when its billing is switched off, and ended when cancelled", () => {
    expect(
      rolloutStage(
        { ...base, effective_mode: "disabled", billing_mode: "disabled", activated_at: null },
        now,
      ).tone,
    ).toBe("off");
    expect(
      rolloutStage({ ...base, status: "cancelled", activated_at: "2026-10-01T00:00:00Z" }, now)
        .tone,
    ).toBe("ended");
  });
});

describe("what a business is told when it has not paid", () => {
  it("gives the date to pay by while the grace period runs", () => {
    expect(stateDetail("past_due", { grace_until: "2026-10-20T00:00:00Z" }, "none", now)).toBe(
      "Please pay by 20 Oct 2026 to avoid your account being suspended.",
    );
    expect(
      stateDetail("grace_period", { grace_until: "2026-10-20T00:00:00Z" }, "none", now),
    ).toMatch(/20 Oct 2026/);
  });
  it("does not quote a date that has passed", () => {
    expect(stateDetail("past_due", { grace_until: "2026-10-01T00:00:00Z" }, "none", now)).toBe(
      "Please pay as soon as you can.",
    );
  });
  it("says what is paused only when the restriction is on", () => {
    expect(stateDetail("suspended", {}, "new_orders", now)).toMatch(/new orders cannot be placed/);
    expect(stateDetail("suspended", {}, "none", now)).toBeNull();
  });
  it("says when billing will start for a business that is waiting for its go-live date", () => {
    expect(stateDetail("not_started", { activated_at: "2026-10-14T00:00:00Z" }, "none", now)).toBe(
      "Billing starts on 14 Oct 2026.",
    );
    expect(stateDetail("not_started", { activated_at: null }, "none", now)).toBeNull();
    expect(stateDetail("active", {}, "none", now)).toBeNull();
  });
  it("uses plain words for a suspended account", () => {
    expect(stateMessage("suspended")).toMatch(/overdue/);
    expect(stateMessage("suspended")).not.toMatch(/ledger|assessment|rpc|shadow/i);
  });
});

describe("labels", () => {
  it("covers every policy and every notice setting", () => {
    expect(Object.keys(ENFORCEMENT_LABELS).sort()).toEqual(["block_new_orders", "none"]);
    expect(NOTICE_LABELS).toHaveLength(8);
    for (const n of NOTICE_LABELS) expect(NOTICE_EVENT_LABELS[n.key] ?? n.label).toBeTruthy();
    expect(NOTICE_EVENT_LABELS.admin).toBe("Administrator alert");
  });
});
