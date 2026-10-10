// The Paystack adapter: the only place that knows Paystack's endpoints, field names, units and signature scheme.
import { createHash, createHmac, randomUUID, timingSafeEqual } from "node:crypto";
import {
  ProviderError,
  type InitializeInput,
  type InitializedPayment,
  type ListedTransaction,
  type PaymentProvider,
  type PaymentStatus,
  type ProviderMode,
  type RefundInput,
  type RefundResult,
  type VerifiedPayment,
  type WebhookParseResult,
} from "./types.js";

const BASE_URL = "https://api.paystack.co";

/** Cedis to pesewas, exactly. Accepts a string or number with at most two decimals and refuses anything else (never rounds money). */
export function ghsToPesewas(amount: number | string): number {
  const text = typeof amount === "number" ? String(amount) : amount.trim();
  const match = /^(\d{1,10})(?:\.(\d{1,2}))?$/.exec(text);
  if (!match) throw new Error(`Not a valid amount in cedis: ${text}`);
  const cedis = Number(match[1]);
  const pesewas = Number((match[2] ?? "").padEnd(2, "0") || "0");
  return cedis * 100 + pesewas;
}

export function pesewasToGhs(pesewas: number): string {
  if (!Number.isInteger(pesewas) || pesewas < 0) throw new Error("Pesewas must be a whole number");
  return `${Math.floor(pesewas / 100)}.${String(pesewas % 100).padStart(2, "0")}`;
}

/** The mode a secret key belongs to, from its prefix. Anything else is refused, so a mistyped key can never be used. */
export function modeFromSecretKey(key: string): ProviderMode {
  if (key.startsWith("sk_test_")) return "test";
  if (key.startsWith("sk_live_")) return "live";
  throw new Error("The Paystack secret key is not a recognised test or live key.");
}

/** A reference that is unique, URL-safe (Paystack allows letters, digits, "-", "." and "="), and says which mode it was made in. */
export function newPaymentReference(mode: ProviderMode): string {
  return `dx-${mode}-${randomUUID()}`;
}

/** HMAC-SHA512 of the raw body keyed with the secret key, compared in constant time. */
export function verifyWebhookSignature(
  rawBody: Buffer | string,
  signature: string | undefined,
  secretKey: string,
): boolean {
  if (!signature || !secretKey) return false;
  const expected = createHmac("sha512", secretKey).update(rawBody).digest();
  let given: Buffer;
  try {
    given = Buffer.from(signature.trim(), "hex");
  } catch {
    return false;
  }
  // Buffer.from(hex) silently stops at the first bad character, so require the round trip to match.
  if (given.length !== expected.length || given.toString("hex") !== signature.trim().toLowerCase())
    return false;
  return timingSafeEqual(given, expected);
}

export function mapPaystackStatus(status: unknown): PaymentStatus {
  switch (status) {
    case "success":
      return "success";
    case "failed":
      return "failed";
    case "abandoned":
      return "abandoned";
    case "pending":
    case "ongoing":
    case "processing":
    case "queued":
      return "pending";
    default:
      return "unknown";
  }
}

const asNumber = (value: unknown): number | null =>
  typeof value === "number" && Number.isFinite(value) ? value : null;
const asString = (value: unknown): string | null =>
  typeof value === "string" && value ? value : null;
const asDomain = (value: unknown): ProviderMode | null =>
  value === "test" || value === "live" ? value : null;

type Json = Record<string, unknown>;

export type PaystackOptions = {
  secretKey: string;
  fetchImpl?: typeof fetch;
  baseUrl?: string;
  timeoutMs?: number;
};

export class PaystackProvider implements PaymentProvider {
  readonly name = "paystack";
  readonly mode: ProviderMode;
  private readonly secretKey: string;
  private readonly fetchImpl: typeof fetch;
  private readonly baseUrl: string;
  private readonly timeoutMs: number;

  constructor(options: PaystackOptions) {
    this.secretKey = options.secretKey;
    this.mode = modeFromSecretKey(options.secretKey);
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.baseUrl = options.baseUrl ?? BASE_URL;
    this.timeoutMs = options.timeoutMs ?? 15000;
  }

  private async call(method: "GET" | "POST", path: string, body?: Json): Promise<Json> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    let response: Response;
    try {
      response = await this.fetchImpl(`${this.baseUrl}${path}`, {
        method,
        headers: {
          Authorization: `Bearer ${this.secretKey}`,
          ...(body ? { "Content-Type": "application/json" } : {}),
        },
        body: body ? JSON.stringify(body) : undefined,
        signal: controller.signal,
      });
    } catch (error) {
      throw new ProviderError(
        error instanceof Error && error.name === "AbortError"
          ? "Paystack did not answer in time."
          : "Paystack could not be reached.",
      );
    } finally {
      clearTimeout(timer);
    }
    let json: Json | null = null;
    try {
      json = (await response.json()) as Json;
    } catch {
      json = null;
    }
    if (!response.ok || !json || json.status !== true) {
      const message =
        typeof json?.message === "string" ? json.message : `Paystack returned ${response.status}.`;
      throw new ProviderError(message, {
        status: response.status,
        notFound: response.status === 404,
      });
    }
    return json;
  }

  async initialize(input: InitializeInput): Promise<InitializedPayment> {
    if (!Number.isInteger(input.amountMinor) || input.amountMinor <= 0)
      throw new Error("The amount must be a whole number of pesewas.");
    const json = await this.call("POST", "/transaction/initialize", {
      email: input.email,
      amount: input.amountMinor,
      currency: "GHS",
      reference: input.reference,
      callback_url: input.callbackUrl,
      ...(input.metadata ? { metadata: input.metadata } : {}),
      ...(input.channels ? { channels: input.channels } : {}),
    });
    const data = (json.data ?? {}) as Json;
    const authorizationUrl = asString(data.authorization_url);
    const accessCode = asString(data.access_code);
    if (!authorizationUrl || !accessCode)
      throw new ProviderError("Paystack did not return a payment page.");
    return { reference: asString(data.reference) ?? input.reference, authorizationUrl, accessCode };
  }

  async verify(reference: string): Promise<VerifiedPayment> {
    const json = await this.call("GET", `/transaction/verify/${encodeURIComponent(reference)}`);
    const data = (json.data ?? {}) as Json;
    const status = mapPaystackStatus(data.status);
    return {
      reference: asString(data.reference) ?? reference,
      status,
      amountMinor: asNumber(data.amount) ?? 0,
      currency: asString(data.currency) ?? "",
      transactionId: data.id === undefined || data.id === null ? null : String(data.id),
      channel: asString(data.channel),
      feeMinor: asNumber(data.fees),
      failureReason:
        status === "failed" || status === "abandoned" ? asString(data.gateway_response) : null,
      paidAt: asString(data.paid_at),
      domain: asDomain(data.domain),
    };
  }

  async refund(input: RefundInput): Promise<RefundResult> {
    if (!Number.isInteger(input.amountMinor) || input.amountMinor <= 0)
      throw new Error("The amount must be a whole number of pesewas.");
    const json = await this.call("POST", "/refund", {
      transaction: input.transactionReference,
      amount: input.amountMinor,
      currency: "GHS",
      ...(input.merchantNote ? { merchant_note: input.merchantNote.slice(0, 200) } : {}),
    });
    const data = (json.data ?? {}) as Json;
    return {
      providerRefundId: data.id === undefined || data.id === null ? null : String(data.id),
      status: (asString(data.status) ?? "pending").toLowerCase(),
    };
  }

  async listTransactions(input: { from: string; to: string; page?: number; perPage?: number }) {
    const params = new URLSearchParams({
      from: input.from,
      to: input.to,
      page: String(input.page ?? 1),
      perPage: String(input.perPage ?? 100),
    });
    const json = await this.call("GET", `/transaction?${params.toString()}`);
    const rows = Array.isArray(json.data) ? (json.data as Json[]) : [];
    const meta = (json.meta ?? {}) as Json;
    const transactions: ListedTransaction[] = rows.map((row) => ({
      reference: asString(row.reference) ?? "",
      status: mapPaystackStatus(row.status),
      amountMinor: asNumber(row.amount) ?? 0,
      currency: asString(row.currency) ?? "",
      transactionId: row.id === undefined || row.id === null ? null : String(row.id),
      paidAt: asString(row.paid_at),
      channel: asString(row.channel),
    }));
    const page = asNumber(meta.page) ?? input.page ?? 1;
    const pageCount = asNumber(meta.pageCount) ?? page;
    return { transactions, hasMore: page < pageCount };
  }

  parseWebhook(rawBody: Buffer | string, signature: string | undefined): WebhookParseResult {
    if (!verifyWebhookSignature(rawBody, signature, this.secretKey))
      return { ok: false, reason: "invalid_signature" };
    let body: Json;
    try {
      body = JSON.parse(typeof rawBody === "string" ? rawBody : rawBody.toString("utf8")) as Json;
    } catch {
      return { ok: false, reason: "invalid_json" };
    }
    const event = asString(body.event);
    if (!event) return { ok: false, reason: "no_event" };
    const data = (body.data ?? {}) as Json;
    const nested = (data.transaction ?? {}) as Json;
    const reference = asString(data.reference);
    // Refund notifications name the payment being refunded (our reference) rather than carrying a "reference" of their own.
    const transactionReference =
      asString(data.transaction_reference) ?? asString(nested.reference) ?? reference;
    const refundId = data.refund_reference ?? data.id;
    const identity =
      data.id !== undefined && data.id !== null
        ? String(data.id)
        : refundId !== undefined && refundId !== null
          ? String(refundId)
          : (transactionReference ?? reference);
    const fallback = createHash("sha256").update(rawBody).digest("hex");
    const isRefund = event.startsWith("refund.");
    return {
      ok: true,
      event: {
        event,
        dedupeKey: `${event}:${identity ?? fallback}`,
        reference: reference ?? (isRefund ? transactionReference : null),
        domain: asDomain(data.domain),
        ...(isRefund
          ? {
              transactionReference,
              refundId: refundId === undefined || refundId === null ? null : String(refundId),
              amountMinor: asNumber(data.amount),
            }
          : {}),
      },
    };
  }
}
