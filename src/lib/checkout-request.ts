type Item = { productId: string; quantity: number };
// Persist before sending. Retain after ambiguous network failures and across reloads.
// Separate users and businesses never share a browser operation.
export function checkoutRequest(userId: string, businessId: string, items: Item[]) {
  const payload = JSON.stringify([...items].sort((a, b) => a.productId.localeCompare(b.productId)));
  return persistentOperation(`checkout.${userId}.${businessId}`, payload);
}

export function persistentOperation(scope: string, payload: string) {
  // Keep unresolved payloads independently, so editing a cart does not lose its earlier retry key.
  const key = `drugxone.${scope}.${encodeURIComponent(payload)}`;
  const saved = localStorage.getItem(key);
  if (saved) {
    const prior: unknown = JSON.parse(saved);
    if (
      typeof prior === "object" &&
      prior !== null &&
      "payload" in prior &&
      "id" in prior &&
      prior.payload === payload &&
      typeof prior.id === "string"
    ) {
      return { id: prior.id, key };
    }
  }
  const id = crypto.randomUUID();
  localStorage.setItem(key, JSON.stringify({ id, payload }));
  return { id, key };
}
