import { useState } from "react";
import { MessageCircleQuestion, Tag, Undo2 } from "lucide-react";
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
import { Textarea } from "@/components/ui/textarea";
import { TextDialog } from "@/components/orders/TextDialog";
import { supabase } from "@/integrations/supabase/client";
import { formatGHS } from "@/lib/format";
import {
  AMENDMENT_STATUS_LABELS,
  deltaPhrase,
  isOpenAmendment,
  openAmendment,
  type Amendment,
  type OrderAmendmentsView,
} from "@/lib/order-amendments";
import {
  canProposePriceChange,
  draftPrice,
  priceAcceptanceConsequence,
  priceDraftFromView,
  priceDraftTotals,
  pricePayload,
  priceResponseSummary,
  priceSummary,
  validatePriceDraft,
  type PriceDraftLine,
} from "@/lib/price-amendment";
import { formatReportDate } from "@/lib/reports";
import { amendmentError as readError } from "@/lib/amendment-errors";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

type Side = "wholesaler" | "pharmacy";
type PharmacyAction = "accept" | "reject" | "ask";

const timeOf = (iso: string) =>
  new Date(iso).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });

/** Price changes on an order: the wholesaler's owner or a manager proposes new unit prices before dispatch; only the pharmacy's
 * explicit approval applies them. Lives inside the supply-change panel and shares its loaded view. */
export function PriceChangeSection({
  orderId,
  orderStatus,
  paymentStatus,
  view,
  side,
  canPropose,
  canRespond,
  onChanged,
}: {
  orderId: string;
  orderStatus: string;
  paymentStatus?: string | null;
  view: OrderAmendmentsView;
  side: Side;
  /** Wholesaler: owner or manager (propose, reply, withdraw). The database enforces it; this only hides buttons. */
  canPropose: boolean;
  /** Pharmacy: owner, manager or cashier (approve, reject, ask). */
  canRespond: boolean;
  onChanged: () => void | Promise<void>;
}) {
  const [proposing, setProposing] = useState(false);
  const [responding, setResponding] = useState<PharmacyAction | null>(null);
  const [replying, setReplying] = useState(false);
  const [withdrawing, setWithdrawing] = useState(false);
  const [busy, setBusy] = useState(false);

  const open = openAmendment(view, "price_change");
  const history = view.amendments.filter(
    (amendment) => amendment.kind === "price_change" && !isOpenAmendment(amendment),
  );
  const mayPropose =
    side === "wholesaler" && canPropose && canProposePriceChange(view, orderStatus, paymentStatus);
  if (!open && history.length === 0 && !mayPropose) return null;

  const run = async (fn: string, args: Record<string, unknown>, success: string) => {
    setBusy(true);
    const { error } = await db.rpc(fn, args);
    setBusy(false);
    if (error) {
      toast.error(readError(error));
      return false;
    }
    toast.success(success);
    await onChanged();
    return true;
  };

  return (
    <section className="mt-4 rounded-xl border border-border p-3 sm:p-4" aria-label="Price changes">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="flex items-center gap-2 text-sm font-semibold">
          <Tag className="h-4 w-4 text-muted-foreground" aria-hidden="true" />
          Price changes
        </h3>
        {mayPropose && (
          <Button type="button" variant="outline" size="sm" onClick={() => setProposing(true)}>
            Propose new prices
          </Button>
        )}
      </div>

      {open && (
        <OpenPriceProposal
          amendment={open}
          view={view}
          side={side}
          canPropose={canPropose}
          canRespond={canRespond}
          onRespond={setResponding}
          onReply={() => setReplying(true)}
          onWithdraw={() => setWithdrawing(true)}
        />
      )}

      {history.length > 0 && (
        <details className="mt-3 text-sm" open={!open}>
          <summary className="cursor-pointer text-muted-foreground">
            Earlier price proposals ({history.length})
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
                <ul className="mt-1 text-xs text-muted-foreground">
                  {amendment.lines
                    .filter((line) => line.proposed_unit_price_ghs != null)
                    .map((line) => (
                      <li key={line.order_item_id}>
                        {line.product_name}: {formatGHS(line.unit_price_ghs)} →{" "}
                        {formatGHS(Number(line.proposed_unit_price_ghs))}
                      </li>
                    ))}
                </ul>
                <div className="text-xs text-muted-foreground">
                  {amendment.reason} · {priceResponseSummary(amendment)}
                  {amendment.responded_at && ` · ${formatReportDate(amendment.responded_at)}`}
                </div>
              </li>
            ))}
          </ul>
        </details>
      )}

      {proposing && (
        <ProposePriceDialog
          view={view}
          busy={busy}
          onClose={() => setProposing(false)}
          onSubmit={async (reason, lines) => {
            const ok = await run(
              "propose_price_amendment",
              {
                p_order_id: orderId,
                p_reason: reason,
                p_lines: lines,
                p_request_id: crypto.randomUUID(),
              },
              "Price proposal sent to the pharmacy",
            );
            if (ok) setProposing(false);
          }}
        />
      )}

      {open && responding && (
        <PriceRespondDialog
          action={responding}
          amendment={open}
          isCredit={view.is_credit_order}
          busy={busy}
          onClose={() => setResponding(null)}
          onSubmit={async (note) => {
            const choice =
              responding === "accept"
                ? "accept"
                : responding === "reject"
                  ? "reject"
                  : "request_clarification";
            const ok = await run(
              "respond_to_price_amendment",
              { p_amendment_id: open.id, p_choice: choice, p_note: note || null },
              responding === "accept"
                ? "Approved. The new prices apply."
                : responding === "reject"
                  ? "Rejected. The prices stand as agreed."
                  : "Question sent to the wholesaler",
            );
            if (ok) setResponding(null);
          }}
        />
      )}

      {open && replying && (
        <TextDialog
          title="Reply to the pharmacy"
          description="Your answer goes to the pharmacy, which then decides on the price proposal."
          label="Your reply"
          submitLabel="Send reply"
          required
          busy={busy}
          onClose={() => setReplying(false)}
          onSubmit={async (text) => {
            const ok = await run(
              "answer_price_clarification",
              { p_amendment_id: open.id, p_message: text },
              "Reply sent",
            );
            if (ok) setReplying(false);
          }}
        />
      )}

      {open && withdrawing && (
        <TextDialog
          title="Withdraw this price proposal?"
          description="The prices stand as agreed and nothing changes. You can propose again later."
          label="Note (optional)"
          submitLabel="Withdraw proposal"
          busy={busy}
          onClose={() => setWithdrawing(false)}
          onSubmit={async (text) => {
            const ok = await run(
              "withdraw_price_amendment",
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

function OpenPriceProposal({
  amendment,
  view,
  side,
  canPropose,
  canRespond,
  onRespond,
  onReply,
  onWithdraw,
}: {
  amendment: Amendment;
  view: OrderAmendmentsView;
  side: Side;
  canPropose: boolean;
  canRespond: boolean;
  onRespond: (action: PharmacyAction) => void;
  onReply: () => void;
  onWithdraw: () => void;
}) {
  const asking = amendment.status === "clarification_requested";
  const lines = amendment.lines.filter((line) => line.proposed_unit_price_ghs != null);
  return (
    <div className="mt-3 rounded-lg border border-amber-500/40 bg-amber-500/5 p-3 text-sm">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="font-semibold">
          Price proposal {amendment.version}: {AMENDMENT_STATUS_LABELS[amendment.status]}
        </span>
        <span className="text-xs text-muted-foreground">
          {amendment.proposed_by_label ?? "Wholesaler"} · {formatReportDate(amendment.proposed_at)}{" "}
          {timeOf(amendment.proposed_at)}
        </span>
      </div>
      <p className="mt-2 text-muted-foreground">
        <span className="font-medium text-foreground">Reason:</span> {amendment.reason}
      </p>
      {side === "pharmacy" && <p className="mt-2">{priceSummary(amendment)}</p>}

      <div className="mt-3 overflow-x-auto">
        <table className="w-full text-sm">
          <caption className="sr-only">Current and proposed unit price per product</caption>
          <thead>
            <tr className="border-b border-border text-left text-xs text-muted-foreground">
              <th scope="col" className="py-1 pr-3 font-medium">
                Product
              </th>
              <th scope="col" className="py-1 pr-3 text-right font-medium">
                Units
              </th>
              <th scope="col" className="py-1 pr-3 text-right font-medium">
                Now
              </th>
              <th scope="col" className="py-1 text-right font-medium">
                Proposed
              </th>
            </tr>
          </thead>
          <tbody>
            {lines.map((line) => (
              <tr key={line.order_item_id} className="border-b border-border/50">
                <td className="py-1 pr-3">{line.product_name}</td>
                <td className="py-1 pr-3 text-right tabular-nums">{line.supplied_qty}</td>
                <td className="py-1 pr-3 text-right tabular-nums">
                  {formatGHS(line.unit_price_ghs)}
                </td>
                <td className="py-1 text-right font-medium tabular-nums">
                  {formatGHS(Number(line.proposed_unit_price_ghs))}
                </td>
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

      <p className="mt-3 text-xs text-muted-foreground">{priceResponseSummary(amendment)}</p>

      {canRespond && side === "pharmacy" && !asking && (
        <div className="mt-3 flex flex-wrap gap-2">
          <Button type="button" size="sm" variant="hero" onClick={() => onRespond("accept")}>
            Approve the new prices
          </Button>
          <Button type="button" size="sm" variant="outline" onClick={() => onRespond("reject")}>
            Reject
          </Button>
          <Button type="button" size="sm" variant="outline" onClick={() => onRespond("ask")}>
            <MessageCircleQuestion className="mr-1 h-4 w-4" aria-hidden="true" /> Ask a question
          </Button>
        </div>
      )}
      {canRespond && side === "pharmacy" && asking && (
        <div className="mt-3">
          <Button type="button" size="sm" variant="outline" onClick={() => onRespond("ask")}>
            Add to your question
          </Button>
        </div>
      )}
      {canPropose && side === "wholesaler" && (
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
        <p className="sr-only">Price proposal for order {view.order_number}</p>
      )}
    </div>
  );
}

function ProposePriceDialog({
  view,
  busy,
  onClose,
  onSubmit,
}: {
  view: OrderAmendmentsView;
  busy: boolean;
  onClose: () => void;
  onSubmit: (reason: string, lines: ReturnType<typeof pricePayload>) => void | Promise<void>;
}) {
  const [lines, setLines] = useState<PriceDraftLine[]>(() => priceDraftFromView(view));
  const [reason, setReason] = useState("");
  const [touched, setTouched] = useState(false);
  const totals = priceDraftTotals(lines, view.current_total);
  const problem = validatePriceDraft(lines, reason, view.current_total);
  const update = (id: string, next: string) =>
    setLines((current) =>
      current.map((line) => (line.order_item_id === id ? { ...line, next } : line)),
    );

  return (
    <Dialog open onOpenChange={(next) => !next && !busy && onClose()}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>Propose new prices</DialogTitle>
          <DialogDescription>
            Enter the new unit price for each product that changes. Nothing changes until the
            pharmacy approves, and the order cannot be dispatched in the meantime. Quantities and
            the delivery fee stay as they are.
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-3">
          {lines.map((line) => {
            const { value, changed } = draftPrice(line);
            const invalid = line.next.trim() !== "" && value === null;
            return (
              <div key={line.order_item_id} className="rounded-lg border border-border p-3 text-sm">
                <div className="flex flex-wrap justify-between gap-1">
                  <span className="font-medium">{line.product_name}</span>
                  <span className="text-xs text-muted-foreground">
                    {line.committed_qty} unit{line.committed_qty === 1 ? "" : "s"} ·{" "}
                    {formatGHS(line.current_price)} each now
                  </span>
                </div>
                <div className="mt-2 grid gap-2 sm:grid-cols-2">
                  <label className="text-xs">
                    New unit price (GH₵)
                    <input
                      type="text"
                      inputMode="decimal"
                      className="mt-1 h-9 w-full rounded-md border border-input bg-background px-2 text-sm"
                      placeholder={line.current_price.toFixed(2)}
                      value={line.next}
                      onChange={(event) => update(line.order_item_id, event.target.value)}
                      aria-label={`New unit price for ${line.product_name}`}
                    />
                  </label>
                  <div className="text-xs">
                    Effect on this line
                    <div className="mt-1 flex h-9 items-center text-sm font-semibold">
                      {changed && value !== null
                        ? deltaPhrase((value - line.current_price) * line.committed_qty)
                        : "—"}
                    </div>
                  </div>
                </div>
                {invalid && (
                  <p role="alert" className="mt-1 text-xs text-destructive">
                    Enter an amount in cedis with at most two decimals.
                  </p>
                )}
              </div>
            );
          })}
        </div>

        <label className="block text-sm font-medium">
          Reason for the price change
          <Textarea
            className="mt-1"
            rows={3}
            maxLength={500}
            value={reason}
            onChange={(event) => setReason(event.target.value)}
            placeholder="For example: supplier cost increase, agreed volume discount, pricing error"
          />
        </label>

        <div className="rounded-lg bg-muted/50 p-3 text-sm" aria-live="polite">
          {totals.changedLines === 0 ? (
            <span className="text-muted-foreground">
              Enter a different price for at least one product.
            </span>
          ) : (
            <>
              <b>{totals.changedLines}</b> product{totals.changedLines === 1 ? "" : "s"} repriced.
              The order total changes from <b>{formatGHS(view.current_total)}</b> to{" "}
              <b>{formatGHS(totals.newTotal)}</b> ({deltaPhrase(totals.delta)}).{" "}
              {priceAcceptanceConsequence(view.is_credit_order, totals.delta).replace(
                /^If you approve, /,
                "If the pharmacy approves, ",
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
              void onSubmit(reason.trim(), pricePayload(lines));
            }}
          >
            {busy ? "Sending…" : "Send proposal to the pharmacy"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function PriceRespondDialog({
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
    accept: {
      title: "Approve the new prices?",
      description: `${priceSummary(amendment)} ${priceAcceptanceConsequence(isCredit, amendment.delta)}`,
      label: "Note (optional)",
      button: "Approve the new prices",
      required: false,
    },
    reject: {
      title: "Reject the new prices?",
      description:
        "Your order stays at the prices agreed. The wholesaler must supply it as agreed, cancel it, or propose again.",
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
