import { useCallback, useEffect, useMemo, useState } from "react";
import { ArrowDown, ArrowUp, History, Search } from "lucide-react";
import { ReportTable, type ReportColumn } from "@/components/reports/ReportTable";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { useDebouncedValue } from "@/hooks/use-debounced-value";
import { supabase } from "@/integrations/supabase/client";
import {
  EMPTY_PRICE_HISTORY_FILTERS,
  PRICE_HISTORY_DETAIL_LIMIT,
  PRICE_HISTORY_LIMIT,
  describeChange,
  priceHistoryArgs,
  priceHistoryDetailArgs,
  priceHistoryExport,
  productDescriptor,
  type PriceHistoryDetailRow,
  type PriceHistoryFilters,
  type PriceHistoryRow,
} from "@/lib/price-history";
import { purchaseCategoryLabel, type PurchaseCategory } from "@/lib/purchase-category";
import {
  formatGHSCell,
  formatReportDate,
  rangeToRpcArgs,
  type ReportExportPayload,
  type ReportRangeState,
} from "@/lib/reports";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

const selectClass =
  "h-9 rounded-md border border-input bg-background px-2 text-sm focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring";

type SupplierOption = { wholesaler_id: string; wholesaler_name: string };
type RpcError = { message?: string; code?: string } | null;

const isMissingFunction = (error: RpcError) =>
  error?.code === "PGRST202" || /could not find the function/i.test(error?.message ?? "");

/** "Up 10.0%" / "Down 4.5%" with an arrow, so the direction never depends on colour alone. */
function ChangeText({ changePct }: { changePct: number | string | null }) {
  const { direction, label } = describeChange(changePct);
  if (direction === "none") return <span className="text-muted-foreground">—</span>;
  const tone = direction === "up" ? "text-destructive" : direction === "down" ? "text-success" : "";
  return (
    <span className={`inline-flex items-center gap-1 ${tone}`}>
      {direction === "up" && <ArrowUp className="h-3.5 w-3.5" aria-hidden="true" />}
      {direction === "down" && <ArrowDown className="h-3.5 w-3.5" aria-hidden="true" />}
      {label}
    </span>
  );
}

export function PriceHistoryTab({
  businessId,
  range,
  exportRef,
}: {
  businessId: string;
  range: ReportRangeState;
  exportRef: React.MutableRefObject<() => ReportExportPayload>;
}) {
  const [filters, setFilters] = useState<PriceHistoryFilters>(EMPTY_PRICE_HISTORY_FILTERS);
  const debouncedSearch = useDebouncedValue(filters.search, 350);
  const [suppliers, setSuppliers] = useState<SupplierOption[]>([]);
  const [rows, setRows] = useState<PriceHistoryRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [unavailable, setUnavailable] = useState(false);
  const [reloadKey, setReloadKey] = useState(0);
  const [open, setOpen] = useState<PriceHistoryRow | null>(null);

  const rangeArgs = useMemo(
    () => rangeToRpcArgs(range),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [range.range, range.from, range.to],
  );
  const effective = useMemo(
    () => ({ ...filters, search: debouncedSearch }),
    [filters, debouncedSearch],
  );

  useEffect(() => {
    void db
      .rpc("pharmacy_report_supplier_spend", { p_business_id: businessId, ...rangeArgs })
      .then(({ data }: { data: SupplierOption[] | null }) => setSuppliers(data ?? []));
  }, [businessId, rangeArgs]);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(false);
    void db
      .rpc("pharmacy_price_history", priceHistoryArgs(businessId, rangeArgs, effective))
      .then(({ data, error: rpcError }: { data: PriceHistoryRow[] | null; error: RpcError }) => {
        if (cancelled) return;
        setLoading(false);
        if (rpcError) {
          if (isMissingFunction(rpcError)) setUnavailable(true);
          else setError(true);
          return;
        }
        setRows(data ?? []);
      });
    return () => {
      cancelled = true;
    };
  }, [businessId, rangeArgs, effective, reloadKey]);

  useEffect(() => {
    exportRef.current = () => priceHistoryExport(rows);
  }, [rows, exportRef]);

  const total = rows.length > 0 ? Number(rows[0].total_count) : 0;

  const columns: ReportColumn<PriceHistoryRow>[] = [
    {
      key: "product",
      header: "Product",
      render: (r) => (
        <button
          type="button"
          className="text-left focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring"
          onClick={() => setOpen(r)}
        >
          <span className="block font-medium underline-offset-2 hover:underline">
            {r.product_name}
          </span>
          <span className="block text-xs text-muted-foreground">{productDescriptor(r)}</span>
        </button>
      ),
    },
    {
      key: "latest",
      header: "Latest paid",
      align: "right",
      render: (r) => (
        <div>
          <div className="font-medium">{formatGHSCell(r.latest_paid_ghs)}</div>
          <div className="text-xs text-muted-foreground">{r.latest_supplier_name}</div>
        </div>
      ),
    },
    {
      key: "change",
      header: "Since last order",
      align: "right",
      render: (r) => <ChangeText changePct={r.change_pct} />,
    },
    {
      key: "avg",
      header: "Average paid",
      align: "right",
      hideOnMobile: true,
      render: (r) => formatGHSCell(r.avg_paid_ghs),
    },
    {
      key: "range",
      header: "Lowest – highest",
      align: "right",
      hideOnMobile: true,
      render: (r) =>
        Number(r.min_paid_ghs) === Number(r.max_paid_ghs)
          ? formatGHSCell(r.min_paid_ghs)
          : `${formatGHSCell(r.min_paid_ghs)} – ${formatGHSCell(r.max_paid_ghs)}`,
    },
    {
      key: "cheaper",
      header: "Cheaper elsewhere",
      hideOnMobile: true,
      render: (r) =>
        r.cheaper_paid_ghs === null ? (
          <span className="text-muted-foreground">—</span>
        ) : (
          <span>
            {formatGHSCell(r.cheaper_paid_ghs)}
            <span className="block text-xs text-muted-foreground">
              at {r.cheaper_supplier_name}
            </span>
          </span>
        ),
    },
    {
      key: "purchases",
      header: "Purchases",
      align: "right",
      hideOnMobile: true,
      render: (r) => r.purchases,
    },
    {
      key: "when",
      header: "Last bought",
      hideOnMobile: true,
      render: (r) => formatReportDate(r.latest_at),
    },
    {
      key: "open",
      header: "",
      align: "right",
      render: (r) => (
        <Button
          variant="outline"
          size="sm"
          onClick={() => setOpen(r)}
          aria-label={`See every purchase of ${[r.product_name, productDescriptor(r)].filter(Boolean).join(", ")}`}
        >
          <History className="mr-1 h-4 w-4" aria-hidden="true" />
          History
        </Button>
      ),
    },
  ];

  if (unavailable)
    return (
      <div className="rounded-xl border border-dashed border-border p-8 text-center text-sm text-muted-foreground">
        Price history is being set up. Your purchases are still available in the Products and
        Suppliers tabs.
      </div>
    );

  return (
    <div className="space-y-4">
      <p className="max-w-3xl text-sm text-muted-foreground">
        What you paid per unit, after discounts, for each product. &ldquo;Since last order&rdquo;
        compares your latest order with the one before it from the same supplier, so switching
        supplier is not counted as a price change. Products are matched across suppliers by name,
        brand, form and pack size. Cancelled orders are left out.
      </p>
      <div className="flex flex-wrap gap-2">
        <div className="relative">
          <Search
            className="pointer-events-none absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground"
            aria-hidden="true"
          />
          <Input
            className="h-9 w-56 pl-8"
            placeholder="Search product or brand"
            aria-label="Search product or brand"
            value={filters.search}
            onChange={(event) => setFilters((c) => ({ ...c, search: event.target.value }))}
          />
        </div>
        <select
          className={selectClass}
          value={filters.category}
          onChange={(event) => setFilters((c) => ({ ...c, category: event.target.value }))}
          aria-label="Purchase category"
        >
          <option value="">All categories</option>
          <option value="nhis">NHIS</option>
          <option value="cash_private">Cash</option>
          <option value="other">Other</option>
          <option value="unclassified">Not classified</option>
        </select>
        <select
          className={selectClass}
          value={filters.supplierId}
          onChange={(event) => setFilters((c) => ({ ...c, supplierId: event.target.value }))}
          aria-label="Supplier"
        >
          <option value="">All suppliers</option>
          {suppliers.map((s) => (
            <option key={s.wholesaler_id} value={s.wholesaler_id}>
              {s.wholesaler_name}
            </option>
          ))}
        </select>
      </div>
      {filters.supplierId && (
        <p className="text-xs text-muted-foreground">
          Showing one supplier only, so prices are not compared across suppliers. Choose All
          suppliers to see who was cheaper.
        </p>
      )}

      <ReportTable
        columns={columns}
        rows={rows}
        rowKey={(r) => r.sample_product_id}
        loading={loading}
        error={error}
        onRetry={() => setReloadKey((key) => key + 1)}
        emptyMessage="No purchases in this range yet."
      />
      {total > PRICE_HISTORY_LIMIT && (
        <p role="status" className="text-sm text-warning">
          Showing the {PRICE_HISTORY_LIMIT} products you spent most on, out of {total}. Search or
          filter to narrow it down.
        </p>
      )}

      <PurchasesDialog
        businessId={businessId}
        row={open}
        rangeArgs={rangeArgs}
        filters={effective}
        onClose={() => setOpen(null)}
      />
    </div>
  );
}

function PurchasesDialog({
  businessId,
  row,
  rangeArgs,
  filters,
  onClose,
}: {
  businessId: string;
  row: PriceHistoryRow | null;
  rangeArgs: ReturnType<typeof rangeToRpcArgs>;
  filters: PriceHistoryFilters;
  onClose: () => void;
}) {
  const [rows, setRows] = useState<PriceHistoryDetailRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(false);
  const [reloadKey, setReloadKey] = useState(0);
  const productId = row?.sample_product_id;

  useEffect(() => {
    if (!productId) return;
    let cancelled = false;
    setLoading(true);
    setError(false);
    setRows([]);
    void db
      .rpc(
        "pharmacy_price_history_detail",
        priceHistoryDetailArgs(businessId, productId, rangeArgs, filters),
      )
      .then(
        ({ data, error: rpcError }: { data: PriceHistoryDetailRow[] | null; error: RpcError }) => {
          if (cancelled) return;
          setLoading(false);
          if (rpcError) return setError(true);
          setRows(data ?? []);
        },
      );
    return () => {
      cancelled = true;
    };
  }, [businessId, productId, rangeArgs, filters, reloadKey]);

  const retry = useCallback(() => setReloadKey((key) => key + 1), []);
  const total = rows.length > 0 ? Number(rows[0].total_count) : 0;

  const columns: ReportColumn<PriceHistoryDetailRow>[] = [
    { key: "date", header: "Date", render: (r) => formatReportDate(r.purchased_at) },
    { key: "supplier", header: "Supplier", render: (r) => r.supplier_name },
    {
      key: "order",
      header: "Order",
      hideOnMobile: true,
      render: (r) => r.order_number,
    },
    { key: "qty", header: "Qty", align: "right", render: (r) => r.quantity },
    {
      key: "list",
      header: "List price",
      align: "right",
      hideOnMobile: true,
      render: (r) => formatGHSCell(r.list_price_ghs),
    },
    {
      key: "paid",
      header: "Paid",
      align: "right",
      render: (r) => <span className="font-medium">{formatGHSCell(r.paid_ghs)}</span>,
    },
    {
      key: "change",
      header: "Since last order",
      align: "right",
      render: (r) => <ChangeText changePct={r.change_pct} />,
    },
    {
      key: "category",
      header: "Category",
      hideOnMobile: true,
      render: (r) => purchaseCategoryLabel(r.purchase_category as PurchaseCategory | null),
    },
  ];

  return (
    <Dialog open={row !== null} onOpenChange={(next) => !next && onClose()}>
      <DialogContent className="max-w-4xl">
        <DialogHeader>
          <DialogTitle>{row?.product_name}</DialogTitle>
          <DialogDescription>
            {row ? productDescriptor(row) : ""}
            {row ? " · " : ""}
            Every purchase in this range, newest first. &ldquo;Since last order&rdquo; compares with
            the previous order from the same supplier.
          </DialogDescription>
        </DialogHeader>
        <div className="max-h-[60vh] overflow-y-auto">
          <ReportTable
            columns={columns}
            rows={rows}
            rowKey={(r, index) => `${r.order_id}-${index}`}
            loading={loading}
            error={error}
            onRetry={retry}
            emptyMessage="No purchases of this product in this range."
          />
        </div>
        {total > PRICE_HISTORY_DETAIL_LIMIT && (
          <p role="status" className="text-sm text-warning">
            Showing the latest {PRICE_HISTORY_DETAIL_LIMIT} of {total} purchases. Choose a shorter
            range to see the rest.
          </p>
        )}
      </DialogContent>
    </Dialog>
  );
}
