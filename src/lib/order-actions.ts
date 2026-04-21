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

async function getRequiredSession() {
  const {
    data: { session },
  } = await supabase.auth.getSession();

  if (!session) {
    throw new Error("You must be signed in to place orders.");
  }

  return session;
}

export async function createMarketplaceOrders(
  input: CreateMarketplaceOrdersInput,
): Promise<CreateMarketplaceOrdersResult> {
  const session = await getRequiredSession();

  const res = await fetch("/api/orders/create", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${session.access_token}`,
    },
    body: JSON.stringify(input),
  });

  const data = await res.json();

  if (!res.ok) {
    throw new Error(data.error || "Failed to place order");
  }

  return {
    orderCount: Number(data.orderCount) || 0,
  };
}
