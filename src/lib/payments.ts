// Online payment of an order (Pay now), from the browser's side. The browser never decides that anything is paid: it asks the
// server to start a payment, sends the customer to the provider's page, and on return only asks the server to check with the
// provider. "Paid" is whatever the database says after that check.
import { useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { postWithSession } from "@/lib/order-actions";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

export type OnlinePaymentsStatus = { enabled: boolean; mode: "test" | "live" };

const OFF: OnlinePaymentsStatus = { enabled: false, mode: "test" };

/** Whether the platform currently offers online payment, and in which mode. Anything unclear means "no". */
export async function fetchOnlinePaymentsStatus(): Promise<OnlinePaymentsStatus> {
  const { data, error } = await db.rpc("online_payments_status");
  if (error || !data || typeof data !== "object") return OFF;
  return {
    enabled: (data as { enabled?: unknown }).enabled === true,
    mode: (data as { mode?: unknown }).mode === "live" ? "live" : "test",
  };
}

/** Loaded once per screen; "off" until the answer arrives, so Pay now is never offered by mistake. */
export function useOnlinePayments(): OnlinePaymentsStatus {
  const [status, setStatus] = useState<OnlinePaymentsStatus>(OFF);
  useEffect(() => {
    let cancelled = false;
    void fetchOnlinePaymentsStatus().then((next) => {
      if (!cancelled) setStatus(next);
    });
    return () => {
      cancelled = true;
    };
  }, []);
  return status;
}

export type StartedPayment = { authorizationUrl: string; reference: string; resumed: boolean };

/** Starts (or resumes) the payment of an order and returns the provider's checkout address. */
export function startOrderPayment(orderId: string): Promise<StartedPayment> {
  return postWithSession<StartedPayment>("/api/payments/initialize", { orderId });
}

export type VerifyStatus = "paid" | "pending" | "failed" | "flagged" | "not_paid";

/** Asks the server to check the order's recent payment attempts with the provider. */
export async function verifyOrderPayment(orderId: string): Promise<VerifyStatus> {
  const data = await postWithSession<{ status?: string }>("/api/payments/verify", { orderId });
  const status = data.status;
  return status === "paid" || status === "pending" || status === "failed" || status === "flagged"
    ? status
    : "not_paid";
}

export type OrderPaymentSummary =
  | { online: false; payment_status: string }
  | {
      online: true;
      side: "pharmacy" | "wholesaler" | "admin";
      order_number: string;
      order_status: string;
      payment_status: "unpaid" | "paid" | "refunded" | "failed";
      amount_ghs: number;
      paid_at: string | null;
      awaiting_payment: boolean;
      last_attempt: {
        status: string;
        at: string;
        reason: string | null;
        channel: string | null;
      } | null;
      refund_required: boolean;
      paid_ghs?: number;
      refunded_ghs?: number;
      refunds?: {
        amount_ghs: number;
        status: string;
        reason: string;
        created_at: string;
        completed_at: string | null;
      }[];
    };

/** What either side of an order may know about its online payment. Null when it cannot be read. */
export async function fetchOrderPaymentSummary(
  orderId: string,
): Promise<OrderPaymentSummary | null> {
  const { data, error } = await db.rpc("order_payment_summary", { p_order_id: orderId });
  if (error || !data) return null;
  return data as OrderPaymentSummary;
}

/** Sends the customer to the provider's page to pay. Returns false (with the reason) when the payment could not be started. */
export async function payForOrder(
  orderId: string,
): Promise<{ ok: true } | { ok: false; error: string }> {
  try {
    const started = await startOrderPayment(orderId);
    window.location.assign(started.authorizationUrl);
    return { ok: true };
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : "We could not start the payment.",
    };
  }
}

/** Whether an order is an online order still waiting for its payment. */
export function isAwaitingOnlinePayment(order: {
  payment_method?: string | null;
  payment_status?: string | null;
  status?: string | null;
}): boolean {
  return (
    order.payment_method === "paystack" &&
    order.payment_status === "unpaid" &&
    order.status !== "cancelled"
  );
}

/** What the return page shows for a verification answer. Never claims "paid" unless the server said so. */
export function returnMessage(status: VerifyStatus | "checking" | "unreachable"): {
  tone: "good" | "wait" | "bad";
  title: string;
  body: string;
} {
  switch (status) {
    case "paid":
      return {
        tone: "good",
        title: "Payment received",
        body: "Thank you. Your payment has been confirmed and the supplier has been told.",
      };
    case "pending":
      return {
        tone: "wait",
        title: "Waiting for your payment",
        body: "Your bank or mobile money provider has not confirmed the payment yet. This page keeps checking; you do not need to pay again.",
      };
    case "failed":
      return {
        tone: "bad",
        title: "The payment did not go through",
        body: "You have not been charged for this order. You can try again from your orders.",
      };
    case "flagged":
      return {
        tone: "bad",
        title: "We need to look at this payment",
        body: "A payment was received that we could not apply to this order automatically. Please do not pay again; our team will contact you.",
      };
    case "unreachable":
      return {
        tone: "wait",
        title: "We could not check just now",
        body: "We could not reach the payment provider. This page will try again shortly. If you were charged, your order will be updated once it is confirmed.",
      };
    case "checking":
      return {
        tone: "wait",
        title: "Checking your payment",
        body: "Please wait while we confirm your payment with the provider.",
      };
    default:
      return {
        tone: "wait",
        title: "We have not received a payment yet",
        body: "If you have just paid, wait a moment; this page keeps checking. Otherwise you can pay again from your orders.",
      };
  }
}
