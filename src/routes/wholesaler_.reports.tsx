import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useRef, useState } from "react";
import {
  ChevronLeft,
  ChevronRight,
  FileText,
  Package,
  ShieldCheck,
  Users2,
  Wallet,
} from "lucide-react";
import { WorkspaceGate } from "@/components/WorkspaceGate";
import { DashboardHeader } from "@/components/DashboardShell";
import { ReportKpis, type ReportKpi } from "@/components/reports/ReportKpis";
import { ReportsHeader } from "@/components/reports/ReportsHeader";
import { ReportTable, type ReportColumn } from "@/components/reports/ReportTable";
import { ReportTrendChart, type TrendPoint } from "@/components/reports/ReportTrendChart";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
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

export const Route = createFileRoute("/wholesaler_/reports")({
  head: () => ({ meta: [{ title: "Reports - Drugxone" }] }),
  component: () => (
    <WorkspaceGate>
      <WholesalerReportsPage />
    </WorkspaceGate>
  ),
});

type Overview = {
  kpis: {
    total_sales_ghs: number;
    total_orders: number;
    customers: number;
    units_sold: number;
    discounts_given_ghs: number;
    avg_order_value_ghs: number;
    pending_orders: number;
  };
  series: Array<{ bucket: string; orders: number; sales_ghs: number }>;
};

type SaleRow = {
  id: string;
  order_number: string;
  created_at: string;
  pharmacy_id: string;
  pharmacy_name: string;
  item_count: number;
  gross_ghs: number;
  discount_amount_ghs: number;
  net_ghs: number;
  status: string;
  payment_status: string;
};

type CustomerRow = {
  pharmacy_id: string;
  pharmacy_name: string;
  orders: number;
  revenue_ghs: number;
  avg_order_value_ghs: number;
  discount_given_ghs: number;
  last_order_at: string | null;
};

type ProductRow = {
  product_id: string;
  product_name: string;
  units_sold: number;
  orders: number;
  revenue_ghs: number;
  customers: number;
  stock_remaining: number | null;
};

type InventoryRow = {
  product_id: string;
  product_name: string;
  category: string | null;
  stock: number;
  price_ghs: number;
  stock_value_ghs: number;
  active: boolean;
};

type ExportRef = React.MutableRefObject<() => void>;

function WholesalerReportsPage() {
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
            <TabsTrigger value="sales">Sales</TabsTrigger>
            <TabsTrigger value="customers">Customers</TabsTrigger>
            <TabsTrigger value="products">Products</TabsTrigger>
            <TabsTrigger value="inventory">Inventory</TabsTrigger>
          </TabsList>

          <TabsContent value="overview">
            <OverviewTab businessId={business.id} range={applied} exportRef={exportRef} />
          </TabsContent>
          <TabsContent value="sales">
            <SalesTab businessId={business.id} range={applied} exportRef={exportRef} />
          </TabsContent>
          <TabsContent value="customers">
            <CustomersTab businessId={business.id} range={applied} exportRef={exportRef} />
          </TabsContent>
          <TabsContent value="products">
            <ProductsTab businessId={business.id} range={applied} exportRef={exportRef} />
          </TabsContent>
          <TabsContent value="inventory">
            <InventoryTab businessId={business.id} exportRef={exportRef} />
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
      .rpc("wholesaler_report_overview", { p_business_id: businessId, ...rangeToRpcArgs(range) })
      .then(({ data: result, error: rpcError }: { data: Overview; error: unknown }) => {
        if (rpcError) return setError(true);
        setData(result);
      });
  }, [businessId, range.range, range.from, range.to]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    exportRef.current = () => {
      if (!data) return;
      downloadCsv(
        reportFilename("wholesaler-overview"),
        rowsToCsv(
          ["Metric", "Value"],
          [
            ["Total sales (GHS)", data.kpis.total_sales_ghs],
            ["Total orders", data.kpis.total_orders],
            ["Customers", data.kpis.customers],
            ["Units sold", data.kpis.units_sold],
            ["Discounts given (GHS)", data.kpis.discounts_given_ghs],
            ["Avg order value (GHS)", data.kpis.avg_order_value_ghs],
            ["Pending orders", data.kpis.pending_orders],
          ],
        ),
      );
    };
  }, [data, exportRef]);

  const kpis: ReportKpi[] = [
    {
      label: "Total Sales",
      value: data ? formatGHSCell(data.kpis.total_sales_ghs) : "—",
      icon: <Wallet className="h-4 w-4 text-primary" />,
    },
    {
      label: "Total Orders",
      value: data ? String(data.kpis.total_orders) : "—",
      icon: <FileText className="h-4 w-4 text-muted-foreground" />,
    },
    {
      label: "Customers",
      value: data ? String(data.kpis.customers) : "—",
      icon: <Users2 className="h-4 w-4 text-accent" />,
    },
    {
      label: "Units Sold",
      value: data ? String(data.kpis.units_sold) : "—",
      icon: <Package className="h-4 w-4 text-muted-foreground" />,
    },
    {
      label: "Discounts Given",
      value: data ? formatGHSCell(data.kpis.discounts_given_ghs) : "—",
      icon: <ShieldCheck className="h-4 w-4 text-success" />,
    },
    { label: "Avg Order Value", value: data ? formatGHSCell(data.kpis.avg_order_value_ghs) : "—" },
    { label: "Pending Orders", value: data ? String(data.kpis.pending_orders) : "—" },
  ];

  const points: TrendPoint[] = (data?.series ?? []).map((p) => ({
    bucket: p.bucket,
    orders: p.orders,
    value: Number(p.sales_ghs),
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
        title="Sales over time"
        valueLabel="Sales"
        points={points}
        loading={!data}
      />
    </div>
  );
}

function SalesTab({
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
  const key = `${businessId}|${range.range}|${range.from}|${range.to}|${status}|${paymentStatus}`;

  const pager = useKeysetPager<SaleRow>(
    async (cursor: KeysetCursor, limit) => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase as any).rpc("wholesaler_report_sales", {
        p_business_id: businessId,
        ...rangeToRpcArgs(range),
        p_status: status || null,
        p_payment_status: paymentStatus || null,
        p_cursor_created_at: cursor?.created_at ?? null,
        p_cursor_id: cursor?.id ?? null,
        p_limit: limit,
      });
      if (error) throw error;
      return (data ?? []) as SaleRow[];
    },
    key,
    50,
  );

  useEffect(() => {
    exportRef.current = () =>
      downloadCsv(
        reportFilename("wholesaler-sales"),
        rowsToCsv(
          [
            "Order",
            "Date",
            "Pharmacy",
            "Items",
            "Gross GHS",
            "Discount GHS",
            "Net GHS",
            "Status",
            "Payment status",
          ],
          pager.rows.map((r) => [
            r.order_number,
            r.created_at,
            r.pharmacy_name,
            r.item_count,
            r.gross_ghs,
            r.discount_amount_ghs,
            r.net_ghs,
            r.status,
            r.payment_status,
          ]),
        ),
      );
  }, [pager.rows, exportRef]);

  const columns: ReportColumn<SaleRow>[] = [
    { key: "order", header: "Order", render: (r) => r.order_number },
    { key: "pharmacy", header: "Pharmacy", render: (r) => r.pharmacy_name },
    { key: "date", header: "Date", render: (r) => formatReportDate(r.created_at) },
    {
      key: "items",
      header: "Items",
      align: "right",
      hideOnMobile: true,
      render: (r) => r.item_count,
    },
    {
      key: "gross",
      header: "Gross",
      align: "right",
      hideOnMobile: true,
      render: (r) => formatGHSCell(r.gross_ghs),
    },
    {
      key: "discount",
      header: "Discount",
      align: "right",
      hideOnMobile: true,
      render: (r) => formatGHSCell(r.discount_amount_ghs),
    },
    { key: "net", header: "Net", align: "right", render: (r) => formatGHSCell(r.net_ghs) },
    { key: "payment", header: "Payment", render: (r) => r.payment_status },
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
      </div>

      <ReportTable
        columns={columns}
        rows={pager.rows}
        rowKey={(r) => r.id}
        loading={pager.loading}
        error={pager.error}
        onRetry={pager.retry}
        emptyMessage="No sales match this range and these filters."
      />

      {(pager.rows.length > 0 || pager.canGoBack) && (
        <nav aria-label="Sales pages" className="flex items-center justify-between">
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

function CustomersTab({
  businessId,
  range,
  exportRef,
}: {
  businessId: string;
  range: ReportRangeState;
  exportRef: ExportRef;
}) {
  const [rows, setRows] = useState<CustomerRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const key = `${businessId}|${range.range}|${range.from}|${range.to}`;

  const load = () => {
    setLoading(true);
    setError(false);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    void (supabase as any)
      .rpc("wholesaler_report_customers", { p_business_id: businessId, ...rangeToRpcArgs(range) })
      .then(({ data, error: rpcError }: { data: CustomerRow[]; error: unknown }) => {
        if (rpcError) return setError(true);
        setRows(data ?? []);
        setLoading(false);
      });
  };

  useEffect(load, [key]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    exportRef.current = () =>
      downloadCsv(
        reportFilename("wholesaler-customers"),
        rowsToCsv(
          [
            "Pharmacy",
            "Orders",
            "Revenue GHS",
            "Avg Order GHS",
            "Discount Given GHS",
            "Last Order",
          ],
          rows.map((r) => [
            r.pharmacy_name,
            r.orders,
            r.revenue_ghs,
            r.avg_order_value_ghs,
            r.discount_given_ghs,
            r.last_order_at ?? "",
          ]),
        ),
      );
  }, [rows, exportRef]);

  const columns: ReportColumn<CustomerRow>[] = [
    { key: "name", header: "Pharmacy", render: (r) => r.pharmacy_name },
    { key: "orders", header: "Orders", align: "right", render: (r) => r.orders },
    {
      key: "revenue",
      header: "Revenue",
      align: "right",
      render: (r) => formatGHSCell(r.revenue_ghs),
    },
    {
      key: "avg",
      header: "Avg Order",
      align: "right",
      hideOnMobile: true,
      render: (r) => formatGHSCell(r.avg_order_value_ghs),
    },
    {
      key: "discount",
      header: "Discount Given",
      align: "right",
      hideOnMobile: true,
      render: (r) => formatGHSCell(r.discount_given_ghs),
    },
    { key: "last", header: "Last Order", render: (r) => formatReportDateTime(r.last_order_at) },
  ];

  return (
    <ReportTable
      columns={columns}
      rows={rows}
      rowKey={(r) => r.pharmacy_id}
      loading={loading}
      error={error}
      onRetry={load}
      emptyMessage="No customer orders in this range yet."
    />
  );
}

function ProductsTab({
  businessId,
  range,
  exportRef,
}: {
  businessId: string;
  range: ReportRangeState;
  exportRef: ExportRef;
}) {
  const [rows, setRows] = useState<ProductRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const key = `${businessId}|${range.range}|${range.from}|${range.to}`;

  const load = () => {
    setLoading(true);
    setError(false);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    void (supabase as any)
      .rpc("wholesaler_report_products", { p_business_id: businessId, ...rangeToRpcArgs(range) })
      .then(({ data, error: rpcError }: { data: ProductRow[]; error: unknown }) => {
        if (rpcError) return setError(true);
        setRows(data ?? []);
        setLoading(false);
      });
  };

  useEffect(load, [key]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    exportRef.current = () =>
      downloadCsv(
        reportFilename("wholesaler-products"),
        rowsToCsv(
          ["Product", "Units Sold", "Orders", "Revenue GHS", "Customers", "Stock Remaining"],
          rows.map((r) => [
            r.product_name,
            r.units_sold,
            r.orders,
            r.revenue_ghs,
            r.customers,
            r.stock_remaining ?? "",
          ]),
        ),
      );
  }, [rows, exportRef]);

  const columns: ReportColumn<ProductRow>[] = [
    { key: "name", header: "Product", render: (r) => r.product_name },
    { key: "units", header: "Units Sold", align: "right", render: (r) => r.units_sold },
    {
      key: "orders",
      header: "Orders",
      align: "right",
      hideOnMobile: true,
      render: (r) => r.orders,
    },
    {
      key: "revenue",
      header: "Revenue",
      align: "right",
      render: (r) => formatGHSCell(r.revenue_ghs),
    },
    {
      key: "customers",
      header: "Customers",
      align: "right",
      hideOnMobile: true,
      render: (r) => r.customers,
    },
    {
      key: "stock",
      header: "Stock Remaining",
      align: "right",
      render: (r) => r.stock_remaining ?? "—",
    },
  ];

  return (
    <ReportTable
      columns={columns}
      rows={rows}
      rowKey={(r) => r.product_id}
      loading={loading}
      error={error}
      onRetry={load}
      emptyMessage="No products sold in this range yet."
    />
  );
}

function InventoryTab({ businessId, exportRef }: { businessId: string; exportRef: ExportRef }) {
  const [search, setSearch] = useState("");
  const [lowStock, setLowStock] = useState("");
  const [rows, setRows] = useState<InventoryRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const key = `${businessId}|${search}|${lowStock}`;

  const load = () => {
    setLoading(true);
    setError(false);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    void (supabase as any)
      .rpc("wholesaler_report_inventory", {
        p_business_id: businessId,
        p_search: search || null,
        p_low_stock_at_or_below: lowStock ? Number(lowStock) : null,
      })
      .then(({ data, error: rpcError }: { data: InventoryRow[]; error: unknown }) => {
        if (rpcError) return setError(true);
        setRows(data ?? []);
        setLoading(false);
      });
  };

  useEffect(load, [key]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    exportRef.current = () =>
      downloadCsv(
        reportFilename("inventory"),
        rowsToCsv(
          ["Product", "Category", "Stock", "Price GHS", "Stock Value GHS", "Active"],
          rows.map((r) => [
            r.product_name,
            r.category ?? "",
            r.stock,
            r.price_ghs,
            r.stock_value_ghs,
            r.active ? "Yes" : "No",
          ]),
        ),
      );
  }, [rows, exportRef]);

  const totalValue = rows.reduce((sum, r) => sum + Number(r.stock_value_ghs), 0);

  const columns: ReportColumn<InventoryRow>[] = [
    { key: "name", header: "Product", render: (r) => r.product_name },
    { key: "category", header: "Category", hideOnMobile: true, render: (r) => r.category ?? "—" },
    { key: "stock", header: "Stock", align: "right", render: (r) => r.stock },
    {
      key: "price",
      header: "Price",
      align: "right",
      hideOnMobile: true,
      render: (r) => formatGHSCell(r.price_ghs),
    },
    {
      key: "value",
      header: "Stock Value",
      align: "right",
      render: (r) => formatGHSCell(r.stock_value_ghs),
    },
    { key: "active", header: "Active", render: (r) => (r.active ? "Yes" : "No") },
  ];

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-2">
        <Input
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search products..."
          className="max-w-xs"
        />
        <div>
          <label htmlFor="low-stock" className="block text-xs text-muted-foreground">
            Low stock at or below
          </label>
          <Input
            id="low-stock"
            type="number"
            min={0}
            value={lowStock}
            onChange={(e) => setLowStock(e.target.value)}
            placeholder="e.g. 10"
            className="w-32"
          />
        </div>
        <p className="ml-auto text-sm text-muted-foreground">
          {rows.length} product{rows.length === 1 ? "" : "s"} · Total value{" "}
          {formatGHSCell(totalValue)}
        </p>
      </div>
      <ReportTable
        columns={columns}
        rows={rows}
        rowKey={(r) => r.product_id}
        loading={loading}
        error={error}
        onRetry={load}
        emptyMessage="No products match this search."
      />
    </div>
  );
}
