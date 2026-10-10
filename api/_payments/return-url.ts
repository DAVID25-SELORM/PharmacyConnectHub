// Where Paystack sends the customer back to after paying. Built from the site's own configured address, never from request headers
// (a header is chosen by whoever sends the request). The page it leads to only ever asks the server to verify; it never marks
// anything paid by itself.

function normalise(candidate: string | undefined): string | null {
  const trimmed = candidate?.trim();
  if (!trimmed) return null;
  const withProtocol = /^https?:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
  try {
    const url = new URL(withProtocol);
    return `${url.protocol}//${url.host}`;
  } catch {
    return null;
  }
}

export function paymentReturnUrl(
  orderId: string,
  env: Record<string, string | undefined> = process.env,
): string | null {
  const base =
    normalise(env.SITE_URL) ??
    normalise(env.VITE_SITE_URL) ??
    normalise(env.VERCEL_PROJECT_PRODUCTION_URL) ??
    normalise(env.VERCEL_URL);
  if (!base) return null;
  return `${base}/pay/return?order=${encodeURIComponent(orderId)}`;
}
