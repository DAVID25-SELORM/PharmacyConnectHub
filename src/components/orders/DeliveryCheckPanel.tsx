import { useCallback, useEffect, useState } from "react";
import { ClipboardCheck } from "lucide-react";
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
import { supabase } from "@/integrations/supabase/client";
import { formatGHS } from "@/lib/format";
import {
  KIND_LABELS,
  OUTCOME_LABELS,
  REPORT_STATUS_LABELS,
  decisionCredit,
  decisionSummary,
  decisionsPayload,
  discrepancies,
  draftCounts,
  draftHasProblem,
  draftReceived,
  liveReport,
  outcomesFor,
  reportDraft,
  reportPayload,
  reportSummary,
  validateDecisions,
  validateReportDraft,
  withinReportWindow,
  type DeliveryEntry,
  type DeliveryReport,
  type Discrepancy,
  type OrderDeliveryReports,
  type Outcome,
  type ReportDraftLine,
} from "@/lib/delivery-report";
import { formatReportDate } from "@/lib/reports";
import { amendmentError as readError } from "@/lib/amendment-errors";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

type Side = "wholesaler" | "pharmacy";

/** What each delivery of an order actually brought. The pharmacy records it (a claim, nothing moves); the wholesaler's owner or
 * manager checks it and decides. Shows nothing until something has been delivered. */
export function DeliveryCheckPanel({
  orderId,
  orderStatus,
  side,
  canAct,
  refreshKey,
  onChanged,
}: {
  orderId: string;
  orderStatus: string;
  side: Side;
  /** Pharmacy: may report (owner/manager/cashier). Wholesaler: may decide (owner/manager). The database enforces it. */
  canAct: boolean;
  refreshKey?: number;
  onChanged?: () => void;
}) {
  const [data, setData] = useState<OrderDeliveryReports | null>(null);
  const [failed, setFailed] = useState(false);
  const [reporting, setReporting] = useState<DeliveryEntry | null>(null);
  const [deciding, setDeciding] = useState<DeliveryReport | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    setFailed(false);
    const { data: result, error } = await db.rpc("get_order_delivery_reports", {
      p_order_id: orderId,
    });
    if (error) return setFailed(true);
    setData(result as OrderDeliveryReports);
  }, [orderId]);

  useEffect(() => {
    void load();
  }, [load, orderStatus, refreshKey]);

  const run = async (fn: string, args: Record<string, unknown>, success: string) => {
    setBusy(true);
    const { error } = await db.rpc(fn, args);
    setBusy(false);
    if (error) {
      toast.error(readError(error));
      return false;
    }
    toast.success(success);
    await load();
    onChanged?.();
    return true;
  };

  if (failed) {
    return (
      <p role="alert" className="mt-3 text-sm">
        We couldn&apos;t load this order&apos;s delivery check.{" "}
        <button type="button" className="text-primary underline" onClick={() => void load()}>
          Try again
        </button>
      </p>
    );
  }
  if (!data) return null;
  const delivered = data.deliveries.filter((delivery) => delivery.delivered);
  if (delivered.length === 0 && data.reports.length === 0) return null;

  return (
    <section
      className="mt-4 rounded-xl border border-border p-3 sm:p-4"
      aria-label="Delivery check"
    >
      <h3 className="flex items-center gap-2 text-sm font-semibold">
        <ClipboardCheck className="h-4 w-4 text-muted-foreground" aria-hidden="true" />
        Delivery check
      </h3>
      <p className="mt-1 text-xs text-muted-foreground">
        What each delivery actually brought. A report is a claim: nothing changes in stock or in the
        amount owed until the wholesaler has checked it and decided.
      </p>

      <ul className="mt-3 space-y-3">
        {delivered.map((delivery) => {
          const live = liveReport(data.reports, delivery.shipment_id);
          const history = data.reports.filter(
            (report) => report.shipment_id === delivery.shipment_id && report !== live,
          );
          const canReport =
            side === "pharmacy" && canAct && !live && withinReportWindow(delivery.delivered_at);
          return (
            <li
              key={delivery.shipment_id ?? "main"}
              className="rounded-lg border border-border/70 p-3 text-sm"
            >
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span className="font-medium">{delivery.label}</span>
                <span className="text-xs text-muted-foreground">
                  {delivery.delivered_at
                    ? `Delivered ${formatReportDate(delivery.delivered_at)}`
                    : "Delivered"}
                </span>
              </div>
              {live ? (
                <ReportCard
                  report={live}
                  side={side}
                  canAct={canAct}
                  busy={busy}
                  onDecide={() => setDeciding(live)}
                  onWithdraw={() =>
                    void run(
                      "withdraw_delivery_report",
                      { p_report_id: live.id },
                      "Report withdrawn",
                    )
                  }
                />
              ) : (
                <p className="mt-1 text-xs text-muted-foreground">
                  {side === "pharmacy"
                    ? withinReportWindow(delivery.delivered_at)
                      ? "Not checked yet."
                      : "The 30-day window to report on this delivery has passed."
                    : "The pharmacy has not reported on this delivery."}
                </p>
              )}
              {canReport && (
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  className="mt-2"
                  onClick={() => setReporting(delivery)}
                >
                  Check this delivery
                </Button>
              )}
              {history.length > 0 && (
                <details className="mt-2 text-xs text-muted-foreground">
                  <summary className="cursor-pointer">Earlier reports ({history.length})</summary>
                  <ul className="mt-1 space-y-1">
                    {history.map((report) => (
                      <li key={report.id}>
                        {formatReportDate(report.submitted_at)}:{" "}
                        {REPORT_STATUS_LABELS[report.status]}
                        {report.resolution_note ? `. ${report.resolution_note}` : ""}
                      </li>
                    ))}
                  </ul>
                </details>
              )}
            </li>
          );
        })}
      </ul>

      {reporting && (
        <ReportDialog
          delivery={reporting}
          busy={busy}
          onClose={() => setReporting(null)}
          onSubmit={async (lines, note) => {
            const ok = await run(
              "submit_delivery_report",
              {
                p_order_id: orderId,
                p_shipment_id: reporting.shipment_id,
                p_lines: lines,
                p_note: note || null,
                p_request_id: crypto.randomUUID(),
              },
              lines.length === 0 ? "Recorded as received in full" : "Report sent to the wholesaler",
            );
            if (ok) setReporting(null);
          }}
        />
      )}
      {deciding && (
        <DecideDialog
          report={deciding}
          busy={busy}
          onClose={() => setDeciding(null)}
          onSubmit={async (payload, note) => {
            const ok = await run(
              "resolve_delivery_report",
              { p_report_id: deciding.id, p_decisions: payload, p_note: note || null },
              "Decision recorded",
            );
            if (ok) setDeciding(null);
          }}
        />
      )}
    </section>
  );
}

function ReportCard({
  report,
  side,
  canAct,
  busy,
  onDecide,
  onWithdraw,
}: {
  report: DeliveryReport;
  side: Side;
  canAct: boolean;
  busy: boolean;
  onDecide: () => void;
  onWithdraw: () => void;
}) {
  const outcome = decisionSummary(report);
  return (
    <div className="mt-2 rounded-md bg-muted/40 p-2">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="text-xs font-medium">{REPORT_STATUS_LABELS[report.status]}</span>
        <span className="text-xs text-muted-foreground">
          {report.submitted_by_label ?? "Pharmacy"} · {formatReportDate(report.submitted_at)}
        </span>
      </div>
      <p className="mt-1">{reportSummary(report)}</p>
      {report.status !== "received_in_full" && (
        <ul className="mt-1 text-xs text-muted-foreground">
          {report.lines
            .filter((line) => line.missing + line.damaged + line.rejected > 0)
            .map((line) => (
              <li key={line.id}>
                {line.product_name}: {line.reason}
              </li>
            ))}
        </ul>
      )}
      {report.note && <p className="mt-1 text-xs text-muted-foreground">Note: {report.note}</p>}
      {outcome && (
        <p className="mt-1 text-xs">
          <span className="font-medium">Outcome:</span> {outcome}
          {report.resolved_at && ` · ${formatReportDate(report.resolved_at)}`}
        </p>
      )}
      {report.resolution_note && (
        <p className="mt-1 text-xs text-muted-foreground">
          Wholesaler&apos;s note: {report.resolution_note}
        </p>
      )}
      {report.status === "submitted" && canAct && (
        <div className="mt-2 flex flex-wrap gap-2">
          {side === "wholesaler" && (
            <Button type="button" size="sm" variant="hero" disabled={busy} onClick={onDecide}>
              Check and decide
            </Button>
          )}
          {side === "pharmacy" && (
            <Button type="button" size="sm" variant="outline" disabled={busy} onClick={onWithdraw}>
              Withdraw this report
            </Button>
          )}
        </div>
      )}
      {report.status === "submitted" && side === "wholesaler" && !canAct && (
        <p className="mt-1 text-xs text-muted-foreground">
          The owner or a manager checks and decides on delivery reports.
        </p>
      )}
    </div>
  );
}

function ReportDialog({
  delivery,
  busy,
  onClose,
  onSubmit,
}: {
  delivery: DeliveryEntry;
  busy: boolean;
  onClose: () => void;
  onSubmit: (lines: ReturnType<typeof reportPayload>, note: string) => void | Promise<void>;
}) {
  const [lines, setLines] = useState<ReportDraftLine[]>(() => reportDraft(delivery.expected));
  const [note, setNote] = useState("");
  const [touched, setTouched] = useState(false);
  const problem = validateReportDraft(lines);
  const hasProblem = draftHasProblem(lines);
  const update = (id: string, patch: Partial<ReportDraftLine>) =>
    setLines((current) =>
      current.map((line) => (line.order_item_id === id ? { ...line, ...patch } : line)),
    );
  const field = (line: ReportDraftLine, key: "missing" | "damaged" | "rejected", label: string) => (
    <label className="text-xs">
      {label}
      <input
        type="text"
        inputMode="numeric"
        className="mt-1 h-9 w-full rounded-md border border-input bg-background px-2 text-sm"
        placeholder="0"
        value={line[key]}
        aria-label={`${label} units of ${line.product_name}`}
        onChange={(event) => update(line.order_item_id, { [key]: event.target.value })}
      />
    </label>
  );

  return (
    <Dialog open onOpenChange={(next) => !next && !busy && onClose()}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>Check {delivery.label.toLowerCase()}</DialogTitle>
          <DialogDescription>
            Count what arrived. Leave everything at zero if it all came in good order. A problem is
            only a claim: nothing changes until the wholesaler has checked it.
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          {lines.map((line) => {
            const received = draftReceived(line);
            const counts = draftCounts(line);
            const problemHere =
              (counts.missing ?? 0) + (counts.damaged ?? 0) + (counts.rejected ?? 0) > 0;
            return (
              <div key={line.order_item_id} className="rounded-lg border border-border p-3 text-sm">
                <div className="flex flex-wrap justify-between gap-1">
                  <span className="font-medium">{line.product_name}</span>
                  <span className="text-xs text-muted-foreground">
                    {line.expected} delivered · received {received === null ? "?" : received}
                  </span>
                </div>
                <div className="mt-2 grid gap-2 sm:grid-cols-3">
                  {field(line, "missing", "Missing")}
                  {field(line, "damaged", "Damaged")}
                  {field(line, "rejected", "Rejected")}
                </div>
                {problemHere && (
                  <label className="mt-2 block text-xs">
                    What went wrong
                    <input
                      type="text"
                      className="mt-1 h-9 w-full rounded-md border border-input bg-background px-2 text-sm"
                      maxLength={300}
                      value={line.reason}
                      onChange={(event) =>
                        update(line.order_item_id, { reason: event.target.value })
                      }
                      aria-label={`What went wrong with ${line.product_name}`}
                    />
                  </label>
                )}
              </div>
            );
          })}
        </div>
        <label className="block text-sm font-medium">
          Note (optional)
          <Textarea
            className="mt-1"
            rows={2}
            maxLength={500}
            value={note}
            onChange={(event) => setNote(event.target.value)}
          />
        </label>
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
              void onSubmit(reportPayload(lines), note.trim());
            }}
          >
            {busy ? "Sending…" : hasProblem ? "Send the report" : "Confirm received in full"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function DecideDialog({
  report,
  busy,
  onClose,
  onSubmit,
}: {
  report: DeliveryReport;
  busy: boolean;
  onClose: () => void;
  onSubmit: (payload: ReturnType<typeof decisionsPayload>, note: string) => void | Promise<void>;
}) {
  const items: Discrepancy[] = discrepancies(report);
  const [choices, setChoices] = useState<Record<string, Outcome | "">>({});
  const [note, setNote] = useState("");
  const [touched, setTouched] = useState(false);
  const problem = validateDecisions(items, choices, note);
  const credit = decisionCredit(items, choices);
  return (
    <Dialog open onOpenChange={(next) => !next && !busy && onClose()}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>Check the delivery report</DialogTitle>
          <DialogDescription>
            Decide each problem. Crediting lowers what the pharmacy owes. Taking goods back opens a
            return that goes through your usual inspection; stock and money follow that return.
            Rejecting changes nothing.
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          {items.map((item) => (
            <div key={item.key} className="rounded-lg border border-border p-3 text-sm">
              <div className="flex flex-wrap justify-between gap-1">
                <span className="font-medium">
                  {item.quantity} × {item.product_name}: {KIND_LABELS[item.kind].toLowerCase()}
                </span>
                <span className="text-xs text-muted-foreground">
                  {formatGHS(item.quantity * item.unit_price_ghs)} at the agreed price
                </span>
              </div>
              {item.reason && (
                <p className="mt-1 text-xs text-muted-foreground">Pharmacy says: {item.reason}</p>
              )}
              <label className="mt-2 block text-xs">
                Your decision
                <select
                  className="mt-1 h-9 w-full rounded-md border border-input bg-background px-2 text-sm"
                  value={choices[item.key] ?? ""}
                  aria-label={`Decision for ${item.quantity} ${item.kind} ${item.product_name}`}
                  onChange={(event) =>
                    setChoices((current) => ({
                      ...current,
                      [item.key]: event.target.value as Outcome | "",
                    }))
                  }
                >
                  <option value="">Choose…</option>
                  {outcomesFor(item.kind).map((outcome) => (
                    <option key={outcome} value={outcome}>
                      {OUTCOME_LABELS[outcome]}
                    </option>
                  ))}
                </select>
              </label>
            </div>
          ))}
        </div>
        <label className="block text-sm font-medium">
          Note to the pharmacy (needed if you reject something)
          <Textarea
            className="mt-1"
            rows={2}
            maxLength={500}
            value={note}
            onChange={(event) => setNote(event.target.value)}
          />
        </label>
        <div className="rounded-lg bg-muted/50 p-3 text-sm" aria-live="polite">
          {credit > 0 ? (
            <>
              <b>{formatGHS(credit)}</b> will be credited. This lowers the order total and, on a
              credit order, posts one credit note.
            </>
          ) : (
            <span className="text-muted-foreground">No money changes with these decisions.</span>
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
              void onSubmit(decisionsPayload(items, choices), note.trim());
            }}
          >
            {busy ? "Saving…" : "Record my decision"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
