import { useCallback, useEffect, useState } from "react";
import { PackageMinus, MessageCircleQuestion, Undo2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Skeleton } from "@/components/ui/skeleton";
import { Textarea } from "@/components/ui/textarea";
import { BackorderPanel } from "@/components/orders/BackorderPanel";
import { PriceChangeSection } from "@/components/orders/PriceChangeSection";
import { TextDialog } from "@/components/orders/TextDialog";
import type { PrintableOrder } from "@/components/order-print";
import { backorderConsequence } from "@/lib/order-backorder";
import { supabase } from "@/integrations/supabase/client";
import { formatGHS } from "@/lib/format";
import {
  AMENDMENT_STATUS_LABELS,
  acceptanceConsequence,
  canProposeSupplyChange,
  deltaPhrase,
  draftFromView,
  draftShort,
  draftSupply,
  draftTotals,
  isOpenAmendment,
  openAmendment,
  pharmacySummary,
  proposalPayload,
  responseSummary,
  validateDraft,
  type Amendment,
  type DraftLine,
  type OrderAmendmentsView,
} from "@/lib/order-amendments";
import { hasPriceChangeContent } from "@/lib/price-amendment";
import { formatReportDate } from "@/lib/reports";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

type Side = "wholesaler" | "pharmacy";
type PharmacyAction = "accept" | "backorder" | "reject" | "ask";

const readError = (error: unknown) =>
  (error as { message?: string } | null)?.message ?? "Something went wrong. Please try again.";

const timeOf = (iso: string) =>
  new Date(iso).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });

/** The supply-change area of an order: the wholesaler proposes a smaller supply, the pharmacy decides. Shows nothing
 * for an order that has never had a proposal and cannot get one. */
export function SupplyChangePanel({
  orderId,
  orderStatus,
  paymentStatus,
  side,
  canAct,
  canProposePrices = false,
  printable = null,
  onChanged,
}: {
  orderId: string;
  orderStatus: string;
  paymentStatus?: string | null;
  side: Side;
  /** The order as a printable document, so a back-order shipment can print its own sheets. */
  printable?: PrintableOrder | null;
  /** Whether this user may propose / respond (the database enforces it; this only hides buttons). */
  canAct: boolean;
  /** Wholesaler side: may this user propose price changes (owner or manager)? Pharmacy side ignores it. */
  canProposePrices?: boolean;
  onChanged?: () => void;
}) {
  const [view, setView] = useState<OrderAmendmentsView | null>(null);
  const [failed, setFailed] = useState(false);
  const [loading, setLoading] = useState(true);
  const [proposing, setProposing] = useState(false);
  const [responding, setResponding] = useState<PharmacyAction | null>(null);
  const [replying, setReplying] = useState(false);
  const [withdrawing, setWithdrawing] = useState(false);
  const [busy, setBusy] = useState(false);
  const [tick, setTick] = useState(0);

  const load = useCallback(async () => {
    setLoading(true);
    setFailed(false);
    const { data, error } = await db.rpc("get_order_amendments", { p_order_id: orderId });
    setLoading(false);
    if (error) return setFailed(true);
    setView(data as OrderAmendmentsView);
  }, [orderId]);

  useEffect(() => {
    void load();
  }, [load, orderStatus]);

  const done = async (message: string) => {
    toast.success(message);
    setTick((value) => value + 1);
    await load();
    onChanged?.();
  };

  const run = async (fn: string, args: Record<string, unknown>, success: string) => {
    setBusy(true);
    const { error } = await db.rpc(fn, args);
    setBusy(false);
    if (error) {
      toast.error(readError(error));
      return false;
    }
    await done(success);
    return true;
  };

  if (loading && !view) {
    return (
      <div className="mt-4 space-y-2" role="status" aria-label="Loading supply changes">
        <Skeleton className="h-5 w-1/3" />
        <Skeleton className="h-16 w-full" />
      </div>
    );
  }
  if (failed) {
    return (
      <p role="alert" className="mt-4 text-sm">
        We couldn&apos;t load this order&apos;s supply changes.{" "}
        <button type="button" className="text-primary underline" onClick={() => void load()}>
          Try again
        </button>
      </p>
    );
  }
  if (!view) return null;

  const open = openAmendment(view);
  const history = view.amendments.filter(
    (amendment) => amendment.kind === "partial_fulfilment" && !isOpenAmendment(amendment),
  );
  const priceContent = hasPriceChangeContent(
    view,
    side,
    canProposePrices,
    orderStatus,
    paymentStatus,
  );
  const canPropose =
    side === "wholesaler" && canAct && canProposeSupplyChange(view, orderStatus, paymentStatus);
  if (!open && history.length === 0 && !canPropose && !view.amended && !priceContent) return null;

  return (
    <section
      className="mt-4 rounded-xl border border-border p-3 sm:p-4"
      aria-label="Supply changes"
    >
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="flex items-center gap-2 text-sm font-semibold">
          <PackageMinus className="h-4 w-4 text-muted-foreground" aria-hidden="true" />
          Supply changes
        </h3>
        {canPropose && (
          <Button type="button" variant="outline" size="sm" onClick={() => setProposing(true)}>
            Propose partial supply
          </Button>
        )}
      </div>

      {view.amended && (
        <div className="mt-3 rounded-lg bg-muted/50 p-3 text-sm">
          <div className="font-medium">
            Order total now {formatGHS(view.current_total)}{" "}
            <span className="font-normal text-muted-foreground">
              (placed as {formatGHS(view.original_total)})
            </span>
          </div>
          <div className="mt-1 text-xs text-muted-foreground">
            The original order is kept unchanged; the figures below are what is being supplied.
          </div>
        </div>
      )}

      {view.amended && <SupplyTable view={view} />}
      {view.amended && (
        <BackorderPanel
          orderId={orderId}
          orderStatus={orderStatus}
          side={side}
          canAct={canAct}
          printable={printable}
          refreshKey={tick}
          onChanged={() => {
            setTick((value) => value + 1);
            void load();
            onChanged?.();
          }}
        />
      )}

      {open && (
        <OpenProposal
          amendment={open}
          view={view}
          side={side}
          canAct={canAct}
          onRespond={setResponding}
          onReply={() => setReplying(true)}
          onWithdraw={() => setWithdrawing(true)}
        />
      )}

      <PriceChangeSection
        orderId={orderId}
        orderStatus={orderStatus}
        paymentStatus={paymentStatus}
        view={view}
        side={side}
        canPropose={canProposePrices}
        canRespond={canAct}
        onChanged={async () => {
          setTick((value) => value + 1);
          await load();
          onChanged?.();
        }}
      />

      {history.length > 0 && (
        <details className="mt-3 text-sm">
          <summary className="cursor-pointer text-muted-foreground">
            Earlier proposals ({history.length})
          </summary>
          <ul className="mt-2 space-y-2">
            {history.map((amendment) => (
              <li key={amendment.id} className="rounded-lg border border-border p-2">
                <div className="flex flex-wrap justify-between gap-2">
                  <span className="font-medium">
                    Proposal {amendment.version}: {AMENDMENT_STATUS_LABELS[amendment.status]}
                  </span>
                  <span className="text-xs text-muted-foreground">
                    {formatGHS(amendment.original_total)} → {formatGHS(amendment.proposed_total)}
                  </span>
                </div>
                <div className="text-xs text-muted-foreground">
                  {amendment.reason} · {responseSummary(amendment)}
                  {amendment.responded_at && ` · ${formatReportDate(amendment.responded_at)}`}
                </div>
              </li>
            ))}
          </ul>
        </details>
      )}

      {proposing && (
        <ProposeDialog
          view={view}
          busy={busy}
          onClose={() => setProposing(false)}
          onSubmit={async (reason, lines) => {
            const ok = await run(
              "propose_partial_fulfilment",
              {
                p_order_id: orderId,
                p_reason: reason,
                p_lines: lines,
                p_request_id: crypto.randomUUID(),
              },
              "Proposal sent to the pharmacy",
            );
            if (ok) setProposing(false);
          }}
        />
      )}

      {open && responding && (
        <RespondDialog
          action={responding}
          amendment={open}
          isCredit={view.is_credit_order}
          busy={busy}
          onClose={() => setResponding(null)}
          onSubmit={async (note) => {
            const choice =
              responding === "accept"
                ? "accept_cancel_remaining"
                : responding === "backorder"
                  ? "accept_backorder"
                  : responding === "reject"
                    ? "reject"
                    : "request_clarification";
            const ok = await run(
              "respond_to_amendment",
              { p_amendment_id: open.id, p_choice: choice, p_note: note || null },
              responding === "accept"
                ? "Accepted. The remaining quantity is cancelled."
                : responding === "backorder"
                  ? "Accepted. The rest is on back-order."
                  : responding === "reject"
                    ? "Rejected. The order stands as placed."
                    : "Question sent to the wholesaler",
            );
            if (ok) setResponding(null);
          }}
        />
      )}

      {open && replying && (
        <TextDialog
          title="Reply to the pharmacy"
          description="Your answer goes to the pharmacy, which then decides on the proposal."
          label="Your reply"
          submitLabel="Send reply"
          required
          busy={busy}
          onClose={() => setReplying(false)}
          onSubmit={async (text) => {
            const ok = await run(
              "answer_amendment_clarification",
              { p_amendment_id: open.id, p_message: text },
              "Reply sent",
            );
            if (ok) setReplying(false);
          }}
        />
      )}

      {open && withdrawing && (
        <TextDialog
          title="Withdraw this proposal?"
          description="The order stands exactly as placed and nothing changes. You can propose again later."
          label="Note (optional)"
          submitLabel="Withdraw proposal"
          busy={busy}
          onClose={() => setWithdrawing(false)}
          onSubmit={async (text) => {
            const ok = await run(
              "withdraw_amendment",
              { p_amendment_id: open.id, p_note: text || null },
              "Proposal withdrawn",
            );
            if (ok) setWithdrawing(false);
          }}
        />
      )}
    </section>
  );
}

/** Ordered / committed / outstanding at a glance, for an order that has been amended. */
function SupplyTable({ view }: { view: OrderAmendmentsView }) {
  return (
    <div className="mt-3 overflow-x-auto">
      <table className="w-full text-sm">
        <caption className="sr-only">Quantities ordered and now being supplied</caption>
        <thead>
          <tr className="border-b border-border text-left text-xs text-muted-foreground">
            <th scope="col" className="py-1 pr-3 font-medium">
              Product
            </th>
            <th scope="col" className="py-1 pr-3 text-right font-medium">
              Ordered
            </th>
            <th scope="col" className="py-1 pr-3 text-right font-medium">
              Supplying
            </th>
            <th scope="col" className="py-1 text-right font-medium">
              Not now
            </th>
          </tr>
        </thead>
        <tbody>
          {view.lines.map((line) => (
            <tr key={line.order_item_id} className="border-b border-border/50">
              <td className="py-1 pr-3">{line.product_name}</td>
              <td className="py-1 pr-3 text-right tabular-nums">{line.ordered_qty}</td>
              <td className="py-1 pr-3 text-right font-medium tabular-nums">{line.supplied_qty}</td>
              <td className="py-1 text-right tabular-nums text-muted-foreground">
                {line.ordered_qty - line.supplied_qty || "—"}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function OpenProposal({
  amendment,
  view,
  side,
  canAct,
  onRespond,
  onReply,
  onWithdraw,
}: {
  amendment: Amendment;
  view: OrderAmendmentsView;
  side: Side;
  canAct: boolean;
  onRespond: (action: PharmacyAction) => void;
  onReply: () => void;
  onWithdraw: () => void;
}) {
  const asking = amendment.status === "clarification_requested";
  return (
    <div className="mt-3 rounded-lg border border-amber-500/40 bg-amber-500/5 p-3 text-sm">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="font-semibold">
          Proposal {amendment.version}: {AMENDMENT_STATUS_LABELS[amendment.status]}
        </span>
        <span className="text-xs text-muted-foreground">
          {amendment.proposed_by_label ?? "Wholesaler"} · {formatReportDate(amendment.proposed_at)}{" "}
          {timeOf(amendment.proposed_at)}
        </span>
      </div>
      <p className="mt-2 text-muted-foreground">
        <span className="font-medium text-foreground">Reason:</span> {amendment.reason}
      </p>
      {side === "pharmacy" && <p className="mt-2">{pharmacySummary(amendment)}</p>}

      <div className="mt-3 overflow-x-auto">
        <table className="w-full text-sm">
          <caption className="sr-only">Proposed quantities per product</caption>
          <thead>
            <tr className="border-b border-border text-left text-xs text-muted-foreground">
              <th scope="col" className="py-1 pr-3 font-medium">
                Product
              </th>
              <th scope="col" className="py-1 pr-3 text-right font-medium">
                Ordered
              </th>
              <th scope="col" className="py-1 pr-3 text-right font-medium">
                Available
              </th>
              <th scope="col" className="py-1 pr-3 text-right font-medium">
                Shortage
              </th>
              {side === "wholesaler" && (
                <th scope="col" className="py-1 font-medium">
                  Stock
                </th>
              )}
            </tr>
          </thead>
          <tbody>
            {amendment.lines.map((line) => (
              <tr key={line.order_item_id} className="border-b border-border/50">
                <td className="py-1 pr-3">{line.product_name}</td>
                <td className="py-1 pr-3 text-right tabular-nums">{line.prior_supplied_qty}</td>
                <td className="py-1 pr-3 text-right font-medium tabular-nums">
                  {line.supplied_qty}
                </td>
                <td className="py-1 pr-3 text-right tabular-nums">
                  {line.short_qty > 0 ? <b>{line.short_qty}</b> : "—"}
                </td>
                {side === "wholesaler" && (
                  <td className="py-1 text-xs text-muted-foreground">
                    {line.short_qty === 0
                      ? ""
                      : line.stock_treatment === "release"
                        ? "Released to stock"
                        : line.stock_treatment === "write_off"
                          ? "Written off"
                          : "No stock change"}
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <dl className="mt-3 grid grid-cols-3 gap-2 text-center text-xs">
        <div className="rounded-md bg-background p-2">
          <dt className="text-muted-foreground">Current total</dt>
          <dd className="text-sm font-semibold">{formatGHS(amendment.original_total)}</dd>
        </div>
        <div className="rounded-md bg-background p-2">
          <dt className="text-muted-foreground">Proposed total</dt>
          <dd className="text-sm font-semibold">{formatGHS(amendment.proposed_total)}</dd>
        </div>
        <div className="rounded-md bg-background p-2">
          <dt className="text-muted-foreground">Change</dt>
          <dd className="text-sm font-semibold">{deltaPhrase(amendment.delta)}</dd>
        </div>
      </dl>

      {amendment.messages.length > 0 && (
        <ul className="mt-3 space-y-1" aria-label="Questions and replies">
          {amendment.messages.map((message, index) => (
            <li
              key={`${message.at}-${index}`}
              className={`rounded-md p-2 text-xs ${message.side === side ? "bg-primary/10" : "bg-muted"}`}
            >
              <span className="font-medium">
                {message.author_label ??
                  (message.side === "wholesaler" ? "Wholesaler" : "Pharmacy")}
              </span>{" "}
              <span className="text-muted-foreground">
                {formatReportDate(message.at)} {timeOf(message.at)}
              </span>
              <div className="mt-0.5 text-sm">{message.message}</div>
            </li>
          ))}
        </ul>
      )}

      <p className="mt-3 text-xs text-muted-foreground">{responseSummary(amendment)}</p>

      {canAct && side === "pharmacy" && !asking && (
        <div className="mt-3 flex flex-wrap gap-2">
          <Button type="button" size="sm" variant="hero" onClick={() => onRespond("accept")}>
            Accept and cancel the rest
          </Button>
          {view.is_credit_order && (
            <Button type="button" size="sm" variant="hero" onClick={() => onRespond("backorder")}>
              Accept and back-order the rest
            </Button>
          )}
          <Button type="button" size="sm" variant="outline" onClick={() => onRespond("reject")}>
            Reject
          </Button>
          <Button type="button" size="sm" variant="outline" onClick={() => onRespond("ask")}>
            <MessageCircleQuestion className="mr-1 h-4 w-4" aria-hidden="true" /> Ask a question
          </Button>
        </div>
      )}
      {canAct && side === "pharmacy" && asking && (
        <div className="mt-3">
          <Button type="button" size="sm" variant="outline" onClick={() => onRespond("ask")}>
            Add to your question
          </Button>
        </div>
      )}
      {canAct && side === "wholesaler" && (
        <div className="mt-3 flex flex-wrap gap-2">
          {asking && (
            <Button type="button" size="sm" variant="hero" onClick={onReply}>
              Reply to the pharmacy
            </Button>
          )}
          <Button type="button" size="sm" variant="outline" onClick={onWithdraw}>
            <Undo2 className="mr-1 h-4 w-4" aria-hidden="true" /> Withdraw
          </Button>
        </div>
      )}
      {side === "pharmacy" && view.order_number && (
        <p className="sr-only">Proposal for order {view.order_number}</p>
      )}
    </div>
  );
}

function ProposeDialog({
  view,
  busy,
  onClose,
  onSubmit,
}: {
  view: OrderAmendmentsView;
  busy: boolean;
  onClose: () => void;
  onSubmit: (reason: string, lines: ReturnType<typeof proposalPayload>) => void | Promise<void>;
}) {
  const [lines, setLines] = useState<DraftLine[]>(() => draftFromView(view));
  const [reason, setReason] = useState("");
  const evidence = Boolean(view.stock_evidence);
  const totals = draftTotals(lines, view.current_total);
  const problem = validateDraft(lines, reason, evidence);
  const [touched, setTouched] = useState(false);
  const update = (id: string, patch: Partial<DraftLine>) =>
    setLines((current) =>
      current.map((line) => (line.order_item_id === id ? { ...line, ...patch } : line)),
    );

  return (
    <Dialog open onOpenChange={(next) => !next && !busy && onClose()}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>Propose a partial supply</DialogTitle>
          <DialogDescription>
            Enter what you can supply for each product. Nothing changes until the pharmacy accepts,
            and the order cannot be dispatched in the meantime.
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-3">
          {lines.map((line) => {
            const short = draftShort(line);
            return (
              <div key={line.order_item_id} className="rounded-lg border border-border p-3 text-sm">
                <div className="flex flex-wrap justify-between gap-1">
                  <span className="font-medium">{line.product_name}</span>
                  <span className="text-xs text-muted-foreground">
                    Ordered {line.ordered_qty}
                    {line.current_qty !== line.ordered_qty
                      ? ` · committed ${line.current_qty}`
                      : ""}{" "}
                    · {formatGHS(line.unit_price_ghs)} each
                  </span>
                </div>
                <div className="mt-2 grid gap-2 sm:grid-cols-3">
                  <label className="text-xs">
                    Can supply
                    <input
                      type="text"
                      inputMode="numeric"
                      className="mt-1 h-9 w-full rounded-md border border-input bg-background px-2 text-sm"
                      placeholder={String(line.current_qty)}
                      value={line.supply}
                      onChange={(event) =>
                        update(line.order_item_id, { supply: event.target.value })
                      }
                      aria-label={`Quantity to supply for ${line.product_name}`}
                    />
                  </label>
                  <div className="text-xs">
                    Shortage
                    <div className="mt-1 flex h-9 items-center text-sm font-semibold">
                      {short > 0 ? `${short} (${formatGHS(short * line.unit_price_ghs)})` : "—"}
                    </div>
                  </div>
                  {evidence && short > 0 && (
                    <label className="text-xs">
                      Stock for the shortage
                      <select
                        className="mt-1 h-9 w-full rounded-md border border-input bg-background px-2 text-sm"
                        value={line.treatment}
                        onChange={(event) =>
                          update(line.order_item_id, {
                            treatment: event.target.value as DraftLine["treatment"],
                          })
                        }
                        aria-label={`Stock treatment for ${line.product_name}`}
                      >
                        <option value="">Choose…</option>
                        <option value="release">Release to stock (the units exist)</option>
                        <option value="write_off">Write off (the units do not exist)</option>
                      </select>
                    </label>
                  )}
                </div>
                {draftSupply(line) === null && (
                  <p role="alert" className="mt-1 text-xs text-destructive">
                    Enter a whole number.
                  </p>
                )}
              </div>
            );
          })}
        </div>

        <label className="block text-sm font-medium">
          Reason for the shortage
          <Textarea
            className="mt-1"
            rows={3}
            maxLength={500}
            value={reason}
            onChange={(event) => setReason(event.target.value)}
            placeholder="For example: supplier delivery delayed, damaged in store, count error"
          />
        </label>

        <div className="rounded-lg bg-muted/50 p-3 text-sm" aria-live="polite">
          {totals.shortLines === 0 ? (
            <span className="text-muted-foreground">
              Enter a smaller quantity for at least one product.
            </span>
          ) : (
            <>
              <b>{totals.shortUnits}</b> unit{totals.shortUnits === 1 ? "" : "s"} short on{" "}
              <b>{totals.shortLines}</b> product{totals.shortLines === 1 ? "" : "s"}. The order
              total changes from <b>{formatGHS(view.current_total)}</b> to{" "}
              <b>{formatGHS(totals.newTotal)}</b> (
              {deltaPhrase(totals.newTotal - view.current_total)}).{" "}
              {view.is_credit_order
                ? "A credit note for that amount is issued if the pharmacy accepts."
                : "That is the amount to collect on delivery if the pharmacy accepts."}
              {!evidence && (
                <div className="mt-1 text-xs text-muted-foreground">
                  This order has no verified stock deduction, so no stock is changed automatically;
                  reconcile stock manually.
                </div>
              )}
            </>
          )}
        </div>
        {touched && problem && (
          <p role="alert" className="text-sm text-destructive">
            {problem}
          </p>
        )}

        <DialogFooter className="gap-2 sm:gap-0">
          <Button type="button" variant="outline" disabled={busy} onClick={onClose}>
            Cancel
          </Button>
          <Button
            type="button"
            variant="hero"
            disabled={busy}
            onClick={() => {
              setTouched(true);
              if (problem) return;
              void onSubmit(reason.trim(), proposalPayload(lines, evidence));
            }}
          >
            {busy ? "Sending…" : "Send proposal to the pharmacy"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function RespondDialog({
  action,
  amendment,
  isCredit,
  busy,
  onClose,
  onSubmit,
}: {
  action: PharmacyAction;
  amendment: Amendment;
  isCredit: boolean;
  busy: boolean;
  onClose: () => void;
  onSubmit: (note: string) => void | Promise<void>;
}) {
  const copy = {
    backorder: {
      title: "Accept and back-order the rest?",
      description: `${pharmacySummary(amendment)} ${backorderConsequence(amendment.delta)}`,
      label: "Note (optional)",
      button: "Accept and back-order the rest",
      required: false,
    },
    accept: {
      title: "Accept the reduced supply?",
      description: `${pharmacySummary(amendment)} ${acceptanceConsequence(isCredit, amendment.delta)}`,
      label: "Note (optional)",
      button: "Accept and cancel the rest",
      required: false,
    },
    reject: {
      title: "Reject the reduced supply?",
      description:
        "Your order stays exactly as placed. The wholesaler must supply it in full, cancel it, or propose again.",
      label: "Why are you rejecting it? (optional)",
      button: "Reject",
      required: false,
    },
    ask: {
      title: "Ask the wholesaler a question",
      description:
        "The proposal waits until the wholesaler replies. Nothing is dispatched meanwhile.",
      label: "Your question",
      button: "Send question",
      required: true,
    },
  }[action];
  return (
    <TextDialog
      title={copy.title}
      description={copy.description}
      label={copy.label}
      submitLabel={copy.button}
      required={copy.required}
      busy={busy}
      onClose={onClose}
      onSubmit={onSubmit}
    />
  );
}
