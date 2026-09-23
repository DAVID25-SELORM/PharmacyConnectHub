import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useRef, useState } from "react";
import { Building2, FileText, ShieldCheck, ShieldX, Store } from "lucide-react";
import { DashboardHeader } from "@/components/DashboardShell";
import { AdminNav } from "@/components/admin/AdminNav";
import { ReportKpis, type ReportKpi } from "@/components/reports/ReportKpis";
import { ReportsHeader } from "@/components/reports/ReportsHeader";
import { ReportTable, type ReportColumn } from "@/components/reports/ReportTable";
import { ReportTrendChart, type TrendPoint } from "@/components/reports/ReportTrendChart";
import { Input } from "@/components/ui/input";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useDebouncedValue } from "@/hooks/use-debounced-value";
import { useReportRange } from "@/hooks/use-report-range";
import { supabase } from "@/integrations/supabase/client";
import {
  downloadCsv,
  formatGHSCell,
  formatReportDate,
  rangeToRpcArgs,
  reportFilename,
  rowsToCsv,
} from "@/lib/reports";

export const Route = createFileRoute("/admin/reports")({
  head: () => ({ meta: [{ title: "Reports - Drugxone" }] }),
  component: AdminReportsPage,
});

type Overview = {
  kpis: {
    gmv_ghs: number;
    orders_total: number;
    completed_orders: number;
    cancelled_orders: number;
    avg_order_value_ghs: number;
  };
  active_pharmacies: number;
  active_wholesalers: number;
  pending_businesses: number;
  series: Array<{ bucket: string; orders: number; gmv_ghs: number }>;
};

type SalesRow = {
  bucket: string;
  orders: number;
  gross_ghs: number;
  discount_ghs: number;
  net_ghs: number;
  avg_order_value_ghs: number;
};

type WholesalerRow = {
  wholesaler_id: string;
  wholesaler_name: string;
  orders: number;
  sales_ghs: number;
  avg_order_value_ghs: number;
  customers: number;
  items_sold: number;
  cancelled_orders: number;
};

type PharmacyRow = {
  pharmacy_id: string;
  pharmacy_name: string;
  orders: number;
  purchases_ghs: number;
  suppliers_used: number;
  avg_basket_ghs: number;
  last_order_at: string | null;
};

type Payments = {
  summary: {
    paid_orders: number;
    paid_ghs: number;
    unpaid_orders: number;
    unpaid_ghs: number;
    failed_orders: number;
    refunded_orders: number;
    cod_orders: number;
    paystack_orders: number;
  };
  rows: Array<{
    order_id: string;
    order_number: string;
    created_at: string;
    pharmacy_name: string;
    wholesaler_name: string;
    payment_method: string;
    total_ghs: number;
    payment_status: string;
  }>;
};

function AdminReportsPage() {
  const { draft, setDraft, applied, apply, reset } = useReportRange();
  const [tab, setTab] = useState("overview");
  const exportRef = useRef<() => void>(() => undefined);

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="Reports" isAdmin={true} />
      <AdminNav />
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
            <TabsTrigger value="sales">Sales</TabsTrigger>
            <TabsTrigger value="businesses">Businesses</TabsTrigger>
            <TabsTrigger value="payments">Payments</TabsTrigger>
          </TabsList>

          <TabsContent value="overview">
            <OverviewTab range={applied} exportRef={exportRef} />
          </TabsContent>
          <TabsContent value="sales">
            <SalesTab range={applied} exportRef={exportRef} />
          </TabsContent>
          <TabsContent value="businesses">
            <BusinessesTab range={applied} exportRef={exportRef} />
          </TabsContent>
          <TabsContent value="payments">
            <PaymentsTab range={applied} exportRef={exportRef} />
          </TabsContent>
        </Tabs>
      </main>
    </div>
  );
}

type ExportRef = React.MutableRefObject<() => void>;

function OverviewTab({
  range,
  exportRef,
}: {
  range: ReturnType<typeof useReportRange>["applied"];
  exportRef: ExportRef;
}) {
  const [data, setData] = useState<Overview | null>(null);
  const [error, setError] = useState(false);

  useEffect(() => {
    setData(null);
    setError(false);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    void (supabase as any)
      .rpc("admin_report_overview", rangeToRpcArgs(range))
      .then(({ data: result, error: rpcError }: { data: Overview; error: unknown }) => {
        if (rpcError) return setError(true);
        setData(result);
      });
  }, [range.range, range.from, range.to]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    exportRef.current = () => {
      if (!data) return;
      downloadCsv(
        reportFilename("platform-overview"),
        rowsToCsv(
          ["Metric", "Value"],
          [
            ["GMV (GHS)", data.kpis.gmv_ghs],
            ["Total orders", data.kpis.orders_total],
            ["Completed orders", data.kpis.completed_orders],
            ["Cancelled orders", data.kpis.cancelled_orders],
            ["Active pharmacies", data.active_pharmacies],
            ["Active wholesalers", data.active_wholesalers],
            ["Pending businesses", data.pending_businesses],
            ["Avg order value (GHS)", data.kpis.avg_order_value_ghs],
          ],
        ),
      );
    };
  }, [data, exportRef]);

  const kpis: ReportKpi[] = [
    {
      label: "Platform GMV",
      value: data ? formatGHSCell(data.kpis.gmv_ghs) : "—",
      icon: <ShieldCheck className="h-4 w-4 text-success" />,
    },
    {
      label: "Total Orders",
      value: data ? String(data.kpis.orders_total) : "—",
      icon: <FileText className="h-4 w-4 text-muted-foreground" />,
    },
    { label: "Completed Orders", value: data ? String(data.kpis.completed_orders) : "—" },
    { label: "Cancelled Orders", value: data ? String(data.kpis.cancelled_orders) : "—" },
    {
      label: "Active Pharmacies",
      value: data ? String(data.active_pharmacies) : "—",
      icon: <Store className="h-4 w-4 text-primary" />,
    },
    {
      label: "Active Wholesalers",
      value: data ? String(data.active_wholesalers) : "—",
      icon: <Building2 className="h-4 w-4 text-accent" />,
    },
    {
      label: "Pending Businesses",
      value: data ? String(data.pending_businesses) : "—",
      icon: <ShieldX className="h-4 w-4 text-warning" />,
    },
    { label: "Avg Order Value", value: data ? formatGHSCell(data.kpis.avg_order_value_ghs) : "—" },
  ];

  const points: TrendPoint[] = (data?.series ?? []).map((p) => ({
    bucket: p.bucket,
    orders: p.orders,
    value: Number(p.gmv_ghs),
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
        title="GMV and orders over time"
        valueLabel="GMV"
        points={points}
        loading={!data}
      />
    </div>
  );
}

function SalesTab({
  range,
  exportRef,
}: {
  range: ReturnType<typeof useReportRange>["applied"];
  exportRef: ExportRef;
}) {
  const [groupBy, setGroupBy] = useState<"day" | "week" | "month">("day");
  const [status, setStatus] = useState("");
  const [paymentStatus, setPaymentStatus] = useState("");
  const [rows, setRows] = useState<SalesRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);

  const key = `${range.range}|${range.from}|${range.to}|${groupBy}|${status}|${paymentStatus}`;

  const load = () => {
    setLoading(true);
    setError(false);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    void (supabase as any)
      .rpc("admin_report_sales", {
        ...rangeToRpcArgs(range),
        p_group_by: groupBy,
        p_status: status || null,
        p_payment_status: paymentStatus || null,
      })
      .then(({ data, error: rpcError }: { data: SalesRow[]; error: unknown }) => {
        if (rpcError) return setError(true);
        setRows(data ?? []);
        setLoading(false);
      });
  };

  useEffect(load, [key]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    exportRef.current = () =>
      downloadCsv(
        reportFilename("marketplace-sales"),
        rowsToCsv(
          ["Date", "Orders", "Gross GHS", "Discount GHS", "Net GHS", "Avg Order Value GHS"],
          rows.map((r) => [
            r.bucket,
            r.orders,
            r.gross_ghs,
            r.discount_ghs,
            r.net_ghs,
            r.avg_order_value_ghs,
          ]),
        ),
      );
  }, [rows, exportRef]);

  const columns: ReportColumn<SalesRow>[] = [
    { key: "bucket", header: "Date", render: (r) => formatReportDate(r.bucket) },
    { key: "orders", header: "Orders", align: "right", render: (r) => r.orders },
    { key: "gross", header: "Gross", align: "right", render: (r) => formatGHSCell(r.gross_ghs) },
    {
      key: "discount",
      header: "Discounts",
      align: "right",
      hideOnMobile: true,
      render: (r) => formatGHSCell(r.discount_ghs),
    },
    { key: "net", header: "Net", align: "right", render: (r) => formatGHSCell(r.net_ghs) },
    {
      key: "aov",
      header: "Avg Order Value",
      align: "right",
      hideOnMobile: true,
      render: (r) => formatGHSCell(r.avg_order_value_ghs),
    },
  ];

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <select
          className="h-9 rounded-md border border-input bg-background px-2 text-sm"
          value={groupBy}
          onChange={(e) => setGroupBy(e.target.value as typeof groupBy)}
        >
          <option value="day">By day</option>
          <option value="week">By week</option>
          <option value="month">By month</option>
        </select>
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
      </div>
      <ReportTable
        columns={columns}
        rows={rows}
        rowKey={(r) => r.bucket}
        loading={loading}
        error={error}
        onRetry={load}
      />
    </div>
  );
}

function BusinessesTab({
  range,
  exportRef,
}: {
  range: ReturnType<typeof useReportRange>["applied"];
  exportRef: ExportRef;
}) {
  const [wholesalers, setWholesalers] = useState<WholesalerRow[]>([]);
  const [pharmacies, setPharmacies] = useState<PharmacyRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [search, setSearch] = useState("");
  const debouncedSearch = useDebouncedValue(search, 400);

  const key = `${range.range}|${range.from}|${range.to}|${debouncedSearch}`;

  const load = () => {
    setLoading(true);
    setError(false);
    void Promise.all([
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (supabase as any).rpc("admin_report_wholesaler_performance", {
        ...rangeToRpcArgs(range),
        p_search: debouncedSearch || null,
      }),
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (supabase as any).rpc("admin_report_pharmacy_activity", {
        ...rangeToRpcArgs(range),
        p_search: debouncedSearch || null,
      }),
    ]).then(([w, p]) => {
      if (w.error || p.error) return setError(true);
      setWholesalers(w.data ?? []);
      setPharmacies(p.data ?? []);
      setLoading(false);
    });
  };

  useEffect(load, [key]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    exportRef.current = () => {
      const wCsv = rowsToCsv(
        [
          "Wholesaler",
          "Orders",
          "Sales GHS",
          "Avg Order GHS",
          "Customers",
          "Items Sold",
          "Cancelled",
        ],
        wholesalers.map((r) => [
          r.wholesaler_name,
          r.orders,
          r.sales_ghs,
          r.avg_order_value_ghs,
          r.customers,
          r.items_sold,
          r.cancelled_orders,
        ]),
      );
      downloadCsv(reportFilename("wholesaler-performance"), wCsv);
      const pCsv = rowsToCsv(
        ["Pharmacy", "Orders", "Purchases GHS", "Suppliers Used", "Avg Basket GHS", "Last Order"],
        pharmacies.map((r) => [
          r.pharmacy_name,
          r.orders,
          r.purchases_ghs,
          r.suppliers_used,
          r.avg_basket_ghs,
          r.last_order_at ?? "",
        ]),
      );
      downloadCsv(reportFilename("pharmacy-activity"), pCsv);
    };
  }, [wholesalers, pharmacies, exportRef]);

  const wholesalerColumns: ReportColumn<WholesalerRow>[] = [
    { key: "name", header: "Wholesaler", render: (r) => r.wholesaler_name },
    { key: "orders", header: "Orders", align: "right", render: (r) => r.orders },
    { key: "sales", header: "Sales", align: "right", render: (r) => formatGHSCell(r.sales_ghs) },
    {
      key: "aov",
      header: "Avg Order",
      align: "right",
      hideOnMobile: true,
      render: (r) => formatGHSCell(r.avg_order_value_ghs),
    },
    {
      key: "customers",
      header: "Customers",
      align: "right",
      hideOnMobile: true,
      render: (r) => r.customers,
    },
    {
      key: "items",
      header: "Items Sold",
      align: "right",
      hideOnMobile: true,
      render: (r) => r.items_sold,
    },
    { key: "cancelled", header: "Cancelled", align: "right", render: (r) => r.cancelled_orders },
  ];

  const pharmacyColumns: ReportColumn<PharmacyRow>[] = [
    { key: "name", header: "Pharmacy", render: (r) => r.pharmacy_name },
    { key: "orders", header: "Orders", align: "right", render: (r) => r.orders },
    {
      key: "purchases",
      header: "Purchases",
      align: "right",
      render: (r) => formatGHSCell(r.purchases_ghs),
    },
    {
      key: "suppliers",
      header: "Suppliers Used",
      align: "right",
      hideOnMobile: true,
      render: (r) => r.suppliers_used,
    },
    {
      key: "basket",
      header: "Avg Basket",
      align: "right",
      hideOnMobile: true,
      render: (r) => formatGHSCell(r.avg_basket_ghs),
    },
    { key: "last", header: "Last Order", render: (r) => formatReportDate(r.last_order_at) },
  ];

  return (
    <div className="space-y-6">
      <Input
        value={search}
        onChange={(e) => setSearch(e.target.value)}
        placeholder="Search by business name..."
        className="max-w-xs"
      />
      <div>
        <h2 className="mb-2 text-sm font-semibold">Wholesaler performance</h2>
        <ReportTable
          columns={wholesalerColumns}
          rows={wholesalers}
          rowKey={(r) => r.wholesaler_id}
          loading={loading}
          error={error}
          onRetry={load}
        />
      </div>
      <div>
        <h2 className="mb-2 text-sm font-semibold">Pharmacy activity</h2>
        <ReportTable
          columns={pharmacyColumns}
          rows={pharmacies}
          rowKey={(r) => r.pharmacy_id}
          loading={loading}
          error={error}
          onRetry={load}
        />
      </div>
    </div>
  );
}

function PaymentsTab({
  range,
  exportRef,
}: {
  range: ReturnType<typeof useReportRange>["applied"];
  exportRef: ExportRef;
}) {
  const [data, setData] = useState<Payments | null>(null);
  const [error, setError] = useState(false);
  const [paymentStatus, setPaymentStatus] = useState("");
  const [paymentMethod, setPaymentMethod] = useState("");
  const key = `${range.range}|${range.from}|${range.to}|${paymentStatus}|${paymentMethod}`;

  const load = () => {
    setData(null);
    setError(false);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    void (supabase as any)
      .rpc("admin_report_payments", {
        ...rangeToRpcArgs(range),
        p_payment_status: paymentStatus || null,
        p_payment_method: paymentMethod || null,
      })
      .then(({ data: result, error: rpcError }: { data: Payments; error: unknown }) => {
        if (rpcError) return setError(true);
        setData(result);
      });
  };

  useEffect(load, [key]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    exportRef.current = () => {
      if (!data) return;
      downloadCsv(
        reportFilename("payments"),
        rowsToCsv(
          ["Date", "Order", "Pharmacy", "Wholesaler", "Method", "Amount GHS", "Status"],
          data.rows.map((r) => [
            r.created_at,
            r.order_number,
            r.pharmacy_name,
            r.wholesaler_name,
            r.payment_method,
            r.total_ghs,
            r.payment_status,
          ]),
        ),
      );
    };
  }, [data, exportRef]);

  const kpis: ReportKpi[] = [
    {
      label: "Paid",
      value: data ? `${data.summary.paid_orders} · ${formatGHSCell(data.summary.paid_ghs)}` : "—",
    },
    {
      label: "Unpaid",
      value: data
        ? `${data.summary.unpaid_orders} · ${formatGHSCell(data.summary.unpaid_ghs)}`
        : "—",
    },
    { label: "Failed", value: data ? String(data.summary.failed_orders) : "—" },
    { label: "Refunded", value: data ? String(data.summary.refunded_orders) : "—" },
    { label: "Cash on delivery", value: data ? String(data.summary.cod_orders) : "—" },
    { label: "Paystack", value: data ? String(data.summary.paystack_orders) : "—" },
  ];

  const columns: ReportColumn<Payments["rows"][number]>[] = [
    { key: "date", header: "Date", render: (r) => formatReportDate(r.created_at) },
    { key: "order", header: "Order", render: (r) => r.order_number },
    { key: "pharmacy", header: "Pharmacy", render: (r) => r.pharmacy_name },
    {
      key: "wholesaler",
      header: "Wholesaler",
      hideOnMobile: true,
      render: (r) => r.wholesaler_name,
    },
    { key: "method", header: "Method", hideOnMobile: true, render: (r) => r.payment_method },
    { key: "amount", header: "Amount", align: "right", render: (r) => formatGHSCell(r.total_ghs) },
    { key: "status", header: "Status", render: (r) => r.payment_status },
  ];

  return (
    <div className="space-y-6">
      <ReportKpis items={kpis} loading={!data} />
      <div className="flex flex-wrap gap-2">
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
          <option value="">All methods</option>
          <option value="cod">Cash on delivery</option>
          <option value="paystack">Paystack</option>
        </select>
      </div>
      <p className="text-xs text-muted-foreground">
        Showing the most recent {data?.rows.length ?? 0} matching payments for this range.
      </p>
      <ReportTable
        columns={columns}
        rows={data?.rows ?? []}
        rowKey={(r) => r.order_id}
        loading={!data}
        error={error}
        onRetry={load}
      />
    </div>
  );
}
