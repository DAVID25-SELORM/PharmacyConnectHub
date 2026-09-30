import { useCallback, useEffect, useState } from "react";
import { ChevronDown, ChevronUp, Receipt } from "lucide-react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { Textarea } from "@/components/ui/textarea";
import { supabase } from "@/integrations/supabase/client";
import { formatGHS } from "@/lib/format";
import { formatReportDate, formatReportDateTime } from "@/lib/reports";
import {
  CREDIT_INVOICE_STATUS_LABELS,
  CREDIT_INVOICE_STATUS_STYLES,
  PAYMENT_METHODS,
  suggestAllocation,
  validateAllocations,
  validatePaymentHeader,
  type CreditInvoice,
  type CreditInvoiceStatus,
} from "@/lib/credit-ledger";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const rpc = (name: string, args: Record<string, unknown>) => (supabase as any).rpc(name, args);

const STATUS_FILTERS: Array<{ value: string; label: string }> = [
  { value: "outstanding", label: "Outstanding" },
  { value: "overdue", label: "Overdue" },
  { value: "due_today", label: "Due today" },
  { value: "partially_paid", label: "Partially paid" },
  { value: "disputed", label: "Disputed" },
  { value: "paid", label: "Paid" },
  { value: "written_off", label: "Written off" },
  { value: "", label: "All" },
];

type LedgerLine = {
  id: string;
  entry_type: string;
  direction: "debit" | "credit";
  amount_ghs: number;
  note: string | null;
  created_at: string;
};

function StatusBadge({ status }: { status: CreditInvoiceStatus }) {
  return (
    <Badge variant="secondary" className={`border ${CREDIT_INVOICE_STATUS_STYLES[status]}`}>
      {CREDIT_INVOICE_STATUS_LABELS[status]}
    </Badge>
  );
}

/** Wholesaler-side credit invoice list: browse, record payments (owner/manager/finance/
 * accountant), and -- for owner/manager, plus dispute for accountant too -- write off, dispute
 * and inspect the ledger behind any invoice. */
export function CreditPaymentsPanel({
  wholesalerId,
  canManage,
  canDispute,
}: {
  wholesalerId: string;
  canManage: boolean;
  canDispute: boolean;
}) {
  const [invoices, setInvoices] = useState<CreditInvoice[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [statusFilter, setStatusFilter] = useState("outstanding");
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [ledgerLines, setLedgerLines] = useState<LedgerLine[]>([]);
  const [ledgerLoading, setLedgerLoading] = useState(false);
  const [payTarget, setPayTarget] = useState<CreditInvoice | null>(null);
  const [writeOffTarget, setWriteOffTarget] = useState<CreditInvoice | null>(null);
  const [disputeTarget, setDisputeTarget] = useState<CreditInvoice | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(false);
    const { data, error: rpcError } = await rpc("list_credit_invoices", {
      p_wholesaler_id: wholesalerId,
      p_pharmacy_id: null,
      p_status: statusFilter || null,
    });
    if (rpcError) setError(true);
    else setInvoices(Array.isArray(data) ? (data as CreditInvoice[]) : []);
    setLoading(false);
  }, [wholesalerId, statusFilter]);

  useEffect(() => {
    void load();
  }, [load]);

  const toggleExpand = async (invoice: CreditInvoice) => {
    if (expandedId === invoice.order_id) {
      setExpandedId(null);
      return;
    }
    setExpandedId(invoice.order_id);
    setLedgerLoading(true);
    const { data, error: rpcError } = await rpc("get_credit_invoice", { p_order_id: invoice.order_id });
    setLedgerLoading(false);
    if (rpcError || !data) {
      toast.error("We couldn't load this invoice's ledger.");
      setLedgerLines([]);
      return;
    }
    setLedgerLines(Array.isArray(data.lines) ? (data.lines as LedgerLine[]) : []);
  };

  const writeOff = async (reason: string) => {
    if (!writeOffTarget) return;
    const { error: rpcError } = await rpc("write_off_credit_invoice", {
      p_order_id: writeOffTarget.order_id,
      p_reason: reason,
    });
    if (rpcError) return toast.error(rpcError.message || "We couldn't write off this invoice.");
    toast.success(`${writeOffTarget.order_number} written off.`);
    setWriteOffTarget(null);
    void load();
  };

  const setDispute = async (disputed: boolean, reason: string) => {
    if (!disputeTarget) return;
    const { error: rpcError } = await rpc("set_credit_invoice_dispute", {
      p_order_id: disputeTarget.order_id,
      p_disputed: disputed,
      p_reason: reason || null,
    });
    if (rpcError) return toast.error(rpcError.message || "We couldn't update this invoice's dispute status.");
    toast.success(disputed ? `${disputeTarget.order_number} marked disputed.` : `Dispute cleared on ${disputeTarget.order_number}.`);
    setDisputeTarget(null);
    void load();
  };

  return (
    <Card className="p-5">
      <div className="flex items-center gap-2">
        <Receipt className="h-5 w-5 text-primary" aria-hidden="true" />
        <h2 className="font-display text-xl font-bold">Credit invoices</h2>
      </div>
      <p className="mt-1 text-sm text-muted-foreground">
        Record payments against credit orders -- a single payment can cover several invoices, and
        one invoice can be settled with several payments over time.
      </p>

      <div className="mt-4 flex flex-wrap gap-2">
        {STATUS_FILTERS.map((filter) => (
          <Button
            key={filter.value || "all"}
            type="button"
            size="sm"
            variant={statusFilter === filter.value ? "secondary" : "ghost"}
            onClick={() => setStatusFilter(filter.value)}
          >
            {filter.label}
          </Button>
        ))}
      </div>

      <div className="mt-4">
        {loading ? (
          <div className="space-y-2">
            <Skeleton className="h-16 w-full" />
            <Skeleton className="h-16 w-full" />
          </div>
        ) : error ? (
          <p role="alert" className="text-sm">
            We couldn&apos;t load credit invoices.{" "}
            <button type="button" className="text-primary underline" onClick={() => void load()}>
              Try again
            </button>
          </p>
        ) : invoices.length === 0 ? (
          <p className="text-sm text-muted-foreground">No credit invoices match this filter.</p>
        ) : (
          <ul className="divide-y divide-border rounded-xl border border-border text-sm">
            {invoices.map((invoice) => {
              const expanded = expandedId === invoice.order_id;
              return (
                <li key={invoice.order_id} className="p-3">
                  <div className="flex flex-wrap items-center justify-between gap-3">
                    <div>
                      <div className="flex flex-wrap items-center gap-2">
                        <span className="font-medium">{invoice.order_number}</span>
                        <StatusBadge status={invoice.status} />
                      </div>
                      <div className="text-muted-foreground">
                        {invoice.pharmacy_name} · {formatGHS(invoice.outstanding_ghs)} outstanding of{" "}
                        {formatGHS(invoice.invoice_ghs)}
                        {invoice.due_date ? ` · due ${formatReportDate(invoice.due_date)}` : ""}
                      </div>
                    </div>
                    <div className="flex flex-wrap items-center gap-2">
                      {invoice.outstanding_ghs > 0 && invoice.status !== "written_off" && (
                        <Button size="sm" variant="hero" onClick={() => setPayTarget(invoice)}>
                          Record payment
                        </Button>
                      )}
                      {canManage && invoice.outstanding_ghs > 0 && invoice.status !== "written_off" && (
                        <Button size="sm" variant="outline" onClick={() => setWriteOffTarget(invoice)}>
                          Write off
                        </Button>
                      )}
                      {canDispute && invoice.status !== "written_off" && (
                        <Button size="sm" variant="outline" onClick={() => setDisputeTarget(invoice)}>
                          {invoice.status === "disputed" ? "Clear dispute" : "Dispute"}
                        </Button>
                      )}
                      <Button
                        type="button"
                        size="sm"
                        variant="ghost"
                        onClick={() => void toggleExpand(invoice)}
                        aria-expanded={expanded}
                      >
                        {expanded ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
                      </Button>
                    </div>
                  </div>

                  {expanded && (
                    <div className="mt-3 rounded-lg border border-border bg-muted/20 p-3">
                      {ledgerLoading ? (
                        <Skeleton className="h-10 w-full" />
                      ) : ledgerLines.length === 0 ? (
                        <p className="text-xs text-muted-foreground">No ledger entries.</p>
                      ) : (
                        <ul className="space-y-1.5">
                          {ledgerLines.map((line) => (
                            <li key={line.id} className="flex items-center justify-between gap-3 text-xs">
                              <span className="text-muted-foreground">
                                {formatReportDateTime(line.created_at)} · {line.entry_type.replace(/_/g, " ")}
                                {line.note ? ` · ${line.note}` : ""}
                              </span>
                              <span className={line.direction === "debit" ? "text-destructive" : "text-success"}>
                                {line.direction === "debit" ? "+" : "-"}
                                {formatGHS(line.amount_ghs)}
                              </span>
                            </li>
                          ))}
                        </ul>
                      )}
                    </div>
                  )}
                </li>
              );
            })}
          </ul>
        )}
      </div>

      {payTarget && (
        <RecordPaymentDialog
          wholesalerId={wholesalerId}
          invoice={payTarget}
          onClose={() => setPayTarget(null)}
          onDone={() => void load()}
        />
      )}
      {writeOffTarget && (
        <ReasonDialog
          title="Write off invoice"
          description={`Zero out the GHS ${writeOffTarget.outstanding_ghs.toFixed(2)} still outstanding on ${writeOffTarget.order_number}. This cannot be undone, but is fully reversible via the ledger if recorded in error.`}
          confirmLabel="Write off"
          onClose={() => setWriteOffTarget(null)}
          onConfirm={(reason) => void writeOff(reason)}
        />
      )}
      {disputeTarget && disputeTarget.status !== "disputed" && (
        <ReasonDialog
          title="Mark invoice disputed"
          description={`${disputeTarget.order_number} will show as disputed until cleared, regardless of its balance.`}
          confirmLabel="Mark disputed"
          onClose={() => setDisputeTarget(null)}
          onConfirm={(reason) => void setDispute(true, reason)}
        />
      )}
      {disputeTarget && disputeTarget.status === "disputed" && (
        <ReasonDialog
          title="Clear dispute"
          description={`${disputeTarget.order_number} will go back to its normal computed status.`}
          confirmLabel="Clear dispute"
          reasonOptional
          onClose={() => setDisputeTarget(null)}
          onConfirm={(reason) => void setDispute(false, reason)}
        />
      )}
    </Card>
  );
}

function ReasonDialog({
  title,
  description,
  confirmLabel,
  reasonOptional,
  onClose,
  onConfirm,
}: {
  title: string;
  description: string;
  confirmLabel: string;
  reasonOptional?: boolean;
  onClose: () => void;
  onConfirm: (reason: string) => void;
}) {
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);

  return (
    <Dialog open onOpenChange={(value) => !value && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          <DialogDescription>{description}</DialogDescription>
        </DialogHeader>
        <Textarea
          placeholder={reasonOptional ? "Reason (optional)" : "Reason (required)"}
          value={reason}
          maxLength={500}
          onChange={(event) => setReason(event.target.value)}
        />
        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={saving}>
            Cancel
          </Button>
          <Button
            variant="hero"
            disabled={saving || (!reasonOptional && !reason.trim())}
            onClick={() => {
              setSaving(true);
              onConfirm(reason.trim());
            }}
          >
            {confirmLabel}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function RecordPaymentDialog({
  wholesalerId,
  invoice,
  onClose,
  onDone,
}: {
  wholesalerId: string;
  invoice: CreditInvoice;
  onClose: () => void;
  onDone: () => void;
}) {
  const [pharmacyInvoices, setPharmacyInvoices] = useState<CreditInvoice[]>([invoice]);
  const [amount, setAmount] = useState(invoice.outstanding_ghs.toFixed(2));
  const [method, setMethod] = useState<string>("cash");
  const [reference, setReference] = useState("");
  const [paidAt, setPaidAt] = useState(() => new Date().toISOString().slice(0, 10));
  const [notes, setNotes] = useState("");
  const [selected, setSelected] = useState<Record<string, boolean>>({ [invoice.order_id]: true });
  const [allocations, setAllocations] = useState<Record<string, string>>({
    [invoice.order_id]: invoice.outstanding_ghs.toFixed(2),
  });
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    let cancelled = false;
    void rpc("list_credit_invoices", {
      p_wholesaler_id: wholesalerId,
      p_pharmacy_id: invoice.pharmacy_id,
      p_status: "outstanding",
    }).then(({ data }: { data: CreditInvoice[] | null }) => {
      if (cancelled || !Array.isArray(data)) return;
      setPharmacyInvoices(data);
    });
    return () => {
      cancelled = true;
    };
  }, [wholesalerId, invoice.pharmacy_id]);

  const toggle = (target: CreditInvoice, checked: boolean) => {
    setSelected((current) => ({ ...current, [target.order_id]: checked }));
    if (checked && !allocations[target.order_id]) {
      const used = Object.entries(selected)
        .filter(([id, on]) => on && id !== target.order_id)
        .reduce((sum, [id]) => sum + Number(allocations[id] || 0), 0);
      const remaining = Number(amount) - used;
      setAllocations((current) => ({
        ...current,
        [target.order_id]: suggestAllocation(remaining, target.outstanding_ghs).toFixed(2),
      }));
    }
  };

  const save = async () => {
    const header = validatePaymentHeader({ amount, method });
    if (header.error) return toast.error(header.error);

    const chosen = pharmacyInvoices.filter((i) => selected[i.order_id]);
    const allocationList = chosen.map((i) => ({
      order_id: i.order_id,
      amount: allocations[i.order_id] || "0",
      outstanding_ghs: i.outstanding_ghs,
    }));
    const validated = validateAllocations(header.amount!, allocationList);
    if (validated.error) return toast.error(validated.error);

    setSaving(true);
    const { error: rpcError } = await rpc("record_credit_payment", {
      p_wholesaler_id: wholesalerId,
      p_pharmacy_id: invoice.pharmacy_id,
      p_amount: header.amount,
      p_method: method,
      p_reference: reference.trim() || null,
      p_paid_at: paidAt ? new Date(`${paidAt}T00:00:00`).toISOString() : null,
      p_notes: notes.trim() || null,
      p_proof_url: null,
      p_allocations: allocationList
        .filter((a) => Number(a.amount) > 0)
        .map((a) => ({ order_id: a.order_id, amount: Number(a.amount) })),
    });
    setSaving(false);
    if (rpcError) return toast.error(rpcError.message || "We couldn't record this payment.");
    toast.success(
      validated.unallocated && validated.unallocated > 0
        ? `Payment recorded. ${formatGHS(validated.unallocated)} left as credit on account.`
        : "Payment recorded.",
    );
    onDone();
    onClose();
  };

  return (
    <Dialog open onOpenChange={(value) => !value && onClose()}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle>Record a payment</DialogTitle>
          <DialogDescription>
            {invoice.pharmacy_name} -- apply this payment to one or more outstanding invoices.
          </DialogDescription>
        </DialogHeader>

        <div className="grid gap-3 sm:grid-cols-2">
          <label className="block text-sm">
            <span className="mb-1 block text-muted-foreground">Amount received (GHS)</span>
            <Input type="number" min={0.01} step="0.01" value={amount} onChange={(e) => setAmount(e.target.value)} />
          </label>
          <label className="block text-sm">
            <span className="mb-1 block text-muted-foreground">Method</span>
            <select
              className="h-10 w-full rounded-md border border-input bg-background px-2 text-sm"
              value={method}
              onChange={(e) => setMethod(e.target.value)}
            >
              {PAYMENT_METHODS.map((m) => (
                <option key={m.value} value={m.value}>
                  {m.label}
                </option>
              ))}
            </select>
          </label>
          <label className="block text-sm">
            <span className="mb-1 block text-muted-foreground">Reference (optional)</span>
            <Input value={reference} maxLength={100} onChange={(e) => setReference(e.target.value)} />
          </label>
          <label className="block text-sm">
            <span className="mb-1 block text-muted-foreground">Date received</span>
            <Input type="date" value={paidAt} onChange={(e) => setPaidAt(e.target.value)} />
          </label>
        </div>
        <label className="block text-sm">
          <span className="mb-1 block text-muted-foreground">Notes (optional)</span>
          <Textarea value={notes} maxLength={1000} onChange={(e) => setNotes(e.target.value)} />
        </label>

        <div>
          <span className="mb-1 block text-sm text-muted-foreground">Apply to</span>
          <ul className="max-h-56 space-y-2 overflow-y-auto rounded-lg border border-border p-2">
            {pharmacyInvoices.map((i) => (
              <li key={i.order_id} className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  className="h-4 w-4"
                  checked={Boolean(selected[i.order_id])}
                  onChange={(e) => toggle(i, e.target.checked)}
                />
                <span className="flex-1">
                  {i.order_number} <span className="text-muted-foreground">({formatGHS(i.outstanding_ghs)} owed)</span>
                </span>
                {selected[i.order_id] && (
                  <Input
                    type="number"
                    min={0}
                    step="0.01"
                    className="h-8 w-28"
                    value={allocations[i.order_id] ?? ""}
                    onChange={(e) =>
                      setAllocations((current) => ({ ...current, [i.order_id]: e.target.value }))
                    }
                  />
                )}
              </li>
            ))}
          </ul>
          <p className="mt-1 text-xs text-muted-foreground">
            Any amount not applied to a specific invoice is kept as unallocated credit on account.
          </p>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={saving}>
            Cancel
          </Button>
          <Button variant="hero" disabled={saving} onClick={() => void save()}>
            {saving ? "Recording..." : "Record payment"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
