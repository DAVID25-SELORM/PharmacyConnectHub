import { useCallback, useEffect, useState } from "react";
import { ChevronLeft, ChevronRight, Search } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { StatementView } from "@/components/statements/StatementView";
import { supabase } from "@/integrations/supabase/client";
import { formatGHSCell, formatReportDate } from "@/lib/reports";
import { SEGMENT_LABELS } from "@/lib/statement";

type Customer = {
  pharmacy_id: string;
  pharmacy_name: string;
  city: string | null;
  region: string | null;
  orders: number;
  revenue_ghs: number;
  avg_order_value_ghs: number;
  outstanding_ghs: number;
  first_order_at: string | null;
  last_order_at: string | null;
  has_discount: boolean;
  segments: string[];
  total_count: number;
};

type Detail = {
  pharmacy: {
    id: string;
    name: string;
    city: string | null;
    region: string | null;
    email: string | null;
  };
  top_products: Array<{ product_name: string; units: number; orders: number; spend_ghs: number }>;
  recent_orders: Array<{
    id: string;
    order_number: string;
    status: string;
    payment_status: string;
    total_ghs: number;
    created_at: string;
  }>;
  discount: {
    discount_type: string;
    discount_percent: number | null;
    discount_amount: number | null;
    minimum_order_value: number;
    ends_at: string | null;
  } | null;
};

const PAGE_SIZE = 25;
const SEGMENTS = ["new", "active", "high_value", "dormant", "discount"];

function CustomerDetail({
  wholesalerId,
  customer,
  onClose,
}: {
  wholesalerId: string;
  customer: Customer | null;
  onClose: () => void;
}) {
  const [detail, setDetail] = useState<Detail | null>(null);
  const [error, setError] = useState(false);

  useEffect(() => {
    if (!customer) return;
    let cancelled = false;
    setDetail(null);
    setError(false);
    void (supabase as any)
      .rpc("wholesaler_customer_detail", {
        p_business_id: wholesalerId,
        p_pharmacy_id: customer.pharmacy_id,
      })
      .then(({ data, error: rpcError }: { data: Detail | null; error: unknown }) => {
        if (cancelled) return;
        if (rpcError || !data) setError(true);
        else setDetail(data);
      });
    return () => {
      cancelled = true;
    };
  }, [wholesalerId, customer]);

  return (
    <Sheet open={Boolean(customer)} onOpenChange={(open) => !open && onClose()}>
      <SheetContent className="w-full overflow-y-auto sm:max-w-3xl">
        {customer && (
          <>
            <SheetHeader>
              <SheetTitle>{customer.pharmacy_name}</SheetTitle>
              <SheetDescription>
                {[customer.city, customer.region].filter(Boolean).join(", ") || "Location not set"}
                {detail?.pharmacy.email ? ` · ${detail.pharmacy.email}` : ""}
              </SheetDescription>
            </SheetHeader>

            <div className="mt-4 grid gap-3 sm:grid-cols-4">
              {[
                ["Orders", String(customer.orders)],
                ["Revenue", formatGHSCell(customer.revenue_ghs)],
                ["Avg order", formatGHSCell(customer.avg_order_value_ghs)],
                ["Outstanding", formatGHSCell(customer.outstanding_ghs)],
              ].map(([label, value]) => (
                <div key={label} className="rounded-xl border border-border p-3">
                  <div className="text-xs uppercase tracking-wider text-muted-foreground">
                    {label}
                  </div>
                  <div className="mt-1 font-display text-lg font-bold tabular-nums">{value}</div>
                </div>
              ))}
            </div>

            {error ? (
              <p role="alert" className="mt-4 text-sm">
                We couldn&apos;t load this customer&apos;s details.
              </p>
            ) : !detail ? (
              <Skeleton className="mt-4 h-32 w-full" />
            ) : (
              <div className="mt-6 grid gap-6 md:grid-cols-2">
                <section>
                  <h3 className="font-semibold">Frequently bought</h3>
                  {detail.top_products.length === 0 ? (
                    <p className="mt-2 text-sm text-muted-foreground">No orders yet.</p>
                  ) : (
                    <ul className="mt-2 divide-y divide-border rounded-xl border border-border text-sm">
                      {detail.top_products.map((product) => (
                        <li key={product.product_name} className="flex justify-between gap-2 p-2">
                          <span>{product.product_name}</span>
                          <span className="text-muted-foreground tabular-nums">
                            {product.units} units
                          </span>
                        </li>
                      ))}
                    </ul>
                  )}
                </section>
                <section>
                  <h3 className="font-semibold">Recent orders</h3>
                  {detail.recent_orders.length === 0 ? (
                    <p className="mt-2 text-sm text-muted-foreground">No orders yet.</p>
                  ) : (
                    <ul className="mt-2 divide-y divide-border rounded-xl border border-border text-sm">
                      {detail.recent_orders.map((order) => (
                        <li key={order.id} className="flex justify-between gap-2 p-2">
                          <span>
                            {order.order_number}
                            <span className="ml-2 text-xs text-muted-foreground">
                              {formatReportDate(order.created_at)} · {order.status} ·{" "}
                              {order.payment_status}
                            </span>
                          </span>
                          <span className="tabular-nums">{formatGHSCell(order.total_ghs)}</span>
                        </li>
                      ))}
                    </ul>
                  )}
                  <p className="mt-3 text-sm text-muted-foreground">
                    Discount:{" "}
                    {detail.discount
                      ? `${detail.discount.discount_type === "percentage" ? `${detail.discount.discount_percent}%` : formatGHSCell(detail.discount.discount_amount)}${Number(detail.discount.minimum_order_value) > 0 ? ` on orders of ${formatGHSCell(detail.discount.minimum_order_value)}+` : ""}`
                      : "none"}
                  </p>
                </section>
              </div>
            )}

            <section className="mt-8">
              <h3 className="mb-3 font-semibold">Statement of account</h3>
              <StatementView wholesalerId={wholesalerId} pharmacyId={customer.pharmacy_id} />
            </section>
          </>
        )}
      </SheetContent>
    </Sheet>
  );
}

export function CustomersView({ wholesalerId }: { wholesalerId: string }) {
  const [search, setSearch] = useState("");
  const [debounced, setDebounced] = useState("");
  const [segment, setSegment] = useState<string>("");
  const [page, setPage] = useState(0);
  const [rows, setRows] = useState<Customer[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [selected, setSelected] = useState<Customer | null>(null);

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
    const { data, error: rpcError } = await (supabase as any).rpc("wholesaler_customers", {
      p_business_id: wholesalerId,
      p_search: debounced || null,
      p_segment: segment || null,
      p_limit: PAGE_SIZE,
      p_offset: page * PAGE_SIZE,
    });
    if (rpcError) setError(true);
    else setRows(Array.isArray(data) ? data : []);
    setLoading(false);
  }, [wholesalerId, debounced, segment, page]);

  useEffect(() => {
    void load();
  }, [load]);

  const total = rows[0]?.total_count ?? 0;
  const pageCount = Math.max(1, Math.ceil(total / PAGE_SIZE));

  return (
    <div className="space-y-4">
      <div>
        <h2 className="font-display text-xl font-bold">Customers</h2>
        <p className="text-sm text-muted-foreground">
          Pharmacies you sell to, with their buying history, balance and statement.
        </p>
      </div>

      <div className="flex flex-col gap-3 sm:flex-row">
        <div className="relative flex-1">
          <Search
            className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground"
            aria-hidden="true"
          />
          <Input
            aria-label="Search customers"
            className="pl-9"
            placeholder="Search customers..."
            value={search}
            onChange={(event) => setSearch(event.target.value)}
          />
        </div>
        <div className="flex flex-wrap gap-2" role="group" aria-label="Customer segment">
          <Button
            size="sm"
            variant={segment === "" ? "secondary" : "ghost"}
            onClick={() => {
              setSegment("");
              setPage(0);
            }}
          >
            All
          </Button>
          {SEGMENTS.map((key) => (
            <Button
              key={key}
              size="sm"
              variant={segment === key ? "secondary" : "ghost"}
              onClick={() => {
                setSegment(key);
                setPage(0);
              }}
            >
              {SEGMENT_LABELS[key]}
            </Button>
          ))}
        </div>
      </div>

      {loading ? (
        <div className="space-y-2" role="status" aria-label="Loading customers">
          <Skeleton className="h-14 w-full" />
          <Skeleton className="h-14 w-full" />
          <Skeleton className="h-14 w-full" />
        </div>
      ) : error ? (
        <div role="alert" className="rounded-xl border border-dashed border-border p-8 text-center">
          <p className="text-sm font-medium">We couldn&apos;t load your customers.</p>
          <Button className="mt-3" variant="outline" size="sm" onClick={() => void load()}>
            Try again
          </Button>
        </div>
      ) : rows.length === 0 ? (
        <Card className="p-10 text-center text-muted-foreground">
          <p className="font-medium text-foreground">
            {debounced || segment ? "No customers match." : "No customers yet"}
          </p>
          <p className="mt-1 text-sm">
            {debounced || segment
              ? "Try a different search or segment."
              : "Pharmacies appear here after their first order."}
          </p>
        </Card>
      ) : (
        <Card className="overflow-x-auto">
          <table className="w-full min-w-[720px] text-left text-sm">
            <thead className="bg-muted/40 text-xs uppercase tracking-wider text-muted-foreground">
              <tr>
                <th scope="col" className="p-3">
                  Pharmacy
                </th>
                <th scope="col" className="p-3 text-right">
                  Orders
                </th>
                <th scope="col" className="p-3 text-right">
                  Revenue
                </th>
                <th scope="col" className="p-3 text-right">
                  Outstanding
                </th>
                <th scope="col" className="p-3">
                  Last order
                </th>
                <th scope="col" className="p-3">
                  Segments
                </th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={row.pharmacy_id} className="border-t">
                  <td className="p-3">
                    <button
                      type="button"
                      className="text-left font-medium text-primary hover:underline"
                      onClick={() => setSelected(row)}
                    >
                      {row.pharmacy_name}
                    </button>
                    <div className="text-xs text-muted-foreground">
                      {[row.city, row.region].filter(Boolean).join(", ")}
                    </div>
                  </td>
                  <td className="p-3 text-right tabular-nums">{row.orders}</td>
                  <td className="p-3 text-right tabular-nums">{formatGHSCell(row.revenue_ghs)}</td>
                  <td className="p-3 text-right tabular-nums">
                    {Number(row.outstanding_ghs) > 0 ? formatGHSCell(row.outstanding_ghs) : "—"}
                  </td>
                  <td className="p-3">{formatReportDate(row.last_order_at)}</td>
                  <td className="p-3">
                    <div className="flex flex-wrap gap-1">
                      {row.segments.map((key) => (
                        <Badge key={key} variant={key === "dormant" ? "outline" : "secondary"}>
                          {SEGMENT_LABELS[key] ?? key}
                        </Badge>
                      ))}
                    </div>
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
            Page {page + 1} of {pageCount} · {total} customers
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

      <CustomerDetail
        wholesalerId={wholesalerId}
        customer={selected}
        onClose={() => setSelected(null)}
      />
    </div>
  );
}
