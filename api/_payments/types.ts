// The provider-neutral shapes of online payments. Nothing outside the provider adapters knows a provider's own field names.

export type ProviderMode = "test" | "live";

/** What a provider says about one payment, in our terms. `unknown` is a status we do not act on. */
export type PaymentStatus = "success" | "failed" | "abandoned" | "pending" | "unknown";

export type VerifiedPayment = {
  reference: string;
  status: PaymentStatus;
  /** The amount in the provider's minor unit (pesewas for GHS). */
  amountMinor: number;
  currency: string;
  transactionId: string | null;
  channel: string | null;
  feeMinor: number | null;
  failureReason: string | null;
  paidAt: string | null;
  /** The mode the provider says this transaction belongs to, when it says. */
  domain: ProviderMode | null;
};

export type InitializedPayment = {
  reference: string;
  authorizationUrl: string;
  accessCode: string;
};

export type InitializeInput = {
  email: string;
  amountMinor: number;
  reference: string;
  callbackUrl: string;
  metadata?: Record<string, unknown>;
  channels?: string[];
};

export type ListedTransaction = {
  reference: string;
  status: PaymentStatus;
  amountMinor: number;
  currency: string;
  transactionId: string | null;
  paidAt: string | null;
  channel: string | null;
};

/** One notification from the provider, after its signature has been checked. */
export type ProviderEvent = {
  /** The provider's event name, e.g. "charge.success". */
  event: string;
  /** Identifies the notification so a retry or duplicate is recognised. */
  dedupeKey: string;
  reference: string | null;
  domain: ProviderMode | null;
  /** For refund notifications: the reference of the payment being refunded, the provider's own refund id, and the amount it states. */
  transactionReference?: string | null;
  refundId?: string | null;
  amountMinor?: number | null;
};

export type RefundInput = {
  /** The reference of the payment being refunded (ours). */
  transactionReference: string;
  amountMinor: number;
  /** A short note for the provider's dashboard. */
  merchantNote?: string;
};

/** What the provider answered when asked to refund. A refund is asynchronous: acceptance is not completion. */
export type RefundResult = {
  providerRefundId: string | null;
  /** The provider's own word for where the refund stands right now ("pending", "processing", "processed", "failed"). */
  status: string;
};

export type WebhookParseResult = { ok: true; event: ProviderEvent } | { ok: false; reason: string };

export class ProviderError extends Error {
  constructor(
    message: string,
    readonly options: { status?: number; notFound?: boolean } = {},
  ) {
    super(message);
    this.name = "ProviderError";
  }
}

export interface PaymentProvider {
  readonly name: string;
  readonly mode: ProviderMode;
  initialize(input: InitializeInput): Promise<InitializedPayment>;
  /** Asks the provider (server to server) what happened to a payment. This, never a redirect or a notification, is proof. */
  verify(reference: string): Promise<VerifiedPayment>;
  /** Asks the provider to return money. A thrown ProviderError with a status in 400 to 499 means it was refused; anything else leaves it uncertain. */
  refund(input: RefundInput): Promise<RefundResult>;
  listTransactions(input: {
    from: string;
    to: string;
    page?: number;
    perPage?: number;
  }): Promise<{ transactions: ListedTransaction[]; hasMore: boolean }>;
  /** Checks the signature of a notification against the raw request body and reads it. */
  parseWebhook(rawBody: Buffer | string, signature: string | undefined): WebhookParseResult;
}
