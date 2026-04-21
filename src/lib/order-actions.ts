import { supabase } from "@/integrations/supabase/client";

type CreateMarketplaceOrdersInput = {
  pharmacyId: string;
  items: Array<{
    productId: string;
    quantity: number;
  }>;
};

type CreateMarketplaceOrdersResult = {
  orderCount: number;
};

type OrderReceiptActionInput = {
  orderId: string;
};

type ConfirmOrderPaymentResult = {
  receiptSent: boolean;
  warning?: string;
};

type SendOrderReceiptResult = {
  sent: boolean;
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

  const data = await res.json();

  if (!res.ok) {
    throw new Error(data.error || "Request failed");
  }

  return data as T;
}

export async function createMarketplaceOrders(
  input: CreateMarketplaceOrdersInput,
): Promise<CreateMarketplaceOrdersResult> {
  const data = await postWithSession<CreateMarketplaceOrdersResult>("/api/orders/create", input);

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
  const data = await postWithSession<{ sent?: boolean }>("/api/orders/send-receipt", input);

  return { sent: Boolean(data.sent) };
}
