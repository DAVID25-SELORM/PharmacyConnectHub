import type { DocumentBusiness } from "../src/lib/document-branding";
import type { VercelRequest } from "@vercel/node";
import { createClient } from "@supabase/supabase-js";
import { receiptDocumentModel } from "./_receipt-document.js";
import { businessDocumentHtml } from "../src/lib/business-document-html";

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
  issuer?: DocumentBusiness & { legacy_branding?: boolean };
  logoUrl?: string;
  orderId: string;
  collectionId?: string;
  orderNumber: string;
  totalGhs: number;
  /** Delivery fee included in totalGhs, when the wholesaler charged one. */
  deliveryFeeGhs?: number;
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
    input.order.deliveryFeeGhs ? `Delivery fee: ${formatGhs(input.order.deliveryFeeGhs)}` : "",
    `Total: ${formatGhs(input.order.totalGhs)}`,
    "",
    loginUrl ? `Open Drugxone: ${loginUrl}` : "",
  ]
    .filter(Boolean)
    .join("\n");
}

export function buildReceiptHtml(input: SendOrderReceiptEmailInput, _loginUrl: string) {
  return businessDocumentHtml(receiptDocumentModel(input.order), input.order.logoUrl);
}

export async function sendOrderReceiptEmail(
  input: SendOrderReceiptEmailInput,
): Promise<SendOrderReceiptEmailResult> {
  const apiKey = process.env.RESEND_API_KEY?.trim();
  const fromEmail =
    process.env.RECEIPT_FROM_EMAIL?.trim() || process.env.MAIL_FROM_EMAIL?.trim() || "";
  const fromName = process.env.RECEIPT_FROM_NAME?.trim() || "Drugxone";
  const replyTo =
    process.env.RECEIPT_REPLY_TO_EMAIL?.trim() || process.env.MAIL_REPLY_TO_EMAIL?.trim();

  if (!apiKey || !fromEmail) {
    return {
      ok: false,
      error: "Receipt email is not configured yet. Add RESEND_API_KEY and RECEIPT_FROM_EMAIL.",
    };
  }

  const siteUrl = getSiteUrl(input.request);
  if (process.env.SUPABASE_URL && process.env.SUPABASE_SERVICE_ROLE_KEY) {
    const db = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false },
    });
    const { data: issuer, error } = await db.rpc("prepare_receipt_document_identity", {
      p_order_id: input.order.orderId,
      p_collection_id: input.order.collectionId ?? null,
    });
    if (error || !issuer)
      return {
        ok: false,
        error: "Receipt identity could not be prepared. Retry sending the receipt.",
      };
    input = {
      ...input,
      order: {
        ...input.order,
        issuer,
        logoUrl: issuer.branding?.logo_path
          ? db.storage.from("business-document-logos").getPublicUrl(issuer.branding.logo_path).data
              .publicUrl
          : undefined,
      },
    };
  }
  const loginUrl = siteUrl ? new URL("/login", `${siteUrl}/`).toString() : "";

  let response: Response;

  try {
    const { buildBusinessDocumentPdf } = await import("../src/lib/business-document-pdf");
    let logo: string | undefined;
    // The snapshot storage URL is constructed above, never taken from a request field.
    if (
      input.order.logoUrl &&
      process.env.SUPABASE_URL &&
      new URL(input.order.logoUrl).origin === new URL(process.env.SUPABASE_URL).origin
    ) {
      const logoResponse = await fetch(input.order.logoUrl, {
        signal: AbortSignal.timeout(10000),
        redirect: "error",
      });
      if (!logoResponse.ok) throw new Error("Receipt logo could not be loaded.");
      const { default: sharp } = await import("sharp");
      const png = await sharp(Buffer.from(await logoResponse.arrayBuffer()), {
        limitInputPixels: 16000000,
      })
        .resize({ width: 1200, height: 1200, fit: "inside", withoutEnlargement: true })
        .png()
        .toBuffer();
      logo = `data:image/png;base64,${png.toString("base64")}`;
    }
    const pdf = buildBusinessDocumentPdf(receiptDocumentModel(input.order), logo);
    response = await fetch("https://api.resend.com/emails", {
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
        attachments: [
          {
            filename: `receipt-${input.order.orderNumber.replace(/[^a-z0-9-]/gi, "-")}.pdf`,
            content: Buffer.from(pdf.output("arraybuffer")).toString("base64"),
          },
        ],
      }),
    });
  } catch (error) {
    return {
      ok: false,
      error:
        error instanceof Error
          ? `Failed to prepare or send the receipt: ${error.message}`
          : "Failed to prepare or send the receipt.",
    };
  }

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
