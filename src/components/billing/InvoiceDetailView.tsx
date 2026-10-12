import { Download } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { formatGHS } from "@/lib/format";
import { describeBilledOrder } from "@/lib/billing";
import { buildBillingInvoicePdf, invoiceFileName } from "@/lib/billing-invoice-pdf";
import {
  INVOICE_STATUS_LABELS,
  INVOICE_STATUS_TONE,
  dateText,
  describePayment,
  dueText,
  type InvoiceDetail,
  type InvoicePayment,
  type InvoiceStatus,
} from "@/lib/billing-invoices";

export function InvoiceStatusBadge({ status }: { status: InvoiceStatus }) {
  return (
    <Badge variant="outline" className={INVOICE_STATUS_TONE[status]} data-testid="invoice-status">
      {INVOICE_STATUS_LABELS[status]}
    </Badge>
  );
}

/** One invoice in full: what it is for, what is owed, what has been paid, and how to pay. Used by a business and by an administrator (who also sees the notes and can reverse a payment). */
export function InvoiceDetailView({
  inv,
  admin = false,
  onReverse,
}: {
  inv: InvoiceDetail;
  admin?: boolean;
  onReverse?: (payment: InvoicePayment) => void;
}) {
  const summary = inv.summary ?? {};
  const isWholesaler = inv.business_type === "wholesaler";
  const download = () => {
    buildBillingInvoicePdf(inv).save(invoiceFileName(inv));
  };
  return (
    <div className="space-y-5 pb-6" data-testid="invoice-detail">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="space-y-1">
          <div className="flex items-center gap-2">
            <span className="font-display text-lg font-bold" data-testid="invoice-number">
              {inv.invoice_number}
            </span>
            <InvoiceStatusBadge status={inv.status} />
          </div>
          <div className="text-sm text-muted-foreground">
            {summary.period_label ?? `${dateText(inv.period_start)} – ${dateText(inv.period_end)}`}
            {" · "}
            Issued {dateText(inv.issued_at)} · Due {dateText(inv.due_at)}
            {" · "}
            <span data-testid="invoice-due-text">{dueText(inv)}</span>
          </div>
          <div className="text-sm">
            {inv.business_name}
            {inv.customer?.license_number ? ` · Licence ${inv.customer.license_number}` : ""}
          </div>
        </div>
        <Button variant="outline" size="sm" onClick={download} data-testid="invoice-download">
          <Download className="mr-1 h-4 w-4" aria-hidden="true" />
          Download PDF
        </Button>
      </div>

      <div className="overflow-x-auto rounded-md border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>What this bill is for</TableHead>
              <TableHead className="text-right">Amount</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {inv.lines.map((l) => (
              <TableRow key={l.line_no}>
                <TableCell>{l.description}</TableCell>
                <TableCell className="text-right">
                  {l.amount < 0 ? `− ${formatGHS(-l.amount)}` : formatGHS(l.amount)}
                </TableCell>
              </TableRow>
            ))}
            <TableRow className="font-semibold">
              <TableCell>Total</TableCell>
              <TableCell className="text-right" data-testid="invoice-total">
                {formatGHS(inv.total_amount)}
              </TableCell>
            </TableRow>
            <TableRow>
              <TableCell>Paid</TableCell>
              <TableCell className="text-right">{formatGHS(inv.amount_paid)}</TableCell>
            </TableRow>
            <TableRow className="font-semibold">
              <TableCell>Balance to pay</TableCell>
              <TableCell className="text-right" data-testid="invoice-balance">
                {formatGHS(inv.outstanding_amount)}
              </TableCell>
            </TableRow>
          </TableBody>
        </Table>
      </div>

      {isWholesaler && (summary.eligible_orders ?? 0) > 0 && (
        <p className="text-sm text-muted-foreground" data-testid="invoice-summary">
          {summary.eligible_orders} eligible {summary.eligible_orders === 1 ? "order" : "orders"} (
          {summary.free_onboarding_orders ?? 0} launch free, {summary.free_monthly_orders ?? 0}{" "}
          monthly free, {summary.chargeable_orders ?? 0} charged) on{" "}
          {formatGHS(summary.billable_gmv ?? 0)} of eligible sales.
        </p>
      )}

      {inv.status !== "paid" && inv.issuer?.payment_instructions && (
        <div className="rounded-md border bg-muted/40 p-3 text-sm" data-testid="invoice-how-to-pay">
          <div className="font-medium">How to pay</div>
          <p className="mt-1 whitespace-pre-line text-muted-foreground">
            {inv.issuer.payment_instructions}
          </p>
          <p className="mt-1 text-muted-foreground">
            Please quote <span className="font-medium text-foreground">{inv.invoice_number}</span>.
          </p>
        </div>
      )}

      <section className="space-y-2">
        <h4 className="font-semibold">Payments</h4>
        {inv.payments.length === 0 ? (
          <p className="text-sm text-muted-foreground" data-testid="invoice-no-payments">
            No payment has been recorded for this invoice yet.
          </p>
        ) : (
          <div className="overflow-x-auto rounded-md border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Received</TableHead>
                  <TableHead>Method</TableHead>
                  <TableHead>Reference</TableHead>
                  <TableHead className="text-right">Amount</TableHead>
                  {admin && <TableHead>Recorded by</TableHead>}
                  {admin && <TableHead />}
                </TableRow>
              </TableHeader>
              <TableBody>
                {inv.payments.map((p) => (
                  <TableRow key={p.id} data-testid="invoice-payment">
                    <TableCell className="whitespace-nowrap">{dateText(p.received_at)}</TableCell>
                    <TableCell>
                      {describePayment(p)}
                      {p.kind === "reversal" && p.reason && (
                        <span className="block text-xs text-muted-foreground">{p.reason}</span>
                      )}
                      {admin && p.note && (
                        <span className="block text-xs text-muted-foreground">{p.note}</span>
                      )}
                    </TableCell>
                    <TableCell>{p.reference ?? "–"}</TableCell>
                    <TableCell className="text-right">
                      {p.kind === "reversal" ? `− ${formatGHS(p.amount)}` : formatGHS(p.amount)}
                    </TableCell>
                    {admin && (
                      <TableCell className="text-xs">{p.recorded_by_email ?? "–"}</TableCell>
                    )}
                    {admin && (
                      <TableCell className="text-right">
                        {p.kind === "payment" && !p.reversed && onReverse && (
                          <Button
                            variant="ghost"
                            size="sm"
                            onClick={() => onReverse(p)}
                            data-testid="reverse-payment"
                          >
                            Reverse
                          </Button>
                        )}
                      </TableCell>
                    )}
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </section>

      {isWholesaler && inv.orders.length > 0 && (
        <section className="space-y-2">
          <h4 className="font-semibold">Orders billed in this period</h4>
          <div className="overflow-x-auto rounded-md border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Order</TableHead>
                  <TableHead>How it was billed</TableHead>
                  <TableHead className="text-right">Eligible sales</TableHead>
                  <TableHead className="text-right">Charged</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {inv.orders.map((o, i) => (
                  <TableRow key={`${o.order_number}-${o.kind}-${o.adjustment_seq}-${i}`}>
                    <TableCell className="whitespace-nowrap">{o.order_number}</TableCell>
                    <TableCell>{describeBilledOrder(o, formatGHS)}</TableCell>
                    <TableCell className="text-right">{formatGHS(o.billable_gmv)}</TableCell>
                    <TableCell className="text-right">{formatGHS(o.charged_amount)}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </section>
      )}
    </div>
  );
}
