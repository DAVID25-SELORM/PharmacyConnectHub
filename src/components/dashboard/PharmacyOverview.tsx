import {
  AlertTriangle,
  ClipboardList,
  FileQuestion,
  PackageX,
  ShoppingCart,
  Timer,
  Wallet,
} from "lucide-react";
import { useEffect, useState } from "react";
import { AccountsPanel } from "@/components/dashboard/AccountsPanel";
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
  inventoryCounts,
  overviewAging,
  overviewSummary,
  pharmacyDashboardAccess,
  rfqsClosingSoon,
  type AccountingOverview,
  type AttentionItem,
  type InventoryRow,
  type RfqLite,
} from "@/lib/dashboard";
import { formatGHS } from "@/lib/format";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

type Spend = { total: number; orders: number; points: TrendPoint[] };
type Section<T> = { state: "loading" } | { state: "error" } | { state: "ready"; data: T };
const loading = { state: "loading" } as const;

type RfqData = {
  open: number;
  quotesReceived: number;
  awaitingDecision: number;
  closingSoon: number;
};

/** The pharmacy dashboard body. Each section loads independently, so one failing query leaves a
 * gap rather than blanking the page, and a section a role can't see is never even requested
 * (the database would refuse it anyway -- this just avoids asking). */
export function PharmacyOverview({
  business,
  openOrders,
  awaitingReceipts,
  recentOrders,
}: {
  business: Business;
  openOrders: number;
  awaitingReceipts: number;
  recentOrders: React.ReactNode;
}) {
  const access = pharmacyDashboardAccess(business.staff_role);
  const [spend, setSpend] = useState<Section<Spend>>(loading);
  const [credit, setCredit] = useState<Section<AccountingOverview>>(loading);
  const [rfqs, setRfqs] = useState<Section<RfqData>>(loading);
  const [stock, setStock] = useState<Section<InventoryRow[]>>(loading);

  useEffect(() => {
    let cancelled = false;
    const run = <T,>(set: (s: Section<T>) => void, job: () => Promise<T>) => {
      set(loading);
      job().then(
        (data) => !cancelled && set({ state: "ready", data }),
        () => !cancelled && set({ state: "error" }),
      );
    };

    run(setSpend, async () => {
      const { data, error } = await db.rpc("pharmacy_report_overview", {
        p_business_id: business.id,
        p_range: "30d",
      });
      if (error) throw error;
      return {
        total: Number(data?.kpis?.total_purchases_ghs ?? 0),
        orders: Number(data?.kpis?.total_orders ?? 0),
        points: (
          (data?.series ?? []) as Array<{ bucket: string; orders: number; spend_ghs: number }>
        ).map((p) => ({
          bucket: p.bucket,
          orders: Number(p.orders),
          value: Number(p.spend_ghs),
        })),
      };
    });

    if (access.finance) {
      run(setCredit, async () => {
        const { data, error } = await db.rpc("accounting_overview", { p_business_id: business.id });
        if (error || !data) throw error ?? new Error("No overview");
        return data as AccountingOverview;
      });
    }

    if (access.rfq) {
      run(setRfqs, async () => {
        const { data: open, error } = await db
          .from("rfqs")
          .select("id, response_deadline")
          .eq("pharmacy_id", business.id)
          .eq("status", "open");
        if (error) throw error;
        const rows = (open ?? []) as RfqLite[];
        if (rows.length === 0)
          return { open: 0, quotesReceived: 0, awaitingDecision: 0, closingSoon: 0 };
        const { data: quotes, error: quoteError } = await db
          .from("rfq_quotes")
          .select("rfq_id")
          .in(
            "rfq_id",
            rows.map((r) => r.id),
          )
          .eq("status", "submitted");
        if (quoteError) throw quoteError;
        const quoted = (quotes ?? []) as Array<{ rfq_id: string }>;
        return {
          open: rows.length,
          quotesReceived: quoted.length,
          awaitingDecision: new Set(quoted.map((q) => q.rfq_id)).size,
          closingSoon: rfqsClosingSoon(rows),
        };
      });
    }

    if (access.inventory) {
      run(setStock, async () => {
        const { data, error } = await db
          .from("pharmacy_inventory_items")
          .select("stock, reorder_level, expiry_date")
          .eq("pharmacy_id", business.id)
          .eq("active", true)
          .limit(5000);
        if (error) throw error;
        return (data ?? []) as InventoryRow[];
      });
    }

    return () => {
      cancelled = true;
    };
  }, [business.id, access.finance, access.rfq, access.inventory]);

  const creditSummary = credit.state === "ready" ? overviewSummary(credit.data) : null;
  const stockCounts = stock.state === "ready" ? inventoryCounts(stock.data) : null;
  const rfqData = rfqs.state === "ready" ? rfqs.data : null;

  const attention: AttentionItem[] = [
    {
      key: "overdue",
      label: "Overdue supplier payments",
      detail: creditSummary ? `${formatGHS(creditSummary.overdueTotal)} past its due date` : "",
      count: creditSummary?.overdueCount ?? 0,
      tone: "danger",
      to: "/pharmacy/accounting",
    },
    {
      key: "due-soon",
      label: "Payments due this week",
      detail: creditSummary ? `${formatGHS(creditSummary.dueSoonTotal)} due within 7 days` : "",
      count: creditSummary?.dueSoonCount ?? 0,
      tone: "warning",
      to: "/pharmacy/accounting",
    },
    {
      key: "out-of-stock",
      label: "Out-of-stock items",
      detail: "Nothing on the shelf",
      count: stockCounts?.outOfStock ?? 0,
      tone: "danger",
      to: "/pharmacy/inventory",
      search: { filter: "low" },
    },
    {
      key: "low-stock",
      label: "Low-stock items",
      detail: "At or below their reorder level",
      count: stockCounts?.lowStock ?? 0,
      tone: "warning",
      to: "/pharmacy/inventory",
      search: { filter: "low" },
    },
    {
      key: "expiring",
      label: "Items expiring within 30 days",
      detail: "Including anything already expired",
      count: stockCounts?.expiringSoon ?? 0,
      tone: "warning",
      to: "/pharmacy/inventory",
      search: { filter: "expiring" },
    },
    {
      key: "quotes",
      label: "RFQs with quotes to review",
      detail: "Compare the quotes and award",
      count: rfqData?.awaitingDecision ?? 0,
      tone: "info",
      to: "/pharmacy/rfqs",
    },
    {
      key: "closing",
      label: "RFQs closing within 3 days",
      detail: "Responses are due soon",
      count: rfqData?.closingSoon ?? 0,
      tone: "warning",
      to: "/pharmacy/rfqs",
    },
    {
      key: "receipts",
      label: "Delivered orders awaiting a receipt",
      detail: "Send the receipt email",
      count: awaitingReceipts,
      tone: "info",
      to: "/pharmacy",
      search: { tab: "orders" },
    },
  ];

  const actions: ActionItem[] = [
    {
      title: "Place an order",
      description: "Compare verified wholesalers in the catalog.",
      to: "/pharmacy",
    },
    ...(access.rfq
      ? [
          {
            title: "Request quotes",
            description: "Ask suppliers to quote, or send to everyone eligible.",
            to: "/pharmacy/rfqs",
          },
        ]
      : []),
    ...(access.inventory
      ? [
          {
            title: "Add inventory item",
            description: "Track medicines, consumables, equipment and more.",
            to: "/pharmacy/inventory",
          },
          {
            title: "View low stock",
            description: "Items at or below their reorder level.",
            to: "/pharmacy/inventory",
            search: { filter: "low" },
          },
        ]
      : []),
    ...(access.finance
      ? [
          {
            title: "Open accounting",
            description: "Payables, aging, payments and statements.",
            to: "/pharmacy/accounting",
          },
        ]
      : []),
  ];

  // A section the role can't see is never requested, so it must not keep the list "loading".
  const attentionLoading =
    (access.finance && credit.state === "loading") ||
    (access.rfq && rfqs.state === "loading") ||
    (access.inventory && stock.state === "loading");

  return (
    <div className="space-y-8">
      <MetricGrid>
        <MetricCard
          label="Purchases, 30 days"
          value={spend.state === "ready" ? formatGHS(spend.data.total) : "—"}
          helper={
            spend.state === "ready"
              ? `${spend.data.orders} order${spend.data.orders === 1 ? "" : "s"}`
              : "Not available right now."
          }
          icon={<ShoppingCart className="h-4 w-4" />}
          to="/pharmacy/reports"
        />
        <MetricCard
          label="Open orders"
          value={String(openOrders)}
          helper="Still moving through fulfilment."
          icon={<ClipboardList className="h-4 w-4" />}
          to="/pharmacy"
          search={{ tab: "orders" }}
        />
        {access.rfq && (
          <>
            <MetricCard
              label="RFQs awaiting responses"
              value={rfqData ? String(rfqData.open) : "—"}
              helper="Open requests for quotation."
              icon={<FileQuestion className="h-4 w-4" />}
              to="/pharmacy/rfqs"
            />
            <MetricCard
              label="Quotations received"
              value={rfqData ? String(rfqData.quotesReceived) : "—"}
              helper="Submitted on your open RFQs."
              icon={<FileQuestion className="h-4 w-4" />}
              tone={rfqData && rfqData.quotesReceived > 0 ? "info" : undefined}
              to="/pharmacy/rfqs"
            />
          </>
        )}
        {access.inventory && (
          <>
            <MetricCard
              label="Low stock"
              value={stockCounts ? String(stockCounts.lowStock) : "—"}
              helper={
                stockCounts ? `${stockCounts.outOfStock} out of stock` : "Not available right now."
              }
              icon={<PackageX className="h-4 w-4" />}
              tone={
                stockCounts && stockCounts.lowStock + stockCounts.outOfStock > 0
                  ? "warning"
                  : undefined
              }
              to="/pharmacy/inventory"
              search={{ filter: "low" }}
            />
            <MetricCard
              label="Expiring soon"
              value={stockCounts ? String(stockCounts.expiringSoon) : "—"}
              helper="Within 30 days, or already expired."
              icon={<Timer className="h-4 w-4" />}
              tone={stockCounts && stockCounts.expiringSoon > 0 ? "warning" : undefined}
              to="/pharmacy/inventory"
              search={{ filter: "expiring" }}
            />
          </>
        )}
        {access.finance && (
          <>
            <MetricCard
              label="Credit outstanding"
              value={creditSummary ? formatGHS(creditSummary.outstanding) : "—"}
              helper={
                creditSummary
                  ? `${creditSummary.invoiceCount} unpaid invoice${creditSummary.invoiceCount === 1 ? "" : "s"}`
                  : "Not available right now."
              }
              icon={<Wallet className="h-4 w-4" />}
              to="/pharmacy/accounting"
            />
            <MetricCard
              label="Overdue invoices"
              value={creditSummary ? String(creditSummary.overdueCount) : "—"}
              helper={
                creditSummary ? formatGHS(creditSummary.overdueTotal) : "Not available right now."
              }
              icon={<AlertTriangle className="h-4 w-4" />}
              tone={creditSummary && creditSummary.overdueCount > 0 ? "danger" : undefined}
              to="/pharmacy/accounting"
            />
          </>
        )}
      </MetricGrid>

      <div className="grid gap-6 lg:grid-cols-[1.4fr,0.9fr]">
        <NeedsAttentionCard items={attention} loading={attentionLoading} />
        <ActionsCard items={actions} />
      </div>

      <div className={`grid gap-6 ${access.finance ? "lg:grid-cols-2" : ""}`}>
        <ReportTrendChart
          title="Purchases over the last 30 days"
          valueLabel="Spend (GHS)"
          points={spend.state === "ready" ? spend.data.points : []}
          loading={spend.state === "loading"}
        />
        {access.finance && (
          <AgingChart
            title="Credit owed, by how late"
            buckets={overviewAging(credit.state === "ready" ? credit.data : null)}
            loading={credit.state === "loading"}
          />
        )}
      </div>

      {access.finance && (
        <AccountsPanel
          side="pharmacy"
          overview={credit.state === "ready" ? credit.data : null}
          loading={credit.state === "loading"}
          failed={credit.state === "error"}
        />
      )}

      <div className={`grid gap-6 ${access.activity ? "lg:grid-cols-[1.4fr,0.9fr]" : ""}`}>
        {recentOrders}
        {access.activity && (
          <RecentActivityCard businessId={business.id} auditPath="/pharmacy/audit" />
        )}
      </div>
    </div>
  );
}
