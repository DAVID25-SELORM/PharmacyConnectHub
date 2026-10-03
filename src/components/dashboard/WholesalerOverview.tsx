import { AlertTriangle, FileQuestion, Receipt, TrendingUp, Wallet } from "lucide-react";
import { useEffect, useState } from "react";
import {
  ActionsCard,
  AgingChart,
  MetricCard,
  MetricGrid,
  NeedsAttentionCard,
  RecentActivityCard,
  type ActionItem,
} from "@/components/dashboard/OverviewParts";
import { ReportTrendChart, type TrendPoint } from "@/components/reports/ReportTrendChart";
import type { Business } from "@/hooks/use-session";
import { supabase } from "@/integrations/supabase/client";
import {
  agingBuckets,
  summariseCredit,
  wholesalerDashboardAccess,
  type AttentionItem,
  type CreditInvoiceRow,
} from "@/lib/dashboard";
import { formatGHS } from "@/lib/format";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

type Sales = { total: number; orders: number; points: TrendPoint[] };
type Section<T> = { state: "loading" } | { state: "error" } | { state: "ready"; data: T };
const loading = { state: "loading" } as const;

/** The wholesaler dashboard body. Sections load independently so one failure leaves a gap, not a
 * blank page; sections a staff role can't see are never requested. */
export function WholesalerOverview({
  business,
  pendingOrders,
  lowStockSkus,
  awaitingPayment,
  summaryCards,
  recentOrders,
}: {
  business: Business;
  pendingOrders: number;
  lowStockSkus: number;
  awaitingPayment: number;
  /** The existing order/catalogue stat cards, kept as they were. */
  summaryCards: React.ReactNode;
  recentOrders: React.ReactNode;
}) {
  const access = wholesalerDashboardAccess(business.staff_role);
  const [sales, setSales] = useState<Section<Sales>>(loading);
  const [credit, setCredit] = useState<Section<CreditInvoiceRow[]>>(loading);
  const [rfqs, setRfqs] = useState<Section<number>>(loading);

  useEffect(() => {
    let cancelled = false;
    const run = <T,>(set: (s: Section<T>) => void, job: () => Promise<T>) => {
      set(loading);
      job().then(
        (data) => !cancelled && set({ state: "ready", data }),
        () => !cancelled && set({ state: "error" }),
      );
    };

    if (access.finance) {
      run(setSales, async () => {
        const { data, error } = await db.rpc("wholesaler_report_overview", {
          p_business_id: business.id,
          p_range: "30d",
        });
        if (error) throw error;
        return {
          total: Number(data?.kpis?.total_sales_ghs ?? 0),
          orders: Number(data?.kpis?.total_orders ?? 0),
          points: (
            (data?.series ?? []) as Array<{ bucket: string; orders: number; sales_ghs: number }>
          ).map((p) => ({
            bucket: p.bucket,
            orders: Number(p.orders),
            value: Number(p.sales_ghs),
          })),
        };
      });
      run(setCredit, async () => {
        const { data, error } = await db.rpc("list_credit_invoices", {
          p_wholesaler_id: business.id,
          p_status: "outstanding",
        });
        if (error) throw error;
        return (data ?? []) as CreditInvoiceRow[];
      });
    }

    if (access.rfq) {
      run(setRfqs, async () => {
        const { data: invites, error } = await db
          .from("rfq_invitees")
          .select("rfq_id")
          .eq("wholesaler_id", business.id);
        if (error) throw error;
        const ids = ((invites ?? []) as Array<{ rfq_id: string }>).map((i) => i.rfq_id);
        if (ids.length === 0) return 0;
        const [{ data: open, error: openError }, { data: mine, error: quoteError }] =
          await Promise.all([
            db.from("rfqs").select("id").in("id", ids).eq("status", "open"),
            db
              .from("rfq_quotes")
              .select("rfq_id")
              .in("rfq_id", ids)
              .eq("wholesaler_id", business.id)
              .neq("status", "withdrawn"),
          ]);
        if (openError || quoteError) throw openError ?? quoteError;
        const quoted = new Set(((mine ?? []) as Array<{ rfq_id: string }>).map((q) => q.rfq_id));
        return ((open ?? []) as Array<{ id: string }>).filter((r) => !quoted.has(r.id)).length;
      });
    }

    return () => {
      cancelled = true;
    };
  }, [business.id, access.finance, access.rfq]);

  const creditSummary = credit.state === "ready" ? summariseCredit(credit.data) : null;
  const awaitingQuote = rfqs.state === "ready" ? rfqs.data : null;

  const attention: AttentionItem[] = [
    {
      key: "overdue",
      label: "Overdue receivables",
      detail: creditSummary
        ? `${formatGHS(creditSummary.overdueTotal)} owed past the due date`
        : "",
      count: creditSummary?.overdueCount ?? 0,
      tone: "danger",
      to: "/wholesaler",
      search: { tab: "credit" },
    },
    {
      key: "pending",
      label: "New orders waiting for action",
      detail: "Confirm or decline them",
      count: pendingOrders,
      tone: "warning",
      to: "/wholesaler",
      search: { tab: "orders" },
    },
    {
      key: "awaiting-payment",
      label: "Delivered COD orders awaiting payment",
      detail: "Confirm payment when received",
      count: awaitingPayment,
      tone: "warning",
      to: "/wholesaler",
      search: { tab: "orders" },
    },
    {
      key: "due-soon",
      label: "Receivables due this week",
      detail: creditSummary ? `${formatGHS(creditSummary.dueSoonTotal)} due within 7 days` : "",
      count: creditSummary?.dueSoonCount ?? 0,
      tone: "info",
      to: "/wholesaler",
      search: { tab: "credit" },
    },
    {
      key: "rfqs",
      label: "RFQs awaiting your quote",
      detail: "Pharmacies are waiting for a response",
      count: awaitingQuote ?? 0,
      tone: "info",
      to: "/wholesaler/rfqs",
    },
    ...(access.inventory
      ? [
          {
            key: "low-stock",
            label: "Low-stock products",
            detail: "Active items below 100 units",
            count: lowStockSkus,
            tone: "warning" as const,
            to: "/wholesaler",
            search: { tab: "insights" },
          },
        ]
      : []),
  ];

  const actions: ActionItem[] = [
    {
      title: "Open workspace",
      description: "Process orders, confirm payments, and manage products.",
      to: "/wholesaler",
    },
    ...(access.rfq
      ? [
          {
            title: "Respond to RFQs",
            description: "Quote on requests from pharmacies.",
            to: "/wholesaler/rfqs",
          },
        ]
      : []),
    ...(access.finance
      ? [
          {
            title: "View receivables",
            description: "Credit balances owed by pharmacies.",
            to: "/wholesaler",
            search: { tab: "credit" },
          },
        ]
      : []),
  ];

  // A section the role can't see is never requested, so it must not keep the list "loading".
  const attentionLoading =
    (access.finance && credit.state === "loading") || (access.rfq && rfqs.state === "loading");

  return (
    <div className="space-y-8">
      <MetricGrid>
        {access.finance && (
          <>
            <MetricCard
              label="Sales, 30 days"
              value={sales.state === "ready" ? formatGHS(sales.data.total) : "—"}
              helper={
                sales.state === "ready"
                  ? `${sales.data.orders} order${sales.data.orders === 1 ? "" : "s"}`
                  : "Not available right now."
              }
              icon={<TrendingUp className="h-4 w-4" />}
              to="/wholesaler/reports"
            />
            <MetricCard
              label="Receivables outstanding"
              value={creditSummary ? formatGHS(creditSummary.outstanding) : "—"}
              helper={
                creditSummary
                  ? `${creditSummary.invoiceCount} unpaid invoice${creditSummary.invoiceCount === 1 ? "" : "s"}`
                  : "Not available right now."
              }
              icon={<Wallet className="h-4 w-4" />}
              to="/wholesaler"
              search={{ tab: "credit" }}
            />
            <MetricCard
              label="Overdue receivables"
              value={creditSummary ? String(creditSummary.overdueCount) : "—"}
              helper={
                creditSummary ? formatGHS(creditSummary.overdueTotal) : "Not available right now."
              }
              icon={<AlertTriangle className="h-4 w-4" />}
              tone={creditSummary && creditSummary.overdueCount > 0 ? "danger" : undefined}
              to="/wholesaler"
              search={{ tab: "credit" }}
            />
          </>
        )}
        {access.rfq && (
          <MetricCard
            label="RFQs awaiting your quote"
            value={awaitingQuote !== null ? String(awaitingQuote) : "—"}
            helper="Open requests you haven't quoted on."
            icon={<FileQuestion className="h-4 w-4" />}
            tone={awaitingQuote ? "info" : undefined}
            to="/wholesaler/rfqs"
          />
        )}
        <MetricCard
          label="Pending orders"
          value={String(pendingOrders)}
          helper="New orders waiting for action."
          icon={<Receipt className="h-4 w-4" />}
          tone={pendingOrders > 0 ? "warning" : undefined}
          to="/wholesaler"
          search={{ tab: "orders" }}
        />
      </MetricGrid>

      {summaryCards}

      <div className="grid gap-6 lg:grid-cols-[1.4fr,0.9fr]">
        <NeedsAttentionCard items={attention} loading={attentionLoading} />
        <ActionsCard items={actions} />
      </div>

      {access.finance && (
        <div className="grid gap-6 lg:grid-cols-2">
          <ReportTrendChart
            title="Sales over the last 30 days"
            valueLabel="Sales (GHS)"
            points={sales.state === "ready" ? sales.data.points : []}
            loading={sales.state === "loading"}
          />
          <AgingChart
            title="Receivables, by how late"
            buckets={credit.state === "ready" ? agingBuckets(credit.data) : agingBuckets([])}
            loading={credit.state === "loading"}
          />
        </div>
      )}

      <div className={`grid gap-6 ${access.activity ? "lg:grid-cols-[1.4fr,0.9fr]" : ""}`}>
        {recentOrders}
        {access.activity && (
          <RecentActivityCard businessId={business.id} auditPath="/wholesaler/audit" />
        )}
      </div>
    </div>
  );
}
