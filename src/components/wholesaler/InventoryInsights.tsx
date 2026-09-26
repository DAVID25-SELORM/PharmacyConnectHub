import { useCallback, useEffect, useState } from "react";
import { ChevronLeft, ChevronRight, Download, Search } from "lucide-react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { supabase } from "@/integrations/supabase/client";
import {
  daysRemainingLabel,
  INSIGHT_FILTERS,
  STATUS_LABELS,
  type InsightRow,
} from "@/lib/inventory-insights";
import { downloadCsv, formatGHSCell, reportFilename, rowsToCsv } from "@/lib/reports";

const PAGE_SIZE = 25;
const EXPORT_PAGE_CAP = 20;

function fetchPage(
  businessId: string,
  windowDays: number,
  search: string,
  filter: string,
  limit: number,
  offset: number,
) {
  return (supabase as any).rpc("wholesaler_inventory_insights", {
    p_business_id: businessId,
    p_window_days: windowDays,
    p_search: search || null,
    p_filter: filter || null,
    p_limit: limit,
    p_offset: offset,
  }) as Promise<{ data: InsightRow[] | null; error: unknown }>;
}

/** Stock health for the wholesaler: what is running out, what is not moving, what to reorder. */
export function InventoryInsights({ businessId }: { businessId: string }) {
  const [windowDays, setWindowDays] = useState(30);
  const [search, setSearch] = useState("");
  const [debounced, setDebounced] = useState("");
  const [filter, setFilter] = useState("");
  const [page, setPage] = useState(0);
  const [rows, setRows] = useState<InsightRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [exporting, setExporting] = useState(false);
  const [summary, setSummary] = useState<InsightRow | null>(null);

  useEffect(() => {
    const timer = setTimeout(() => {
      setDebounced(search.trim());
      setPage(0);
    }, 300);
    return () => clearTimeout(timer);
  }, [search]);

  const load = useCallback(async () => {
    setLoading(true);
    setError(false);
    const { data, error: rpcError } = await fetchPage(
      businessId,
      windowDays,
      debounced,
      filter,
      PAGE_SIZE,
      page * PAGE_SIZE,
    );
    if (rpcError) setError(true);
    else {
      const list = Array.isArray(data) ? data : [];
      setRows(list);
      if (list[0]) setSummary(list[0]);
    }
    setLoading(false);
  }, [businessId, windowDays, debounced, filter, page]);

  useEffect(() => {
    void load();
  }, [load]);

  const exportCsv = async () => {
    setExporting(true);
    const all: InsightRow[] = [];
    for (let index = 0; index < EXPORT_PAGE_CAP; index += 1) {
      const { data, error: rpcError } = await fetchPage(
        businessId,
        windowDays,
        debounced,
        filter,
        100,
        index * 100,
      );
      if (rpcError) {
        setExporting(false);
        return toast.error("We couldn't export the inventory. Please try again.");
      }
      const chunk = Array.isArray(data) ? data : [];
      all.push(...chunk);
      if (chunk.length < 100) break;
    }
    setExporting(false);
    downloadCsv(
      reportFilename("stock-insights"),
      rowsToCsv(
        [
          "Product",
          "Category",
          "Stock",
          "Price (GHS)",
          "Stock value at selling price (GHS)",
          `Units sold (${windowDays}d)`,
          "Units sold (90d)",
          "Days remaining",
          "Status",
          "Movement",
          "Suggested reorder (recommendation to reach 30-day cover)",
        ],
        all.map((row) => [
          row.product_name,
          row.category ?? "",
          row.current_stock,
          Number(row.price_ghs).toFixed(2),
          Number(row.stock_value_ghs).toFixed(2),
          row.units_sold_window,
          row.units_sold_90d,
          row.days_remaining ?? "",
          STATUS_LABELS[row.status],
          row.movement ?? "",
          row.suggested_reorder ?? "",
        ]),
      ),
    );
  };

  const total = rows[0]?.total_count ?? 0;
  const pageCount = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const kpis = summary
    ? [
        ["Active products", String(summary.total_products)],
        ["Out of stock", String(summary.total_out_of_stock)],
        ["Low stock", String(summary.total_low_stock)],
        ["Dead stock", String(summary.total_dead_stock)],
        ["Stock value (selling price)", formatGHSCell(summary.total_stock_value_ghs)],
      ]
    : [];

  return (
    <div className="space-y-4">
      <div>
        <h2 className="font-display text-xl font-bold">Stock insights</h2>
        <p className="text-sm text-muted-foreground">
          Low stock means under 14 days of cover at recent sales speed. Dead stock is listed for
          over 90 days with no sales in that time; new products are never dead stock. Suggested
          reorder is a recommendation to reach 30 days of cover, not an order. Value is at selling
          price because cost prices are not recorded.
        </p>
      </div>

      {kpis.length > 0 && (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
          {kpis.map(([label, value]) => (
            <Card key={label} className="p-4">
              <div className="text-xs uppercase tracking-wider text-muted-foreground">{label}</div>
              <div className="mt-1 font-display text-xl font-bold tabular-nums">{value}</div>
            </Card>
          ))}
        </div>
      )}

      <div className="flex flex-col gap-3 lg:flex-row lg:items-center">
        <div className="relative flex-1">
          <Search
            className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground"
            aria-hidden="true"
          />
          <Input
            aria-label="Search products"
            className="pl-9"
            placeholder="Search products..."
            value={search}
            onChange={(event) => setSearch(event.target.value)}
          />
        </div>
        <label className="flex items-center gap-2 text-sm">
          <span className="text-muted-foreground">Sales speed based on</span>
          <select
            className="h-10 rounded-md border border-input bg-background px-2 text-sm"
            value={windowDays}
            onChange={(event) => {
              setWindowDays(Number(event.target.value));
              setPage(0);
            }}
          >
            <option value={7}>last 7 days</option>
            <option value={30}>last 30 days</option>
            <option value={90}>last 90 days</option>
          </select>
        </label>
        <Button
          variant="outline"
          size="sm"
          onClick={() => void exportCsv()}
          disabled={exporting || total === 0}
        >
          <Download className="mr-1 h-4 w-4" aria-hidden="true" />
          {exporting ? "Exporting..." : "CSV"}
        </Button>
      </div>

      <div className="flex flex-wrap gap-2" role="group" aria-label="Inventory filter">
        {INSIGHT_FILTERS.map((item) => (
          <Button
            key={item.value}
            size="sm"
            variant={filter === item.value ? "secondary" : "ghost"}
            onClick={() => {
              setFilter(item.value);
              setPage(0);
            }}
          >
            {item.label}
          </Button>
        ))}
      </div>

      {loading ? (
        <div className="space-y-2" role="status" aria-label="Loading stock insights">
          <Skeleton className="h-14 w-full" />
          <Skeleton className="h-14 w-full" />
          <Skeleton className="h-14 w-full" />
        </div>
      ) : error ? (
        <div role="alert" className="rounded-xl border border-dashed border-border p-8 text-center">
          <p className="text-sm font-medium">We couldn&apos;t load your stock insights.</p>
          <Button className="mt-3" variant="outline" size="sm" onClick={() => void load()}>
            Try again
          </Button>
        </div>
      ) : rows.length === 0 ? (
        <Card className="p-10 text-center text-muted-foreground">
          <p className="font-medium text-foreground">
            {debounced || filter ? "No products match." : "No active products yet"}
          </p>
          <p className="mt-1 text-sm">
            {debounced || filter
              ? "Try a different search or filter."
              : "Add products in My products to see stock insights."}
          </p>
        </Card>
      ) : (
        <Card className="overflow-x-auto">
          <table className="w-full min-w-[820px] text-left text-sm">
            <thead className="bg-muted/40 text-xs uppercase tracking-wider text-muted-foreground">
              <tr>
                <th scope="col" className="p-3">
                  Product
                </th>
                <th scope="col" className="p-3 text-right">
                  Stock
                </th>
                <th scope="col" className="p-3 text-right">
                  Sold ({windowDays}d)
                </th>
                <th scope="col" className="p-3 text-right">
                  Days left
                </th>
                <th scope="col" className="p-3">
                  Status
                </th>
                <th scope="col" className="p-3 text-right">
                  Suggested reorder{" "}
                  <span className="block text-[10px] font-normal normal-case tracking-normal">
                    recommended, 30-day target cover
                  </span>
                </th>
                <th scope="col" className="p-3 text-right">
                  Value
                </th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={row.product_id} className="border-t">
                  <td className="p-3">
                    <div className="font-medium">{row.product_name}</div>
                    <div className="text-xs text-muted-foreground">{row.category}</div>
                  </td>
                  <td className="p-3 text-right tabular-nums">{row.current_stock}</td>
                  <td className="p-3 text-right tabular-nums">{row.units_sold_window}</td>
                  <td className="p-3 text-right tabular-nums">{daysRemainingLabel(row)}</td>
                  <td className="p-3">
                    <div className="flex flex-wrap gap-1">
                      <Badge
                        variant={
                          row.status === "out_of_stock"
                            ? "destructive"
                            : row.status === "ok"
                              ? "outline"
                              : "secondary"
                        }
                      >
                        {STATUS_LABELS[row.status]}
                      </Badge>
                      {row.movement && (
                        <Badge variant="outline">
                          {row.movement === "fast" ? "Fast moving" : "Slow moving"}
                        </Badge>
                      )}
                    </div>
                  </td>
                  <td className="p-3 text-right tabular-nums">
                    {row.suggested_reorder ? `${row.suggested_reorder} units` : "—"}
                  </td>
                  <td className="p-3 text-right tabular-nums">
                    {formatGHSCell(row.stock_value_ghs)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}

      {!loading && !error && total > PAGE_SIZE && (
        <div className="flex items-center justify-between text-sm text-muted-foreground">
          <span>
            Page {page + 1} of {pageCount} · {total} products
          </span>
          <div className="flex gap-2">
            <Button
              size="sm"
              variant="outline"
              disabled={page === 0}
              onClick={() => setPage((value) => value - 1)}
            >
              <ChevronLeft className="h-4 w-4" aria-hidden="true" />
              Previous
            </Button>
            <Button
              size="sm"
              variant="outline"
              disabled={page + 1 >= pageCount}
              onClick={() => setPage((value) => value + 1)}
            >
              Next
              <ChevronRight className="h-4 w-4" aria-hidden="true" />
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}
