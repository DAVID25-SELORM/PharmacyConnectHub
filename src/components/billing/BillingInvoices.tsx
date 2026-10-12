import { useCallback, useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
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
import { formatGHS } from "@/lib/format";
import { periodLabel } from "@/lib/billing";
import {
  dateText,
  dueText,
  fetchMyInvoice,
  fetchMyInvoices,
  describePayment,
  type InvoiceDetail,
  type MyInvoices,
} from "@/lib/billing-invoices";
import { InvoiceDetailView, InvoiceStatusBadge } from "./InvoiceDetailView";

const PAGE = 12;

/** A business's invoices and payment history. Real invoices only; nothing here can change anything. */
export function BillingInvoices({ businessId }: { businessId: string }) {
  const [data, setData] = useState<MyInvoices | null>(null);
  const [limit, setLimit] = useState(PAGE);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState<{ id: string; number: string } | null>(null);
  const [detail, setDetail] = useState<InvoiceDetail | null>(null);
  const [detailError, setDetailError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setData(await fetchMyInvoices(businessId, limit, 0));
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not load your invoices.");
    }
  }, [businessId, limit]);
  useEffect(() => {
    void load();
  }, [load]);

  useEffect(() => {
    if (!open) return;
    setDetail(null);
    setDetailError(null);
    fetchMyInvoice(open.id)
      .then(setDetail)
      .catch((e) =>
        setDetailError(e instanceof Error ? e.message : "Could not open this invoice."),
      );
  }, [open]);

  if (error) {
    return (
      <Card className="border-destructive/40 p-4 text-sm text-destructive" role="alert">
        {error}
      </Card>
    );
  }
  if (!data) return <Skeleton className="h-32" />;
  if (data.count === 0) return null;

  return (
    <Card className="space-y-4 p-4" data-testid="billing-invoices">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h3 className="font-semibold">Invoices</h3>
        <div className="flex flex-wrap gap-4 text-sm">
          <span>
            Balance to pay:{" "}
            <span className="font-semibold" data-testid="invoices-outstanding">
              {formatGHS(data.outstanding_total)}
            </span>
          </span>
          {data.overdue_total > 0 && (
            <span className="text-destructive">
              Overdue:{" "}
              <span className="font-semibold" data-testid="invoices-overdue">
                {formatGHS(data.overdue_total)}
              </span>
            </span>
          )}
          {data.credit_available > 0 && (
            <span className="text-success">
              Credit available:{" "}
              <span className="font-semibold">{formatGHS(data.credit_available)}</span>
            </span>
          )}
        </div>
      </div>

      <div className="overflow-x-auto">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Invoice</TableHead>
              <TableHead>Period</TableHead>
              <TableHead>Due</TableHead>
              <TableHead className="text-right">Total</TableHead>
              <TableHead className="text-right">Balance</TableHead>
              <TableHead>Status</TableHead>
              <TableHead />
            </TableRow>
          </TableHeader>
          <TableBody>
            {data.invoices.map((i) => (
              <TableRow key={i.id} data-testid="invoice-row">
                <TableCell className="whitespace-nowrap font-medium">{i.invoice_number}</TableCell>
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
                <TableCell className="text-right">
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => setOpen({ id: i.id, number: i.invoice_number })}
                  >
                    View
                  </Button>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
      {data.count > data.invoices.length && (
        <Button variant="ghost" size="sm" onClick={() => setLimit((n) => n + PAGE)}>
          Show older invoices
        </Button>
      )}

      {data.payments.length > 0 && (
        <section className="space-y-2" data-testid="payment-history">
          <h4 className="text-sm font-semibold">Payment history</h4>
          <div className="overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Received</TableHead>
                  <TableHead>Invoice</TableHead>
                  <TableHead>Method</TableHead>
                  <TableHead>Reference</TableHead>
                  <TableHead className="text-right">Amount</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {data.payments.map((p) => (
                  <TableRow key={p.id}>
                    <TableCell className="whitespace-nowrap">{dateText(p.received_at)}</TableCell>
                    <TableCell className="whitespace-nowrap">{p.invoice_number}</TableCell>
                    <TableCell>
                      {describePayment({ kind: p.kind, method: p.method, reversed: false })}
                    </TableCell>
                    <TableCell>{p.reference ?? "–"}</TableCell>
                    <TableCell className="text-right">
                      {p.kind === "reversal" ? `− ${formatGHS(p.amount)}` : formatGHS(p.amount)}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </section>
      )}

      <Sheet open={open !== null} onOpenChange={(o) => !o && setOpen(null)}>
        <SheetContent className="w-full overflow-y-auto sm:max-w-2xl">
          <SheetHeader>
            <SheetTitle>{open?.number ?? "Invoice"}</SheetTitle>
            <SheetDescription>Your bill from DrugXOne for one billing period.</SheetDescription>
          </SheetHeader>
          <div className="mt-4">
            {detailError && (
              <p className="text-sm text-destructive" role="alert">
                {detailError}
              </p>
            )}
            {!detail && !detailError && <Skeleton className="h-40" />}
            {detail && <InvoiceDetailView inv={detail} />}
          </div>
        </SheetContent>
      </Sheet>
    </Card>
  );
}
