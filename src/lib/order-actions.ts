import { supabase } from "@/integrations/supabase/client";
import type { ItemPurchaseCategory } from "@/lib/purchase-category";

type CreateMarketplaceOrdersInput = {
  pharmacyId: string;
  items: Array<{
    productId: string;
    quantity: number;
    /** Omitted = unclassified (matches every historical order). */
    category?: ItemPurchaseCategory;
  }>;
  /** Wholesaler ids for which the pharmacy wants to buy on its approved credit line. */
  creditWholesalerIds?: string[];
  /** Payment method per wholesaler id (cod, credit, bank_transfer, momo, cheque, other). Omitted =
   * cash on delivery, or credit for the wholesalers in creditWholesalerIds. */
  settlementMethods?: Record<string, string>;
};

type CreateMarketplaceOrdersResult = {
  orderCount: number;
};

type OrderReceiptActionInput = {
  orderId: string;
  /** One back-order shipment of a cash order (omitted for the order itself, or for the main delivery). */
  shipmentId?: string | null;
};

type ConfirmOrderPaymentResult = {
  receiptSent: boolean;
  warning?: string;
};

type SendOrderReceiptResult = {
  sent: boolean;
  warning?: string;
};

async function getRequiredSession() {
  const {
    data: { session },
  } = await supabase.auth.getSession();

  if (!session) {
    throw new Error("You must be signed in to place orders.");
  }

  return session;
}

async function postWithSession<T>(path: string, input: unknown): Promise<T> {
  const session = await getRequiredSession();

  const res = await fetch(path, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${session.access_token}`,
    },
    body: JSON.stringify(input),
  });

  const contentType = res.headers.get("content-type") ?? "";
  const data = contentType.includes("application/json")
    ? await res.json()
    : { error: await res.text() };

  if (!res.ok) {
    throw new Error(data.error || "Request failed");
  }

  return data as T;
}

export async function createMarketplaceOrders(
  input: CreateMarketplaceOrdersInput,
): Promise<CreateMarketplaceOrdersResult> {
  const session = await getRequiredSession();
  const key = `checkout-request:${session.user.id}:${input.pharmacyId}`;
  const payload = JSON.stringify(input);
  // Keep the ID after a lost response and across reloads. A successful checkout clears it,
  // allowing a deliberate second purchase of the same cart.
  let pending: { payload: string; requestId: string } | undefined;
  try {
    pending = JSON.parse(sessionStorage.getItem(key) ?? "null") ?? undefined;
  } catch {
    /* replace malformed state */
  }
  if (!pending || pending.payload !== payload || !pending.requestId) {
    pending = { payload, requestId: crypto.randomUUID() };
    sessionStorage.setItem(key, JSON.stringify(pending));
  }
  const data = await postWithSession<CreateMarketplaceOrdersResult>("/api/orders/create", {
    ...input,
    requestId: pending.requestId,
  });
  // A slower response must not clear a newer cart's pending request.
  if (sessionStorage.getItem(key) === JSON.stringify(pending)) sessionStorage.removeItem(key);

  return { orderCount: Number(data.orderCount) || 0 };
}

export async function confirmOrderPayment(
  input: OrderReceiptActionInput,
): Promise<ConfirmOrderPaymentResult> {
  const data = await postWithSession<{
    receiptSent?: boolean;
    warning?: string;
  }>("/api/orders/confirm-payment", input);

  return {
    receiptSent: Boolean(data.receiptSent),
    warning: typeof data.warning === "string" ? data.warning : undefined,
  };
}

export async function sendOrderReceipt(
  input: OrderReceiptActionInput,
): Promise<SendOrderReceiptResult> {
  const data = await postWithSession<{ sent?: boolean; warning?: string }>(
    "/api/orders/send-receipt",
    input,
  );

  return {
    sent: Boolean(data.sent),
    warning: typeof data.warning === "string" ? data.warning : undefined,
  };
}
