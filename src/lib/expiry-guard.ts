// The expiry sales guard, from the screens' side. The database decides what can be sold (stock minus units in expired batches) and keeps the record;
// nothing here works that out. This file reads the administrator's status, switches the mode through an audited function, and turns the numbers into plain advice.
import { supabase } from "@/integrations/supabase/client";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

export type GuardMode = "off" | "observe" | "enforce";
export type GuardEntryPoint = "checkout" | "rfq_award" | "backorder_shipment";

export type GuardEvent = {
  created_at: string;
  entry_point: GuardEntryPoint;
  product_name: string;
  wholesaler_name: string | null;
  quantity: number;
  stock: number;
  expired_units: number;
  sellable: number;
};

export type GuardStatus = {
  mode: GuardMode;
  changed_at: string | null;
  products_with_expired_units: number;
  expired_units: number;
  orderable_products_with_expired_units: number;
  products_where_batches_exceed_stock: number;
  would_have_blocked_7_days: number;
  would_have_blocked_30_days: number;
  events: GuardEvent[];
};

/** The status, or null when the database update that adds the guard has not been applied yet. */
export async function fetchGuardStatus(limit = 20): Promise<GuardStatus | null> {
  const { data, error } = await db.rpc("admin_expiry_guard_status", { p_limit: limit });
  if (error) {
    if (
      /PGRST202|42883|could not find the function|does not exist/i.test(
        `${error.code ?? ""} ${error.message ?? ""}`,
      )
    )
      return null;
    throw new Error(error.message);
  }
  return data as GuardStatus;
}

export async function setGuardMode(mode: GuardMode, reason: string): Promise<GuardMode> {
  const { data, error } = await db.rpc("admin_set_expiry_guard_mode", {
    p_mode: mode,
    p_reason: reason,
  });
  if (error) throw new Error(error.message);
  return data as GuardMode;
}

export const MODE_LABELS: Record<GuardMode, string> = {
  off: "Off",
  observe: "Observing",
  enforce: "Enforced",
};

export const MODE_DESCRIPTIONS: Record<GuardMode, string> = {
  off: "Nothing is checked. Expired units can be sold.",
  observe:
    "Nothing is blocked. Every sale that would have been refused is recorded below, so you can see the effect before it is real.",
  enforce:
    "Sales that need expired units are refused with a message, and pharmacies are shown only the number that can be sold.",
};

export const ENTRY_LABELS: Record<GuardEntryPoint, string> = {
  checkout: "Checkout",
  rfq_award: "Request for quotation award",
  backorder_shipment: "Back-order shipment",
};

export type GuardAdvice = {
  tone: "good" | "attention" | "neutral";
  headline: string;
  points: string[];
};

/**
 * What to do next, in words. Observing first is the safe route: look at what would have been refused, put right any stock figures that do not match the batches, and only then enforce.
 */
export function guardAdvice(status: GuardStatus): GuardAdvice {
  const points: string[] = [];
  const mismatch = status.products_where_batches_exceed_stock;
  const orderable = status.orderable_products_with_expired_units;
  if (status.mode === "off")
    return {
      tone: "attention",
      headline: "The guard is off, so expired units can be sold.",
      points: ["Switch to observing to record what it would refuse, without blocking anything."],
    };
  if (mismatch > 0)
    points.push(
      `${mismatch} product${mismatch === 1 ? " has" : "s have"} more units in batches than in stock. Ask the wholesaler to correct the stock or the batches first: the guard cannot tell which figure is right.`,
    );
  if (orderable > 0)
    points.push(
      `${orderable} product${orderable === 1 ? " is" : "s are"} still orderable while holding expired units.`,
    );
  if (status.mode === "observe") {
    if (status.would_have_blocked_7_days > 0)
      points.push(
        `In the last 7 days ${status.would_have_blocked_7_days} sale${status.would_have_blocked_7_days === 1 ? "" : "s"} would have been refused. Check the list below: each one is a real order that needed expired units.`,
      );
    if (points.length === 0)
      return {
        tone: "good",
        headline: "Nothing would have been refused. Enforcing looks safe.",
        points: ["Keep observing for a while if you want more evidence, then switch to enforced."],
      };
    return {
      tone: "attention",
      headline: "Observing. Review these before enforcing.",
      points,
    };
  }
  return {
    tone: points.length === 0 ? "good" : "attention",
    headline: "Expired units cannot be sold.",
    points: points.length ? points : ["No product is holding expired units that could be ordered."],
  };
}

/** A wholesaler's product line: how its stock splits when some of it is past its date. */
export function expiredNote(stock: number, expired: number | null | undefined): string | null {
  if (!expired || expired <= 0) return null;
  const e = Math.min(expired, Math.max(stock, 0));
  if (e <= 0) return null;
  return `${e} of these ${e === 1 ? "is" : "are"} past their expiry date`;
}
