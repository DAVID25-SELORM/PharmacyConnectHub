import type { VercelRequest } from "@vercel/node";

type ReceiptLineItem = {
  productName: string;
  quantity: number;
  unitPriceGhs: number;
};

type ReceiptParties = {
  pharmacy: {
    name: string;
    city: string | null;
    region: string | null;
  };
  wholesaler: {
    name: string;
    city: string | null;
    region: string | null;
  };
};

export type OrderReceiptPayload = {
  orderId: string;
  orderNumber: string;
  totalGhs: number;
  deliveredAt: string | null;
  paidAt: string | null;
  paymentMethod: "cod" | "paystack";
  items: ReceiptLineItem[];
  parties: ReceiptParties;
};

type SendOrderReceiptEmailInput = {
  toEmail: string;
  toName?: string | null;
  order: OrderReceiptPayload;
  request?: VercelRequest;
};

type SendOrderReceiptEmailResult =
  | { ok: true }
  | {
      ok: false;
      error: string;
    };

function firstHeaderValue(value: string | string[] | undefined) {
  if (Array.isArray(value)) {
    return value[0];
  }

  return value;
}

function normalizeSiteUrl(value: string | undefined) {
  const trimmed = value?.trim();
  if (!trimmed) {
    return "";
  }

  if (/^https?:\/\//i.test(trimmed)) {
    return trimmed.replace(/\/+$/, "");
  }

  return `https://${trimmed.replace(/\/+$/, "")}`;
}

function getSiteUrl(req?: VercelRequest) {
  const forwardedHost = firstHeaderValue(req?.headers["x-forwarded-host"]);
  const forwardedProto = firstHeaderValue(req?.headers["x-forwarded-proto"]) ?? "https";
  const fallbackHost = forwardedHost ?? firstHeaderValue(req?.headers.host);

  const siteUrlCandidates = [
    process.env.SITE_URL,
    process.env.VITE_SITE_URL,
    process.env.VERCEL_PROJECT_PRODUCTION_URL,
    process.env.VERCEL_URL,
    firstHeaderValue(req?.headers.origin),
    fallbackHost ? `${forwardedProto}://${fallbackHost}` : undefined,
  ];

  for (const candidate of siteUrlCandidates) {
    const normalized = normalizeSiteUrl(candidate);
    if (normalized) {
      return normalized;
    }
  }

  return "";
}

function formatGhs(value: number) {
  return new Intl.NumberFormat("en-GH", {
    style: "currency",
    currency: "GHS",
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(value);
}

function formatDateTime(value: string | null) {
  if (!value) {
    return "Pending";
  }

  return new Intl.DateTimeFormat("en-GB", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}

function escapeHtml(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function buildReceiptText(input: SendOrderReceiptEmailInput, loginUrl: string) {
  const itemLines = input.order.items
    .map(
      (item) =>
        `- ${item.productName}: ${item.quantity} x ${formatGhs(item.unitPriceGhs)} = ${formatGhs(
          item.quantity * item.unitPriceGhs,
        )}`,
    )
    .join("\n");

  return [
    `Hello ${input.toName?.trim() || input.order.parties.pharmacy.name},`,
    "",
    `Your receipt for order ${input.order.orderNumber} is ready.`,
    "",
    `Pharmacy: ${input.order.parties.pharmacy.name}`,
    `Wholesaler: ${input.order.parties.wholesaler.name}`,
    `Payment method: ${input.order.paymentMethod === "cod" ? "Cash on delivery" : "Paystack"}`,
    `Delivered at: ${formatDateTime(input.order.deliveredAt)}`,
    `Payment confirmed at: ${formatDateTime(input.order.paidAt)}`,
    "",
    "Items:",
    itemLines,
    "",
    `Total: ${formatGhs(input.order.totalGhs)}`,
    "",
    loginUrl ? `Open PharmaHub GH: ${loginUrl}` : "",
  ]
    .filter(Boolean)
    .join("\n");
}

function buildReceiptHtml(input: SendOrderReceiptEmailInput, loginUrl: string) {
  const itemsHtml = input.order.items
    .map((item) => {
      const lineTotal = item.quantity * item.unitPriceGhs;
      return `
        <tr>
          <td style="padding:12px 0;border-top:1px solid #e5e7eb;">${escapeHtml(item.productName)}</td>
          <td style="padding:12px 0;border-top:1px solid #e5e7eb;text-align:center;">${item.quantity}</td>
          <td style="padding:12px 0;border-top:1px solid #e5e7eb;text-align:right;">${escapeHtml(formatGhs(item.unitPriceGhs))}</td>
          <td style="padding:12px 0;border-top:1px solid #e5e7eb;text-align:right;">${escapeHtml(formatGhs(lineTotal))}</td>
        </tr>
      `;
    })
    .join("");

  const paymentMethodLabel = input.order.paymentMethod === "cod" ? "Cash on delivery" : "Paystack";

  return `
    <div style="background:#f5faf8;padding:32px 16px;font-family:Segoe UI,Arial,sans-serif;color:#102a43;">
      <div style="max-width:680px;margin:0 auto;background:#ffffff;border:1px solid #d9e7df;border-radius:20px;overflow:hidden;">
        <div style="padding:28px 32px;background:linear-gradient(135deg,#0f766e,#0b4f4b);color:#ffffff;">
          <div style="font-size:12px;letter-spacing:.08em;text-transform:uppercase;opacity:.85;">PharmaHub GH</div>
          <h1 style="margin:12px 0 0;font-size:28px;line-height:1.15;">Order receipt</h1>
          <p style="margin:10px 0 0;font-size:15px;line-height:1.6;opacity:.92;">
            This receipt was issued after the wholesaler confirmed payment for your delivered order.
          </p>
        </div>
        <div style="padding:28px 32px;">
          <p style="margin:0 0 20px;font-size:16px;">Hello ${escapeHtml(
            input.toName?.trim() || input.order.parties.pharmacy.name,
          )},</p>
          <div style="display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px;margin-bottom:24px;">
            <div style="padding:16px;border:1px solid #e5e7eb;border-radius:16px;background:#f8fafc;">
              <div style="font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:#486581;">Order</div>
              <div style="margin-top:8px;font-size:24px;font-weight:700;">${escapeHtml(
                input.order.orderNumber,
              )}</div>
              <div style="margin-top:8px;color:#486581;">Total: ${escapeHtml(
                formatGhs(input.order.totalGhs),
              )}</div>
            </div>
            <div style="padding:16px;border:1px solid #e5e7eb;border-radius:16px;background:#f8fafc;">
              <div style="font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:#486581;">Payment</div>
              <div style="margin-top:8px;font-size:16px;font-weight:700;">${escapeHtml(
                paymentMethodLabel,
              )}</div>
              <div style="margin-top:8px;color:#486581;">Confirmed: ${escapeHtml(
                formatDateTime(input.order.paidAt),
              )}</div>
            </div>
          </div>

          <div style="display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px;margin-bottom:24px;">
            <div style="padding:16px;border:1px solid #e5e7eb;border-radius:16px;">
              <div style="font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:#486581;">Pharmacy</div>
              <div style="margin-top:8px;font-size:18px;font-weight:700;">${escapeHtml(
                input.order.parties.pharmacy.name,
              )}</div>
              <div style="margin-top:6px;color:#486581;">${escapeHtml(
                [input.order.parties.pharmacy.city, input.order.parties.pharmacy.region]
                  .filter(Boolean)
                  .join(", ") || "Ghana",
              )}</div>
            </div>
            <div style="padding:16px;border:1px solid #e5e7eb;border-radius:16px;">
              <div style="font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:#486581;">Wholesaler</div>
              <div style="margin-top:8px;font-size:18px;font-weight:700;">${escapeHtml(
                input.order.parties.wholesaler.name,
              )}</div>
              <div style="margin-top:6px;color:#486581;">${escapeHtml(
                [input.order.parties.wholesaler.city, input.order.parties.wholesaler.region]
                  .filter(Boolean)
                  .join(", ") || "Ghana",
              )}</div>
            </div>
          </div>

          <div style="margin-bottom:24px;padding:16px;border-radius:16px;background:#f8fafc;border:1px solid #e5e7eb;">
            <div style="font-size:13px;color:#486581;">Delivered at</div>
            <div style="margin-top:6px;font-size:16px;font-weight:600;">${escapeHtml(
              formatDateTime(input.order.deliveredAt),
            )}</div>
          </div>

          <table role="presentation" style="width:100%;border-collapse:collapse;font-size:14px;">
            <thead>
              <tr style="text-align:left;color:#486581;">
                <th style="padding-bottom:10px;">Item</th>
                <th style="padding-bottom:10px;text-align:center;">Qty</th>
                <th style="padding-bottom:10px;text-align:right;">Unit price</th>
                <th style="padding-bottom:10px;text-align:right;">Line total</th>
              </tr>
            </thead>
            <tbody>${itemsHtml}</tbody>
          </table>

          <div style="margin-top:24px;padding-top:18px;border-top:1px solid #e5e7eb;display:flex;justify-content:space-between;gap:12px;align-items:center;">
            <span style="font-size:14px;color:#486581;">Receipt total</span>
            <strong style="font-size:22px;">${escapeHtml(formatGhs(input.order.totalGhs))}</strong>
          </div>

          ${
            loginUrl
              ? `<div style="margin-top:28px;">
                  <a href="${escapeHtml(
                    loginUrl,
                  )}" style="display:inline-block;padding:14px 20px;border-radius:999px;background:#0f766e;color:#ffffff;text-decoration:none;font-weight:600;">
                    Open PharmaHub GH
                  </a>
                </div>`
              : ""
          }
        </div>
      </div>
    </div>
  `;
}

export async function sendOrderReceiptEmail(
  input: SendOrderReceiptEmailInput,
): Promise<SendOrderReceiptEmailResult> {
  const apiKey = process.env.RESEND_API_KEY?.trim();
  const fromEmail =
    process.env.RECEIPT_FROM_EMAIL?.trim() || process.env.MAIL_FROM_EMAIL?.trim() || "";
  const fromName = process.env.RECEIPT_FROM_NAME?.trim() || "PharmaHub GH";
  const replyTo =
    process.env.RECEIPT_REPLY_TO_EMAIL?.trim() || process.env.MAIL_REPLY_TO_EMAIL?.trim();

  if (!apiKey || !fromEmail) {
    return {
      ok: false,
      error: "Receipt email is not configured yet. Add RESEND_API_KEY and RECEIPT_FROM_EMAIL.",
    };
  }

  const siteUrl = getSiteUrl(input.request);
  const loginUrl = siteUrl ? new URL("/login", `${siteUrl}/`).toString() : "";

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: `${fromName} <${fromEmail}>`,
      to: [input.toEmail],
      ...(replyTo ? { reply_to: replyTo } : {}),
      subject: `Receipt for order ${input.order.orderNumber}`,
      html: buildReceiptHtml(input, loginUrl),
      text: buildReceiptText(input, loginUrl),
    }),
  });

  if (!response.ok) {
    let message = "Failed to send receipt email.";

    try {
      const data = (await response.json()) as { message?: string; error?: string };
      message = data.error || data.message || message;
    } catch {
      // Ignore JSON parsing errors and use the fallback message above.
    }

    return { ok: false, error: message };
  }

  return { ok: true };
}
