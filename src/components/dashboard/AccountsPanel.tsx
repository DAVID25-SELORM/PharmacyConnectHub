import { Link } from "@tanstack/react-router";
import { ArrowRight } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import type { AccountingOverview } from "@/lib/dashboard";
import { formatGHS } from "@/lib/format";

type Side = "wholesaler" | "pharmacy";

const COPY: Record<
  Side,
  {
    title: string;
    to: "/wholesaler/accounting" | "/pharmacy/accounting";
    payments: string;
    topTitle: string;
    nothing: string;
  }
> = {
  wholesaler: {
    title: "Accounts receivable",
    to: "/wholesaler/accounting",
    payments: "Payments received, last 30 days",
    topTitle: "Pharmacies with the most overdue",
    nothing: "No pharmacy is overdue.",
  },
  pharmacy: {
    title: "Accounts payable",
    to: "/pharmacy/accounting",
    payments: "Payments made, last 30 days",
    topTitle: "Suppliers you owe the most overdue",
    nothing: "Nothing you owe is overdue.",
  },
};

function Stat({ label, value, helper }: { label: string; value: string; helper?: string }) {
  return (
    <div className="rounded-xl border border-border p-3">
      <div className="text-xs text-muted-foreground">{label}</div>
      <div className="mt-1 font-display text-lg font-bold">{value}</div>
      {helper && <div className="mt-0.5 text-xs text-muted-foreground">{helper}</div>}
    </div>
  );
}

const plural = (count: number, one: string, many: string) => `${count} ${count === 1 ? one : many}`;

/** The finance roles' view of the books: who is most overdue, what was paid recently, what is
 * sitting unmatched on account. Every figure comes from accounting_overview(). */
export function AccountsPanel({
  side,
  overview,
  loading,
  failed,
}: {
  side: Side;
  overview: AccountingOverview | null;
  loading: boolean;
  failed: boolean;
}) {
  const copy = COPY[side];
  return (
    <Card className="p-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="text-sm font-semibold">{copy.title}</div>
        <Button asChild variant="outline" size="sm">
          <Link to={copy.to}>
            Open accounting
            <ArrowRight className="ml-1 h-4 w-4" aria-hidden="true" />
          </Link>
        </Button>
      </div>

      {loading ? (
        <div
          className="mt-4 h-40 animate-pulse rounded-lg bg-muted"
          role="status"
          aria-label="Loading accounts"
        />
      ) : failed || !overview ? (
        <p className="mt-4 rounded-xl border border-dashed border-border p-6 text-center text-sm text-muted-foreground">
          Not available right now.
        </p>
      ) : (
        <div className="mt-4 grid gap-4 lg:grid-cols-[1.3fr,1fr]">
          <div>
            <div className="text-xs uppercase tracking-wider text-muted-foreground">
              {copy.topTitle}
            </div>
            {overview.top_overdue.length === 0 ? (
              <p className="mt-2 rounded-xl border border-dashed border-border p-4 text-sm text-muted-foreground">
                {copy.nothing}
              </p>
            ) : (
              <ul className="mt-2 divide-y divide-border rounded-xl border border-border">
                {overview.top_overdue.map((row) => (
                  <li
                    key={row.counterparty_id}
                    className="flex flex-wrap items-center justify-between gap-2 px-3 py-2.5 text-sm"
                  >
                    <div>
                      <div className="font-medium">{row.counterparty_name}</div>
                      <div className="text-xs text-muted-foreground">
                        {plural(Number(row.invoices), "invoice", "invoices")} · oldest{" "}
                        {Number(row.oldest_days_overdue)} days overdue
                      </div>
                    </div>
                    <div className="font-semibold">{formatGHS(Number(row.overdue_ghs))}</div>
                  </li>
                ))}
              </ul>
            )}
          </div>
          <div className="grid grid-cols-2 gap-3 lg:grid-cols-1">
            <Stat
              label={copy.payments}
              value={formatGHS(Number(overview.payments_30d.total_ghs))}
              helper={plural(Number(overview.payments_30d.count), "payment", "payments")}
            />
            <Stat
              label="Paid on account, not matched to an invoice"
              value={formatGHS(Number(overview.on_account.total_ghs))}
              helper={
                Number(overview.on_account.parties) > 0
                  ? plural(Number(overview.on_account.parties), "account", "accounts")
                  : "Nothing waiting to be matched."
              }
            />
            {Number(overview.disputed_count) > 0 && (
              <Stat
                label="In dispute"
                value={formatGHS(Number(overview.disputed_ghs))}
                helper={plural(Number(overview.disputed_count), "invoice", "invoices")}
              />
            )}
          </div>
        </div>
      )}
    </Card>
  );
}
