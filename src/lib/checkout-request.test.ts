import { beforeEach, expect, it, vi } from "vitest";
import { checkoutRequest } from "./checkout-request";
const values = new Map<string, string>();
beforeEach(() => {
  values.clear();
  vi.stubGlobal("localStorage", {
    getItem: (k: string) => values.get(k) ?? null,
    setItem: (k: string, v: string) => values.set(k, v),
    removeItem: (k: string) => values.delete(k),
  });
});
it("retains a logical key across retries and cart ordering", () => {
  const items = [
    { productId: "a", quantity: 2 },
    { productId: "b", quantity: 1 },
  ];
  expect(checkoutRequest("u", "b", items).id).toBe(
    checkoutRequest("u", "b", [...items].reverse()).id,
  );
});
it("isolates user/business scopes and changed quantities", () => {
  const items = [{ productId: "a", quantity: 2 }];
  const a = checkoutRequest("u", "b", items).id;
  expect(checkoutRequest("other", "b", items).id).not.toBe(a);
  expect(checkoutRequest("u", "other", items).id).not.toBe(a);
  expect(checkoutRequest("u", "b", [{ productId: "a", quantity: 3 }]).id).not.toBe(a);
});
it("successful completion permits a new intentional checkout", () => {
  const items = [{ productId: "a", quantity: 2 }];
  const a = checkoutRequest("u", "b", items);
  localStorage.removeItem(a.key);
  expect(checkoutRequest("u", "b", items).id).not.toBe(a.id);
});
