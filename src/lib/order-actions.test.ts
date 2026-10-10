import { beforeEach, describe, expect, it, vi } from "vitest";
import { createMarketplaceOrders } from "./order-actions";

vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    auth: {
      getSession: async () => ({
        data: { session: { user: { id: "caller" }, access_token: "test" } },
      }),
    },
  },
}));

const input = {
  pharmacyId: "pharmacy",
  items: [{ productId: "product", quantity: 1, category: "other" as const }],
};
const fetchMock = vi.fn();
beforeEach(() => {
  const store = new Map<string, string>();
  vi.stubGlobal("sessionStorage", {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => store.set(key, value),
    removeItem: (key: string) => store.delete(key),
  });
  fetchMock.mockReset();
  vi.stubGlobal("fetch", fetchMock);
});
const success = () =>
  new Response(JSON.stringify({ orderCount: 1 }), {
    headers: { "content-type": "application/json" },
  });
const requestId = (index: number) => JSON.parse(fetchMock.mock.calls[index][1].body).requestId;

describe("checkout retries", () => {
  it("reuses the request ID after a lost response, then rotates after success", async () => {
    fetchMock
      .mockRejectedValueOnce(new Error("connection lost"))
      .mockImplementation(async () => success());
    await expect(createMarketplaceOrders(input)).rejects.toThrow("connection lost");
    await expect(createMarketplaceOrders(input)).resolves.toEqual({
      orderCount: 1,
      awaitingPayment: [],
    });
    expect(requestId(1)).toBe(requestId(0));
    await createMarketplaceOrders(input);
    expect(requestId(2)).not.toBe(requestId(0));
  });
  it("passes on the orders that are waiting for online payment", async () => {
    const waiting = [{ orderId: "o1", orderNumber: "ORD-1", wholesalerId: "w1", amountGhs: 100 }];
    fetchMock.mockImplementation(
      async () =>
        new Response(JSON.stringify({ orderCount: 1, awaitingPayment: waiting }), {
          headers: { "content-type": "application/json" },
        }),
    );
    await expect(createMarketplaceOrders(input)).resolves.toEqual({
      orderCount: 1,
      awaitingPayment: waiting,
    });
  });
  it("uses a new request ID if the cart changes", async () => {
    fetchMock
      .mockRejectedValueOnce(new Error("connection lost"))
      .mockImplementation(async () => success());
    await expect(createMarketplaceOrders(input)).rejects.toThrow();
    await createMarketplaceOrders({ ...input, items: [{ ...input.items[0], quantity: 2 }] });
    expect(requestId(1)).not.toBe(requestId(0));
  });
  it("concurrent submissions share a request ID", async () => {
    fetchMock.mockImplementation(async () => success());
    await Promise.all([createMarketplaceOrders(input), createMarketplaceOrders(input)]);
    expect(requestId(1)).toBe(requestId(0));
  });
});
