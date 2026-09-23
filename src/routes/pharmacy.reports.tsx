import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useRef, useState } from "react";
import { ChevronLeft, ChevronRight, FileText, ShieldCheck, Wallet } from "lucide-react";
import { WorkspaceGate } from "@/components/WorkspaceGate";
import { DashboardHeader } from "@/components/DashboardShell";
import { ReportKpis, type ReportKpi } from "@/components/reports/ReportKpis";
import { ReportsHeader } from "@/components/reports/ReportsHeader";
import { ReportTable, type ReportColumn } from "@/components/reports/ReportTable";
import { ReportTrendChart, type TrendPoint } from "@/components/reports/ReportTrendChart";
import { Button } from "@/components/ui/button";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useKeysetPager, type KeysetCursor } from "@/hooks/use-keyset-pager";
import { useReportRange } from "@/hooks/use-report-range";
import { useSession } from "@/hooks/use-session";
import { supabase } from "@/integrations/supabase/client";
import {
  downloadCsv,
  formatGHSCell,
  formatReportDate,
  formatReportDateTime,
  rangeToRpcArgs,
  reportFilename,
  rowsToCsv,
  type ReportRangeState,
} from "@/lib/reports";

export const Route = createFileRoute("/pharmacy/reports")({
  head: () => ({ meta: [{ title: "Reports - Drugxone" }] }),
  component: () => (
    <WorkspaceGate>
      <PharmacyReportsPage />
    </WorkspaceGate>
  ),
});

type Overview = {
  kpis: {
    total_purchases_ghs: number;
    total_orders: number;
    delivered_orders: number;
    outstanding_orders: number;
    total_discount_ghs: number;
    avg_order_value_ghs: number;
  };
  series: Array<{ bucket: string; orders: number; spend_ghs: number }>;
};

type OrderRow = {
  id: string;
  order_number: string;
  created_at: string;
  wholesaler_id: string;
  wholesaler_name: string;
  item_count: number;
  subtotal_ghs: number;
  discount_amount_ghs: number;
  total_ghs: number;
  status: string;
  payment_status: string;
  payment_method: string;
};

type SupplierRow = {
  wholesaler_id: string;
  wholesaler_name: string;
  orders: number;
  spend_ghs: number;
  avg_order_value_ghs: number;
  discount_ghs: number;
  last_order_at: string | null;
};

type ExportRef = React.MutableRefObject<() => void>;

function PharmacyReportsPage() {
  const { business } = useSession();
  const { draft, setDraft, applied, apply, reset } = useReportRange();
  const [tab, setTab] = useState("overview");
  const exportRef = useRef<() => void>(() => undefined);

  if (!business) return null;

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="Reports" showNav={true} />
      <main className="mx-auto max-w-7xl px-4 py-8 sm:px-6 lg:px-8">
        <ReportsHeader
          title="Reports"
          subtitle="Analyze performance, transactions and operational activity."
          draft={draft}
          onDraftChange={setDraft}
          onApply={apply}
          onReset={reset}
          onExportCsv={() => exportRef.current()}
        />

        <Tabs value={tab} onValueChange={setTab} className="mt-6">
          <TabsList className="mb-4 flex-wrap">
            <TabsTrigger value="overview">Overview</TabsTrigger>
            <TabsTrigger value="orders">Orders &amp; Payments</TabsTrigger>
            <TabsTrigger value="suppliers">Suppliers</TabsTrigger>
          </TabsList>

          <TabsContent value="overview">
            <OverviewTab businessId={business.id} range={applied} exportRef={exportRef} />
          </TabsContent>
          <TabsContent value="orders">
            <OrdersTab businessId={business.id} range={applied} exportRef={exportRef} />
          </TabsContent>
          <TabsContent value="suppliers">
            <SuppliersTab businessId={business.id} range={applied} exportRef={exportRef} />
          </TabsContent>
        </Tabs>
      </main>
    </div>
  );
}

function OverviewTab({
  businessId,
  range,
  exportRef,
}: {
  businessId: string;
  range: ReportRangeState;
  exportRef: ExportRef;
}) {
  const [data, setData] = useState<Overview | null>(null);
  const [error, setError] = useState(false);

  useEffect(() => {
    setData(null);
    setError(false);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    void (supabase as any)
      .rpc("pharmacy_report_overview", { p_business_id: businessId, ...rangeToRpcArgs(range) })
      .then(({ data: result, error: rpcError }: { data: Overview; error: unknown }) => {
        if (rpcError) return setError(true);
        setData(result);
      });
  }, [businessId, range.range, range.from, range.to]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    exportRef.current = () => {
      if (!data) return;
      downloadCsv(
        reportFilename("pharmacy-overview"),
        rowsToCsv(
          ["Metric", "Value"],
          [
            ["Total purchases (GHS)", data.kpis.total_purchases_ghs],
            ["Total orders", data.kpis.total_orders],
            ["Delivered orders", data.kpis.delivered_orders],
            ["Outstanding orders", data.kpis.outstanding_orders],
            ["Total discounts (GHS)", data.kpis.total_discount_ghs],
            ["Avg order value (GHS)", data.kpis.avg_order_value_ghs],
          ],
        ),
      );
    };
  }, [data, exportRef]);

  const kpis: ReportKpi[] = [
    {
      label: "Total Purchases",
      value: data ? formatGHSCell(data.kpis.total_purchases_ghs) : "—",
      icon: <Wallet className="h-4 w-4 text-primary" />,
    },
    {
      label: "Total Orders",
      value: data ? String(data.kpis.total_orders) : "—",
      icon: <FileText className="h-4 w-4 text-muted-foreground" />,
    },
    { label: "Delivered Orders", value: data ? String(data.kpis.delivered_orders) : "—" },
    { label: "Outstanding Orders", value: data ? String(data.kpis.outstanding_orders) : "—" },
    {
      label: "Total Savings",
      value: data ? formatGHSCell(data.kpis.total_discount_ghs) : "—",
      icon: <ShieldCheck className="h-4 w-4 text-success" />,
    },
    { label: "Avg Order Value", value: data ? formatGHSCell(data.kpis.avg_order_value_ghs) : "—" },
  ];

  const points: TrendPoint[] = (data?.series ?? []).map((p) => ({
    bucket: p.bucket,
    orders: p.orders,
    value: Number(p.spend_ghs),
  }));

  if (error) {
    return (
      <p role="alert" className="text-sm text-muted-foreground">
        We couldn&apos;t load this report.
      </p>
    );
  }

  return (
    <div className="space-y-6">
      <ReportKpis items={kpis} loading={!data} />
      <ReportTrendChart
        title="Purchases over time"
        valueLabel="Spend"
        points={points}
        loading={!data}
      />
    </div>
  );
}

function OrdersTab({
  businessId,
  range,
  exportRef,
}: {
  businessId: string;
  range: ReportRangeState;
  exportRef: ExportRef;
}) {
  const [status, setStatus] = useState("");
  const [paymentStatus, setPaymentStatus] = useState("");
  const [paymentMethod, setPaymentMethod] = useState("");
  const key = `${businessId}|${range.range}|${range.from}|${range.to}|${status}|${paymentStatus}|${paymentMethod}`;

  const pager = useKeysetPager<OrderRow>(
    async (cursor: KeysetCursor, limit) => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase as any).rpc("pharmacy_report_orders", {
        p_business_id: businessId,
        ...rangeToRpcArgs(range),
        p_status: status || null,
        p_payment_status: paymentStatus || null,
        p_payment_method: paymentMethod || null,
        p_cursor_created_at: cursor?.created_at ?? null,
        p_cursor_id: cursor?.id ?? null,
        p_limit: limit,
      });
      if (error) throw error;
      return (data ?? []) as OrderRow[];
    },
    key,
    50,
  );

  useEffect(() => {
    exportRef.current = () =>
      downloadCsv(
        reportFilename("pharmacy-orders"),
        rowsToCsv(
          [
            "Order",
            "Date",
            "Supplier",
            "Items",
            "Subtotal GHS",
            "Discount GHS",
            "Total GHS",
            "Status",
            "Payment status",
            "Payment method",
          ],
          pager.rows.map((r) => [
            r.order_number,
            r.created_at,
            r.wholesaler_name,
            r.item_count,
            r.subtotal_ghs,
            r.discount_amount_ghs,
            r.total_ghs,
            r.status,
            r.payment_status,
            r.payment_method,
          ]),
        ),
      );
  }, [pager.rows, exportRef]);

  const columns: ReportColumn<OrderRow>[] = [
    { key: "order", header: "Order", render: (r) => r.order_number },
    { key: "supplier", header: "Supplier", render: (r) => r.wholesaler_name },
    { key: "date", header: "Date", render: (r) => formatReportDate(r.created_at) },
    {
      key: "items",
      header: "Items",
      align: "right",
      hideOnMobile: true,
      render: (r) => r.item_count,
    },
    {
      key: "subtotal",
      header: "Subtotal",
      align: "right",
      hideOnMobile: true,
      render: (r) => formatGHSCell(r.subtotal_ghs),
    },
    {
      key: "discount",
      header: "Discount",
      align: "right",
      hideOnMobile: true,
      render: (r) => formatGHSCell(r.discount_amount_ghs),
    },
    { key: "total", header: "Total", align: "right", render: (r) => formatGHSCell(r.total_ghs) },
    {
      key: "payment",
      header: "Payment",
      render: (r) => `${r.payment_status} · ${r.payment_method}`,
    },
    { key: "status", header: "Status", render: (r) => r.status },
  ];

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap gap-2">
        <select
          className="h-9 rounded-md border border-input bg-background px-2 text-sm"
          value={status}
          onChange={(e) => setStatus(e.target.value)}
        >
          <option value="">All statuses</option>
          {["pending", "accepted", "packed", "dispatched", "delivered", "cancelled"].map((s) => (
            <option key={s} value={s}>
              {s}
            </option>
          ))}
        </select>
        <select
          className="h-9 rounded-md border border-input bg-background px-2 text-sm"
          value={paymentStatus}
          onChange={(e) => setPaymentStatus(e.target.value)}
        >
          <option value="">All payment statuses</option>
          {["unpaid", "paid", "refunded", "failed"].map((s) => (
            <option key={s} value={s}>
              {s}
            </option>
          ))}
        </select>
        <select
          className="h-9 rounded-md border border-input bg-background px-2 text-sm"
          value={paymentMethod}
          onChange={(e) => setPaymentMethod(e.target.value)}
        >
          <option value="">All payment methods</option>
          <option value="cod">Cash on delivery</option>
          <option value="paystack">Paystack</option>
        </select>
      </div>

      <ReportTable
        columns={columns}
        rows={pager.rows}
        rowKey={(r) => r.id}
        loading={pager.loading}
        error={pager.error}
        onRetry={pager.retry}
        emptyMessage="No orders match this range and these filters."
      />

      {(pager.rows.length > 0 || pager.canGoBack) && (
        <nav aria-label="Order pages" className="flex items-center justify-between">
          <Button
            variant="outline"
            size="sm"
            disabled={!pager.canGoBack || pager.loading}
            onClick={pager.previous}
          >
            <ChevronLeft className="mr-1 h-4 w-4" aria-hidden="true" />
            Previous
          </Button>
          <span className="text-sm text-muted-foreground">
            Page {pager.pageNumber} · newest first
          </span>
          <Button
            variant="outline"
            size="sm"
            disabled={!pager.hasMore || pager.loading}
            onClick={pager.next}
          >
            Next
            <ChevronRight className="ml-1 h-4 w-4" aria-hidden="true" />
          </Button>
        </nav>
      )}
    </div>
  );
}

function SuppliersTab({
  businessId,
  range,
  exportRef,
}: {
  businessId: string;
  range: ReportRangeState;
  exportRef: ExportRef;
}) {
  const [rows, setRows] = useState<SupplierRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const key = `${businessId}|${range.range}|${range.from}|${range.to}`;

  const load = () => {
    setLoading(true);
    setError(false);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    void (supabase as any)
      .rpc("pharmacy_report_supplier_spend", {
        p_business_id: businessId,
        ...rangeToRpcArgs(range),
      })
      .then(({ data, error: rpcError }: { data: SupplierRow[]; error: unknown }) => {
        if (rpcError) return setError(true);
        setRows(data ?? []);
        setLoading(false);
      });
  };

  useEffect(load, [key]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    exportRef.current = () =>
      downloadCsv(
        reportFilename("supplier-spend"),
        rowsToCsv(
          ["Supplier", "Orders", "Spend GHS", "Avg Order GHS", "Discounts GHS", "Last Order"],
          rows.map((r) => [
            r.wholesaler_name,
            r.orders,
            r.spend_ghs,
            r.avg_order_value_ghs,
            r.discount_ghs,
            r.last_order_at ?? "",
          ]),
        ),
      );
  }, [rows, exportRef]);

  const columns: ReportColumn<SupplierRow>[] = [
    { key: "name", header: "Supplier", render: (r) => r.wholesaler_name },
    { key: "orders", header: "Orders", align: "right", render: (r) => r.orders },
    { key: "spend", header: "Spend", align: "right", render: (r) => formatGHSCell(r.spend_ghs) },
    {
      key: "avg",
      header: "Avg Order",
      align: "right",
      hideOnMobile: true,
      render: (r) => formatGHSCell(r.avg_order_value_ghs),
    },
    {
      key: "discount",
      header: "Discounts",
      align: "right",
      hideOnMobile: true,
      render: (r) => formatGHSCell(r.discount_ghs),
    },
    { key: "last", header: "Last Order", render: (r) => formatReportDateTime(r.last_order_at) },
  ];

  return (
    <ReportTable
      columns={columns}
      rows={rows}
      rowKey={(r) => r.wholesaler_id}
      loading={loading}
      error={error}
      onRetry={load}
      emptyMessage="No supplier purchases in this range yet."
    />
  );
}
