import { useCallback, useEffect, useState } from "react";
import { toast } from "sonner";
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
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Textarea } from "@/components/ui/textarea";
import { formatGHS } from "@/lib/format";
import { periodLabel } from "@/lib/billing";
import {
  INVOICE_STATUS_LABELS,
  ISSUER_FIELDS,
  MANUAL_METHODS,
  PAYMENT_METHOD_LABELS,
  dateText,
  dueText,
  fetchAdminInvoice,
  fetchAdminInvoices,
  fetchInvoiceSettings,
  newRequestKey,
  paymentFormError,
  receivedAtFromDate,
  recordPayment,
  reversePayment,
  saveInvoiceSettings,
  type AdminInvoices,
  type InvoiceDetail,
  type InvoicePayment,
  type InvoiceSettings,
  type InvoiceStatus,
  type PaymentMethod,
} from "@/lib/billing-invoices";
import { InvoiceDetailView, InvoiceStatusBadge } from "./InvoiceDetailView";

const PAGE = 25;
const today = () => new Date().toISOString().slice(0, 10);
const errText = (e: unknown, fallback: string) => (e instanceof Error ? e.message : fallback);

/** Invoices for the administrator: find one, see what is owed, record a payment that arrived, reverse a mistaken one. Every change needs a reason and is audited by the database. */
export function AdminBillingInvoicesSection() {
  const [status, setStatus] = useState<InvoiceStatus | "all">("all");
  const [type, setType] = useState<"pharmacy" | "wholesaler" | "all">("all");
  const [search, setSearch] = useState("");
  const [query, setQuery] = useState("");
  const [page, setPage] = useState(0);
  const [data, setData] = useState<AdminInvoices | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [openId, setOpenId] = useState<string | null>(null);
  const [detail, setDetail] = useState<InvoiceDetail | null>(null);
  const [detailError, setDetailError] = useState<string | null>(null);
  const [paying, setPaying] = useState(false);
  const [reversing, setReversing] = useState<InvoicePayment | null>(null);

  const load = useCallback(async () => {
    try {
      setData(
        await fetchAdminInvoices({
          status: status === "all" ? null : status,
          businessType: type === "all" ? null : type,
          search: query,
          limit: PAGE,
          offset: page * PAGE,
        }),
      );
      setError(null);
    } catch (e) {
      setError(errText(e, "Could not load invoices."));
    }
  }, [status, type, query, page]);
  useEffect(() => {
    void load();
  }, [load]);

  const loadDetail = useCallback(async (id: string) => {
    try {
      setDetail(await fetchAdminInvoice(id));
      setDetailError(null);
    } catch (e) {
      setDetailError(errText(e, "Could not open this invoice."));
    }
  }, []);
  useEffect(() => {
    if (!openId) return;
    setDetail(null);
    void loadDetail(openId);
  }, [openId, loadDetail]);

  const refreshAll = async () => {
    await Promise.all([load(), openId ? loadDetail(openId) : Promise.resolve()]);
  };

  return (
    <div className="space-y-4" data-testid="admin-invoices">
      <div className="flex flex-wrap items-end gap-3">
        <div className="space-y-1">
          <Label htmlFor="inv-status">Status</Label>
          <Select
            value={status}
            onValueChange={(v) => {
              setPage(0);
              setStatus(v as InvoiceStatus | "all");
            }}
          >
            <SelectTrigger id="inv-status" className="w-40">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All statuses</SelectItem>
              {(Object.keys(INVOICE_STATUS_LABELS) as InvoiceStatus[]).map((s) => (
                <SelectItem key={s} value={s}>
                  {INVOICE_STATUS_LABELS[s]}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="inv-type">Business type</Label>
          <Select
            value={type}
            onValueChange={(v) => {
              setPage(0);
              setType(v as "pharmacy" | "wholesaler" | "all");
            }}
          >
            <SelectTrigger id="inv-type" className="w-40">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All types</SelectItem>
              <SelectItem value="wholesaler">Wholesalers</SelectItem>
              <SelectItem value="pharmacy">Pharmacies</SelectItem>
            </SelectContent>
          </Select>
        </div>
        <form
          className="flex items-end gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            setPage(0);
            setQuery(search);
          }}
        >
          <div className="space-y-1">
            <Label htmlFor="inv-search">Invoice number or business</Label>
            <Input
              id="inv-search"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="DXB-2026-… or a name"
              className="w-60"
            />
          </div>
          <Button type="submit" variant="outline">
            Search
          </Button>
        </form>
      </div>

      {error && (
        <Card className="border-destructive/40 p-4 text-sm text-destructive" role="alert">
          {error}
        </Card>
      )}
      {!data && !error && <Skeleton className="h-40" />}
      {data && (
        <>
          <div className="grid gap-3 sm:grid-cols-4" data-testid="invoice-totals">
            {[
              ["Invoiced", data.totals.invoiced],
              ["Paid", data.totals.paid],
              ["Outstanding", data.totals.outstanding],
              ["Overdue", data.totals.overdue],
            ].map(([label, value]) => (
              <Card key={label as string} className="p-3">
                <div className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
                  {label} (these invoices)
                </div>
                <div className="mt-1 font-display text-lg font-bold">
                  {formatGHS(value as number)}
                </div>
              </Card>
            ))}
          </div>
          <Card className="overflow-x-auto p-0">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Invoice</TableHead>
                  <TableHead>Business</TableHead>
                  <TableHead>Period</TableHead>
                  <TableHead>Due</TableHead>
                  <TableHead className="text-right">Total</TableHead>
                  <TableHead className="text-right">Balance</TableHead>
                  <TableHead>Status</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {data.invoices.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={7} className="py-8 text-center text-muted-foreground">
                      No invoices match. Invoices appear once billing is active and a billing period
                      has ended.
                    </TableCell>
                  </TableRow>
                )}
                {data.invoices.map((i) => (
                  <TableRow
                    key={i.id}
                    className="cursor-pointer"
                    onClick={() => setOpenId(i.id)}
                    data-testid="admin-invoice-row"
                  >
                    <TableCell className="whitespace-nowrap font-medium">
                      {i.invoice_number}
                    </TableCell>
                    <TableCell>
                      {i.business_name}
                      <span className="block text-xs capitalize text-muted-foreground">
                        {i.business_type}
                      </span>
                    </TableCell>
                    <TableCell className="whitespace-nowrap">
                      {periodLabel(i.period_start, i.period_end)}
                    </TableCell>
                    <TableCell className="whitespace-nowrap">
                      {dateText(i.due_at)}
                      <span className="block text-xs text-muted-foreground">{dueText(i)}</span>
                    </TableCell>
                    <TableCell className="text-right">{formatGHS(i.total_amount)}</TableCell>
                    <TableCell className="text-right">{formatGHS(i.outstanding_amount)}</TableCell>
                    <TableCell>
                      <InvoiceStatusBadge status={i.status} />
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </Card>
          <div className="flex items-center justify-between text-sm text-muted-foreground">
            <span>
              {data.count} {data.count === 1 ? "invoice" : "invoices"}
            </span>
            <div className="flex gap-2">
              <Button
                variant="outline"
                size="sm"
                disabled={page === 0}
                onClick={() => setPage((p) => p - 1)}
              >
                Previous
              </Button>
              <Button
                variant="outline"
                size="sm"
                disabled={(page + 1) * PAGE >= data.count}
                onClick={() => setPage((p) => p + 1)}
              >
                Next
              </Button>
            </div>
          </div>
        </>
      )}

      <InvoiceSettingsCard />

      <Sheet open={openId !== null} onOpenChange={(o) => !o && setOpenId(null)}>
        <SheetContent className="w-full overflow-y-auto sm:max-w-2xl">
          <SheetHeader>
            <SheetTitle>{detail?.invoice_number ?? "Invoice"}</SheetTitle>
            <SheetDescription>
              Payments are recorded by hand until online payment is added. Every change needs a
              reason and is kept in the audit trail.
            </SheetDescription>
          </SheetHeader>
          <div className="mt-4 space-y-4">
            {detailError && (
              <p className="text-sm text-destructive" role="alert">
                {detailError}
              </p>
            )}
            {!detail && !detailError && <Skeleton className="h-40" />}
            {detail && (
              <>
                {detail.outstanding_amount > 0 && (
                  <Button onClick={() => setPaying(true)} data-testid="record-payment">
                    Record a payment
                  </Button>
                )}
                <InvoiceDetailView inv={detail} admin onReverse={(p) => setReversing(p)} />
              </>
            )}
          </div>
        </SheetContent>
      </Sheet>

      {detail && (
        <RecordPaymentDialog
          open={paying}
          invoice={detail}
          onClose={() => setPaying(false)}
          onDone={async () => {
            setPaying(false);
            await refreshAll();
          }}
        />
      )}
      <ReversePaymentDialog
        payment={reversing}
        onClose={() => setReversing(null)}
        onDone={async () => {
          setReversing(null);
          await refreshAll();
        }}
      />
    </div>
  );
}

function RecordPaymentDialog({
  open,
  invoice,
  onClose,
  onDone,
}: {
  open: boolean;
  invoice: InvoiceDetail;
  onClose: () => void;
  onDone: () => Promise<void>;
}) {
  const [amount, setAmount] = useState("");
  const [method, setMethod] = useState<PaymentMethod>("bank_transfer");
  const [reference, setReference] = useState("");
  const [received, setReceived] = useState(today());
  const [note, setNote] = useState("");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);
  const [requestKey, setRequestKey] = useState(newRequestKey);

  useEffect(() => {
    if (open) {
      setAmount(invoice.outstanding_amount.toFixed(2));
      setMethod("bank_transfer");
      setReference("");
      setReceived(today());
      setNote("");
      setReason("");
      setFormError(null);
      setRequestKey(newRequestKey());
    }
  }, [open, invoice.id, invoice.outstanding_amount]);

  const submit = async () => {
    const problem = paymentFormError({
      amount,
      outstanding: invoice.outstanding_amount,
      receivedAt: received,
      reason,
    });
    if (problem) {
      setFormError(problem);
      return;
    }
    setBusy(true);
    setFormError(null);
    try {
      const res = await recordPayment({
        invoiceId: invoice.id,
        amount: Number(amount),
        method,
        reference,
        receivedAt: receivedAtFromDate(received),
        note,
        reason: reason.trim(),
        requestKey,
      });
      toast.success(
        res.invoice_status === "paid"
          ? "Payment recorded. The invoice is now paid."
          : `Payment recorded. ${formatGHS(res.outstanding)} is still outstanding.`,
      );
      await onDone();
    } catch (e) {
      setFormError(errText(e, "The payment could not be recorded."));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={(o) => !o && !busy && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Record a payment for {invoice.invoice_number}</DialogTitle>
          <DialogDescription>
            {invoice.business_name} owes {formatGHS(invoice.outstanding_amount)} on this invoice.
            Only record money that has actually arrived.
          </DialogDescription>
        </DialogHeader>
        <div className="grid gap-3">
          <div className="grid gap-1">
            <Label htmlFor="pay-amount">Amount received (GH₵)</Label>
            <Input
              id="pay-amount"
              inputMode="decimal"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
            />
          </div>
          <div className="grid gap-1">
            <Label htmlFor="pay-method">How it was paid</Label>
            <Select value={method} onValueChange={(v) => setMethod(v as PaymentMethod)}>
              <SelectTrigger id="pay-method">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {MANUAL_METHODS.map((m) => (
                  <SelectItem key={m} value={m}>
                    {PAYMENT_METHOD_LABELS[m]}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div className="grid gap-1">
            <Label htmlFor="pay-ref">Reference (bank or mobile money transaction number)</Label>
            <Input id="pay-ref" value={reference} onChange={(e) => setReference(e.target.value)} />
          </div>
          <div className="grid gap-1">
            <Label htmlFor="pay-date">Date received</Label>
            <Input
              id="pay-date"
              type="date"
              max={today()}
              value={received}
              onChange={(e) => setReceived(e.target.value)}
            />
          </div>
          <div className="grid gap-1">
            <Label htmlFor="pay-note">Note (only you can see it)</Label>
            <Input id="pay-note" value={note} onChange={(e) => setNote(e.target.value)} />
          </div>
          <div className="grid gap-1">
            <Label htmlFor="pay-reason">Reason for recording (kept in the audit trail)</Label>
            <Textarea
              id="pay-reason"
              rows={2}
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder="e.g. Transfer seen on the 12 Oct bank statement"
            />
          </div>
          {formError && (
            <p className="text-sm text-destructive" role="alert" data-testid="payment-error">
              {formError}
            </p>
          )}
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={busy}>
            Cancel
          </Button>
          <Button onClick={() => void submit()} disabled={busy} data-testid="payment-submit">
            {busy ? "Recording…" : "Record payment"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function ReversePaymentDialog({
  payment,
  onClose,
  onDone,
}: {
  payment: InvoicePayment | null;
  onClose: () => void;
  onDone: () => Promise<void>;
}) {
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);
  useEffect(() => {
    setReason("");
    setFormError(null);
  }, [payment?.id]);

  const submit = async () => {
    if (!payment) return;
    if (reason.trim().length < 5) {
      setFormError("Give a reason of at least 5 characters.");
      return;
    }
    setBusy(true);
    try {
      await reversePayment(payment.id, reason.trim());
      toast.success("Payment reversed. Both records are kept.");
      await onDone();
    } catch (e) {
      setFormError(errText(e, "The payment could not be reversed."));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Dialog open={payment !== null} onOpenChange={(o) => !o && !busy && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Reverse this payment?</DialogTitle>
          <DialogDescription>
            {payment &&
              `${formatGHS(payment.amount)} (${PAYMENT_METHOD_LABELS[payment.method]}${payment.reference ? `, ${payment.reference}` : ""}) will be taken off the invoice. The payment record stays, with the reversal beside it.`}
          </DialogDescription>
        </DialogHeader>
        <div className="grid gap-1">
          <Label htmlFor="rev-reason">Reason (kept in the audit trail)</Label>
          <Textarea
            id="rev-reason"
            rows={2}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="e.g. The transfer was returned by the bank"
          />
        </div>
        {formError && (
          <p className="text-sm text-destructive" role="alert">
            {formError}
          </p>
        )}
        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={busy}>
            Keep the payment
          </Button>
          <Button
            variant="destructive"
            onClick={() => void submit()}
            disabled={busy}
            data-testid="reverse-submit"
          >
            {busy ? "Reversing…" : "Reverse payment"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/** How invoices are issued: payment terms, how long after a period ends, and who they come from and how to pay. */
function InvoiceSettingsCard() {
  const [settings, setSettings] = useState<InvoiceSettings | null>(null);
  const [terms, setTerms] = useState("14");
  const [delay, setDelay] = useState("24");
  const [issuer, setIssuer] = useState<Record<string, string>>({});
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const apply = (s: InvoiceSettings) => {
    setSettings(s);
    setTerms(String(s.payment_terms_days));
    setDelay(String(s.invoice_delay_hours));
    setIssuer(s.issuer ?? {});
  };
  useEffect(() => {
    fetchInvoiceSettings()
      .then(apply)
      .catch((e) => setError(errText(e, "Could not load the invoice settings.")));
  }, []);

  const save = async () => {
    setBusy(true);
    setError(null);
    try {
      const saved = await saveInvoiceSettings(
        { payment_terms_days: Number(terms), invoice_delay_hours: Number(delay), issuer },
        reason.trim(),
      );
      apply(saved);
      setReason("");
      toast.success("Invoice settings saved. New invoices will use them.");
    } catch (e) {
      setError(errText(e, "Could not save."));
    } finally {
      setBusy(false);
    }
  };

  if (!settings && !error) return <Skeleton className="h-24" />;
  return (
    <Card className="space-y-3 p-4" data-testid="invoice-settings">
      <div>
        <h3 className="font-semibold">Invoice settings</h3>
        <p className="text-xs text-muted-foreground">
          These apply to invoices issued from now on. An invoice keeps the details it was issued
          with.
        </p>
      </div>
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="grid gap-1">
          <Label htmlFor="set-terms">Days to pay an invoice</Label>
          <Input
            id="set-terms"
            inputMode="numeric"
            value={terms}
            onChange={(e) => setTerms(e.target.value)}
          />
        </div>
        <div className="grid gap-1">
          <Label htmlFor="set-delay">Hours after a period ends before it is invoiced</Label>
          <Input
            id="set-delay"
            inputMode="numeric"
            value={delay}
            onChange={(e) => setDelay(e.target.value)}
          />
        </div>
        {ISSUER_FIELDS.map((f) => (
          <div key={f.key} className={f.multiline ? "grid gap-1 sm:col-span-2" : "grid gap-1"}>
            <Label htmlFor={`set-${f.key}`}>{f.label}</Label>
            {f.multiline ? (
              <Textarea
                id={`set-${f.key}`}
                rows={2}
                value={issuer[f.key] ?? ""}
                onChange={(e) => setIssuer({ ...issuer, [f.key]: e.target.value })}
              />
            ) : (
              <Input
                id={`set-${f.key}`}
                value={issuer[f.key] ?? ""}
                onChange={(e) => setIssuer({ ...issuer, [f.key]: e.target.value })}
              />
            )}
          </div>
        ))}
        <div className="grid gap-1 sm:col-span-2">
          <Label htmlFor="set-reason">Reason for the change (kept in the audit trail)</Label>
          <Input id="set-reason" value={reason} onChange={(e) => setReason(e.target.value)} />
        </div>
      </div>
      {error && (
        <p className="text-sm text-destructive" role="alert">
          {error}
        </p>
      )}
      <Button onClick={() => void save()} disabled={busy || !settings} data-testid="settings-save">
        {busy ? "Saving…" : "Save invoice settings"}
      </Button>
    </Card>
  );
}
