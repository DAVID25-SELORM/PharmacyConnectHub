import { useCallback, useEffect, useState } from "react";
import { ChevronLeft, ChevronRight, Plus, Search } from "lucide-react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { Textarea } from "@/components/ui/textarea";
import { supabase } from "@/integrations/supabase/client";
import {
  BATCH_FILTERS,
  EXPIRY_LABELS,
  expiryText,
  validateBatchInput,
  WRITE_OFF_REASONS,
  type BatchRow,
} from "@/lib/batches";
import { formatReportDate } from "@/lib/reports";

const PAGE_SIZE = 25;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const rpc = (name: string, args: Record<string, unknown>) => (supabase as any).rpc(name, args);

function ReceiveDialog({
  open,
  products,
  onClose,
  onDone,
}: {
  open: boolean;
  products: Array<{ id: string; name: string }>;
  onClose: () => void;
  onDone: () => void;
}) {
  const [productId, setProductId] = useState("");
  const [batchNumber, setBatchNumber] = useState("");
  const [expiryDate, setExpiryDate] = useState("");
  const [quantity, setQuantity] = useState("");
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (open) {
      setProductId("");
      setBatchNumber("");
      setExpiryDate("");
      setQuantity("");
    }
  }, [open]);

  const save = async () => {
    const problem = validateBatchInput({ productId, batchNumber, expiryDate, quantity });
    if (problem) return toast.error(problem);
    setSaving(true);
    const { error } = await rpc("receive_product_batch", {
      p_product_id: productId,
      p_batch_number: batchNumber.trim(),
      p_expiry_date: expiryDate,
      p_quantity: Number(quantity),
    });
    setSaving(false);
    if (error) return toast.error(error.message || "We couldn't receive this batch.");
    toast.success("Batch received and added to stock.");
    onDone();
    onClose();
  };

  return (
    <Dialog open={open} onOpenChange={(value) => !value && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Receive a batch</DialogTitle>
          <DialogDescription>
            The quantity is added to the product&apos;s sellable stock. Receiving more of an
            existing batch number with the same expiry date adds to that batch.
          </DialogDescription>
        </DialogHeader>
        <label className="block text-sm">
          <span className="mb-1 block text-muted-foreground">Product</span>
          <select
            className="h-10 w-full rounded-md border border-input bg-background px-2 text-sm"
            value={productId}
            onChange={(event) => setProductId(event.target.value)}
          >
            <option value="">Choose a product</option>
            {products.map((product) => (
              <option key={product.id} value={product.id}>
                {product.name}
              </option>
            ))}
          </select>
        </label>
        <div className="grid gap-3 sm:grid-cols-3">
          <label className="block text-sm">
            <span className="mb-1 block text-muted-foreground">Batch number</span>
            <Input
              value={batchNumber}
              maxLength={60}
              onChange={(event) => setBatchNumber(event.target.value)}
            />
          </label>
          <label className="block text-sm">
            <span className="mb-1 block text-muted-foreground">Expiry date</span>
            <Input
              type="date"
              value={expiryDate}
              onChange={(event) => setExpiryDate(event.target.value)}
            />
          </label>
          <label className="block text-sm">
            <span className="mb-1 block text-muted-foreground">Quantity</span>
            <Input
              type="number"
              min={1}
              value={quantity}
              onChange={(event) => setQuantity(event.target.value)}
            />
          </label>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="hero" disabled={saving} onClick={() => void save()}>
            {saving ? "Saving..." : "Receive batch"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function WriteOffDialog({
  batch,
  onClose,
  onDone,
}: {
  batch: BatchRow | null;
  onClose: () => void;
  onDone: () => void;
}) {
  const [quantity, setQuantity] = useState("");
  const [reason, setReason] = useState("");
  const [note, setNote] = useState("");
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (batch) {
      setQuantity(String(batch.quantity_on_hand));
      setReason(batch.expiry_status === "expired" ? "expired" : "");
      setNote("");
    }
  }, [batch]);

  const save = async () => {
    if (!batch) return;
    const units = Number(quantity);
    if (!Number.isInteger(units) || units < 1 || units > batch.quantity_on_hand)
      return toast.error(`Enter a quantity between 1 and ${batch.quantity_on_hand}.`);
    if (!reason) return toast.error("Choose a reason.");
    setSaving(true);
    const { error } = await rpc("write_off_batch", {
      p_batch_id: batch.batch_id,
      p_quantity: units,
      p_reason: reason,
      p_note: note.trim() || null,
    });
    setSaving(false);
    if (error) return toast.error(error.message || "We couldn't write off this stock.");
    toast.success("Stock written off.");
    onDone();
    onClose();
  };

  return (
    <Dialog open={Boolean(batch)} onOpenChange={(value) => !value && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Write off stock</DialogTitle>
          <DialogDescription>
            {batch?.product_name} · batch {batch?.batch_number}. Written-off units are removed from
            the batch and from sellable stock. This cannot be undone.
          </DialogDescription>
        </DialogHeader>
        <div className="grid gap-3 sm:grid-cols-2">
          <label className="block text-sm">
            <span className="mb-1 block text-muted-foreground">
              Units to write off (max {batch?.quantity_on_hand})
            </span>
            <Input
              type="number"
              min={1}
              value={quantity}
              onChange={(event) => setQuantity(event.target.value)}
            />
          </label>
          <label className="block text-sm">
            <span className="mb-1 block text-muted-foreground">Reason</span>
            <select
              className="h-10 w-full rounded-md border border-input bg-background px-2 text-sm"
              value={reason}
              onChange={(event) => setReason(event.target.value)}
            >
              <option value="">Choose a reason</option>
              {WRITE_OFF_REASONS.map((item) => (
                <option key={item.value} value={item.value}>
                  {item.label}
                </option>
              ))}
            </select>
          </label>
        </div>
        <label className="block text-sm">
          <span className="mb-1 block text-muted-foreground">Note (optional)</span>
          <Textarea
            value={note}
            maxLength={500}
            onChange={(event) => setNote(event.target.value)}
          />
        </label>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="destructive" disabled={saving} onClick={() => void save()}>
            Write off
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/** Batches and expiry for one wholesaler. Everyone who can process orders can look; owners and managers can change stock. */
export function BatchesPanel({
  businessId,
  canManage,
  products,
}: {
  businessId: string;
  canManage: boolean;
  products: Array<{ id: string; name: string }>;
}) {
  const [search, setSearch] = useState("");
  const [debounced, setDebounced] = useState("");
  const [filter, setFilter] = useState("");
  const [page, setPage] = useState(0);
  const [rows, setRows] = useState<BatchRow[]>([]);
  const [summary, setSummary] = useState<BatchRow | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [receiving, setReceiving] = useState(false);
  const [writeOff, setWriteOff] = useState<BatchRow | null>(null);

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
    const { data, error: rpcError } = await rpc("list_product_batches", {
      p_business_id: businessId,
      p_filter: filter || null,
      p_search: debounced || null,
      p_limit: PAGE_SIZE,
      p_offset: page * PAGE_SIZE,
    });
    if (rpcError) setError(true);
    else {
      const list = Array.isArray(data) ? (data as BatchRow[]) : [];
      setRows(list);
      if (list[0]) setSummary(list[0]);
    }
    setLoading(false);
  }, [businessId, filter, debounced, page]);

  useEffect(() => {
    void load();
  }, [load]);

  const total = rows[0]?.total_count ?? 0;
  const pageCount = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const kpis = summary
    ? [
        ["Expired batches", summary.summary_expired],
        ["Within 30 days", summary.summary_within_30],
        ["Within 60 days", summary.summary_within_60],
        ["Within 90 days", summary.summary_within_90],
        ["Units expiring or expired", summary.summary_units_at_risk],
      ]
    : [];

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="font-display text-xl font-bold">Batches &amp; expiry</h2>
          <p className="text-sm text-muted-foreground">
            Track batch numbers and expiry dates. For each order, Drugxone suggests the
            earliest-expiring batch first. Stock you had before adding batches shows as not batched.
          </p>
        </div>
        {canManage && (
          <Button variant="hero" size="sm" onClick={() => setReceiving(true)}>
            <Plus className="mr-1 h-4 w-4" aria-hidden="true" />
            Receive batch
          </Button>
        )}
      </div>

      {kpis.length > 0 && (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
          {kpis.map(([label, value]) => (
            <Card key={label as string} className="p-4">
              <div className="text-xs uppercase tracking-wider text-muted-foreground">{label}</div>
              <div className="mt-1 font-display text-xl font-bold tabular-nums">{value}</div>
            </Card>
          ))}
        </div>
      )}

      <div className="relative">
        <Search
          className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground"
          aria-hidden="true"
        />
        <Input
          aria-label="Search batches"
          className="pl-9"
          placeholder="Search product or batch number..."
          value={search}
          onChange={(event) => setSearch(event.target.value)}
        />
      </div>

      <div className="flex flex-wrap gap-2" role="group" aria-label="Batch filter">
        {BATCH_FILTERS.map((item) => (
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
        <div className="space-y-2" role="status" aria-label="Loading batches">
          <Skeleton className="h-14 w-full" />
          <Skeleton className="h-14 w-full" />
        </div>
      ) : error ? (
        <div role="alert" className="rounded-xl border border-dashed border-border p-8 text-center">
          <p className="text-sm font-medium">We couldn&apos;t load your batches.</p>
          <Button className="mt-3" variant="outline" size="sm" onClick={() => void load()}>
            Try again
          </Button>
        </div>
      ) : rows.length === 0 ? (
        <Card className="p-10 text-center text-muted-foreground">
          <p className="font-medium text-foreground">
            {debounced || filter ? "No batches match." : "No batches recorded yet"}
          </p>
          <p className="mt-1 text-sm">
            {debounced || filter
              ? "Try a different search or filter."
              : canManage
                ? "Use “Receive batch” when new stock arrives."
                : "An owner or manager can receive batches."}
          </p>
        </Card>
      ) : (
        <Card className="overflow-x-auto">
          <table className="w-full min-w-[760px] text-left text-sm">
            <thead className="bg-muted/40 text-xs uppercase tracking-wider text-muted-foreground">
              <tr>
                <th scope="col" className="p-3">
                  Product
                </th>
                <th scope="col" className="p-3">
                  Batch
                </th>
                <th scope="col" className="p-3">
                  Expiry
                </th>
                <th scope="col" className="p-3 text-right">
                  On hand
                </th>
                <th scope="col" className="p-3 text-right">
                  Received
                </th>
                <th scope="col" className="p-3 text-right">
                  Not batched
                </th>
                {canManage && (
                  <th scope="col" className="p-3">
                    <span className="sr-only">Actions</span>
                  </th>
                )}
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={row.batch_id} className="border-t align-top">
                  <td className="p-3 font-medium">{row.product_name}</td>
                  <td className="p-3">{row.batch_number}</td>
                  <td className="p-3">
                    <div>{formatReportDate(row.expiry_date)}</div>
                    <div className="mt-1 flex flex-wrap items-center gap-1">
                      <Badge
                        variant={
                          row.expiry_status === "expired"
                            ? "destructive"
                            : row.expiry_status === "ok"
                              ? "outline"
                              : "secondary"
                        }
                      >
                        {EXPIRY_LABELS[row.expiry_status]}
                      </Badge>
                      <span className="text-xs text-muted-foreground">
                        {expiryText(row.days_to_expiry)}
                      </span>
                    </div>
                  </td>
                  <td className="p-3 text-right tabular-nums">{row.quantity_on_hand}</td>
                  <td className="p-3 text-right tabular-nums">{row.quantity_received}</td>
                  <td className="p-3 text-right tabular-nums">
                    {Math.max(row.product_stock - Number(row.product_batched_units), 0)}
                  </td>
                  {canManage && (
                    <td className="p-3 text-right">
                      {row.quantity_on_hand > 0 && (
                        <Button size="sm" variant="outline" onClick={() => setWriteOff(row)}>
                          Write off
                        </Button>
                      )}
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}

      {!loading && !error && total > PAGE_SIZE && (
        <div className="flex items-center justify-between text-sm text-muted-foreground">
          <span>
            Page {page + 1} of {pageCount} · {total} batches
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

      <ReceiveDialog
        open={receiving}
        products={products}
        onClose={() => setReceiving(false)}
        onDone={() => void load()}
      />
      <WriteOffDialog
        batch={writeOff}
        onClose={() => setWriteOff(null)}
        onDone={() => void load()}
      />
    </div>
  );
}
