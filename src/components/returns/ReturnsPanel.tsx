import { useCallback, useEffect, useState } from "react";
import { Check, ChevronLeft, ChevronRight } from "lucide-react";
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
import { formatGHS, timeAgo } from "@/lib/format";
import {
  acceptedValue,
  nextWholesalerAction,
  RESOLUTION_LABELS,
  RETURN_REASONS,
  RETURN_STATUS_FILTERS,
  RETURN_STATUS_LABELS,
  returnTimeline,
  type ReturnResolution,
  type ReturnRow,
  type WholesalerAction,
} from "@/lib/returns";

const PAGE_SIZE = 20;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const rpc = (name: string, args: Record<string, unknown>) => (supabase as any).rpc(name, args);

function reasonLabel(value: string) {
  return RETURN_REASONS.find((item) => item.value === value)?.label ?? value;
}

function Timeline({ status }: { status: ReturnRow["status"] }) {
  return (
    <ol className="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-xs" aria-label="Return progress">
      {returnTimeline(status).map((step) => (
        <li
          key={step.key}
          className={`flex items-center gap-1 ${step.done ? "text-foreground" : "text-muted-foreground"}`}
        >
          {step.done ? (
            <Check className="h-3 w-3 text-success" aria-hidden="true" />
          ) : (
            <span className="h-3 w-3" />
          )}
          {step.label}
        </li>
      ))}
    </ol>
  );
}

function ReviewDialog({
  row,
  onClose,
  onDone,
}: {
  row: ReturnRow | null;
  onClose: () => void;
  onDone: () => void;
}) {
  const [note, setNote] = useState("");
  const [saving, setSaving] = useState(false);
  useEffect(() => setNote(""), [row]);

  const decide = async (approve: boolean) => {
    if (!row) return;
    if (!approve && !note.trim())
      return toast.error("Give the pharmacy a reason for rejecting this return.");
    setSaving(true);
    const { error } = await rpc("review_order_return", {
      p_return_id: row.id,
      p_approve: approve,
      p_note: note.trim() || null,
    });
    setSaving(false);
    if (error) return toast.error(error.message || "We couldn't update this return.");
    toast.success(approve ? "Return approved." : "Return rejected.");
    onDone();
    onClose();
  };

  return (
    <Dialog open={Boolean(row)} onOpenChange={(open) => !open && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Review {row?.return_number}</DialogTitle>
          <DialogDescription>
            Approve to ask the pharmacy to send the goods back, or reject with a reason they can
            read.
          </DialogDescription>
        </DialogHeader>
        <label className="block text-sm">
          <span className="mb-1 block text-muted-foreground">
            Note to the pharmacy (required when rejecting)
          </span>
          <Textarea
            value={note}
            maxLength={1000}
            onChange={(event) => setNote(event.target.value)}
          />
        </label>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="destructive" disabled={saving} onClick={() => void decide(false)}>
            Reject
          </Button>
          <Button variant="hero" disabled={saving} onClick={() => void decide(true)}>
            Approve
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function InspectDialog({
  row,
  onClose,
  onDone,
}: {
  row: ReturnRow | null;
  onClose: () => void;
  onDone: () => void;
}) {
  const [accepted, setAccepted] = useState<Record<string, string>>({});
  const [restock, setRestock] = useState<Record<string, boolean>>({});
  const [saving, setSaving] = useState(false);
  useEffect(() => {
    if (!row) return;
    setAccepted(
      Object.fromEntries(row.items.map((item) => [item.id, String(item.quantity_requested)])),
    );
    setRestock(Object.fromEntries(row.items.map((item) => [item.id, false])));
  }, [row]);

  const save = async () => {
    if (!row) return;
    for (const item of row.items) {
      const value = Number(accepted[item.id]);
      if (!Number.isInteger(value) || value < 0 || value > item.quantity_requested) {
        return toast.error(
          `Accepted quantity for ${item.product_name} must be between 0 and ${item.quantity_requested}.`,
        );
      }
    }
    setSaving(true);
    const { error } = await rpc("inspect_order_return", {
      p_return_id: row.id,
      p_items: row.items.map((item) => ({
        return_item_id: item.id,
        quantity_accepted: Number(accepted[item.id]),
        restock: Boolean(restock[item.id]),
      })),
    });
    setSaving(false);
    if (error) return toast.error(error.message || "We couldn't save the inspection.");
    toast.success("Inspection saved.");
    onDone();
    onClose();
  };

  return (
    <Dialog open={Boolean(row)} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-h-[85vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>Inspect {row?.return_number}</DialogTitle>
          <DialogDescription>
            For each line, record how many units you accept and whether they can go back into stock.
          </DialogDescription>
        </DialogHeader>
        <ul className="divide-y divide-border rounded-xl border border-border">
          {row?.items.map((item) => (
            <li
              key={item.id}
              className="flex flex-wrap items-center justify-between gap-3 p-3 text-sm"
            >
              <div>
                <div className="font-medium">{item.product_name}</div>
                <div className="text-xs text-muted-foreground">
                  Requested {item.quantity_requested} at {formatGHS(item.unit_price_ghs)}
                </div>
              </div>
              <div className="flex items-center gap-3">
                <label className="flex items-center gap-2">
                  <span className="text-xs text-muted-foreground">Accept</span>
                  <Input
                    type="number"
                    min={0}
                    max={item.quantity_requested}
                    className="w-20"
                    value={accepted[item.id] ?? ""}
                    onChange={(event) =>
                      setAccepted((current) => ({ ...current, [item.id]: event.target.value }))
                    }
                  />
                </label>
                <label className="flex items-center gap-1 text-xs">
                  <input
                    type="checkbox"
                    checked={Boolean(restock[item.id])}
                    onChange={(event) =>
                      setRestock((current) => ({ ...current, [item.id]: event.target.checked }))
                    }
                  />
                  Restock
                </label>
              </div>
            </li>
          ))}
        </ul>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="hero" disabled={saving} onClick={() => void save()}>
            Save inspection
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function ResolveDialog({
  row,
  onClose,
  onDone,
}: {
  row: ReturnRow | null;
  onClose: () => void;
  onDone: () => void;
}) {
  const [resolution, setResolution] = useState<ReturnResolution | "">("");
  const [note, setNote] = useState("");
  const [saving, setSaving] = useState(false);
  useEffect(() => {
    setResolution("");
    setNote("");
  }, [row]);

  const accepted = Object.fromEntries(
    (row?.items ?? []).map((item) => [item.id, item.quantity_accepted ?? 0]),
  );
  const units = Object.values(accepted).reduce((sum, value) => sum + value, 0);
  const amount = row ? acceptedValue(row.items, accepted) : 0;
  const restocked = (row?.items ?? [])
    .filter((item) => item.restock)
    .reduce((sum, item) => sum + (item.quantity_accepted ?? 0), 0);

  const save = async () => {
    if (!row || !resolution) return toast.error("Choose how to resolve this return.");
    setSaving(true);
    const { error } = await rpc("resolve_order_return", {
      p_return_id: row.id,
      p_resolution: resolution,
      p_note: note.trim() || null,
    });
    setSaving(false);
    if (error) return toast.error(error.message || "We couldn't resolve this return.");
    toast.success("Return resolved.");
    onDone();
    onClose();
  };

  return (
    <Dialog open={Boolean(row)} onOpenChange={(open) => !open && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Resolve {row?.return_number}</DialogTitle>
          <DialogDescription>
            {units} unit(s) accepted, worth {formatGHS(amount)}.{" "}
            {restocked > 0
              ? `${restocked} unit(s) will go back into stock.`
              : "Nothing will be restocked."}
          </DialogDescription>
        </DialogHeader>
        <label className="block text-sm">
          <span className="mb-1 block text-muted-foreground">Resolution</span>
          <select
            className="h-10 w-full rounded-md border border-input bg-background px-2 text-sm"
            value={resolution}
            onChange={(event) => setResolution(event.target.value as ReturnResolution)}
          >
            <option value="">Choose a resolution</option>
            {units > 0 ? (
              <>
                <option value="refund">Refund {formatGHS(amount)}</option>
                <option value="credit">
                  Credit {formatGHS(amount)} to the pharmacy&apos;s account
                </option>
                <option value="replacement">Send a replacement (no money moves)</option>
              </>
            ) : (
              <option value="none">No action (nothing accepted)</option>
            )}
          </select>
        </label>
        <p className="text-xs text-muted-foreground">
          Refunds and credits appear as a credit on both sides&apos; statement. Paying a refund out
          is done outside Drugxone.
        </p>
        <label className="block text-sm">
          <span className="mb-1 block text-muted-foreground">Note to the pharmacy (optional)</span>
          <Textarea
            value={note}
            maxLength={1000}
            onChange={(event) => setNote(event.target.value)}
          />
        </label>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="hero" disabled={saving} onClick={() => void save()}>
            Resolve return
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/** Returns list for either side. Pharmacies can cancel unreviewed requests; wholesalers step them through. */
export function ReturnsPanel({
  businessId,
  side,
  canProcess,
  canManage,
  refreshKey = 0,
}: {
  businessId: string;
  side: "pharmacy" | "wholesaler";
  canProcess: boolean;
  canManage: boolean;
  refreshKey?: number;
}) {
  const [status, setStatus] = useState("");
  const [page, setPage] = useState(0);
  const [rows, setRows] = useState<ReturnRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [dialog, setDialog] = useState<{ action: WholesalerAction; row: ReturnRow } | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(false);
    const { data, error: rpcError } = await rpc("list_order_returns", {
      p_business_id: businessId,
      p_status: status || null,
      p_limit: PAGE_SIZE,
      p_offset: page * PAGE_SIZE,
    });
    if (rpcError) setError(true);
    else setRows(Array.isArray(data) ? data : []);
    setLoading(false);
  }, [businessId, status, page]);

  useEffect(() => {
    void load();
  }, [load, refreshKey]);

  const run = async (row: ReturnRow, name: string, args: Record<string, unknown>, done: string) => {
    setBusyId(row.id);
    const { error: rpcError } = await rpc(name, args);
    setBusyId(null);
    if (rpcError) return toast.error(rpcError.message || "We couldn't update this return.");
    toast.success(done);
    void load();
  };

  const total = rows[0]?.total_count ?? 0;
  const pageCount = Math.max(1, Math.ceil(total / PAGE_SIZE));

  return (
    <div className="space-y-4">
      <div>
        <h2 className="font-display text-xl font-bold">Returns</h2>
        <p className="text-sm text-muted-foreground">
          {side === "pharmacy"
            ? "Return requests you have sent to suppliers. Start one from a delivered order under My orders."
            : "Return requests from your customers. Accepted refunds and credits reduce the customer's balance."}
        </p>
      </div>

      <div className="flex flex-wrap gap-2" role="group" aria-label="Return status filter">
        {RETURN_STATUS_FILTERS.map((item) => (
          <Button
            key={item.value}
            size="sm"
            variant={status === item.value ? "secondary" : "ghost"}
            onClick={() => {
              setStatus(item.value);
              setPage(0);
            }}
          >
            {item.label}
          </Button>
        ))}
      </div>

      {loading ? (
        <div className="space-y-2" role="status" aria-label="Loading returns">
          <Skeleton className="h-24 w-full" />
          <Skeleton className="h-24 w-full" />
        </div>
      ) : error ? (
        <div role="alert" className="rounded-xl border border-dashed border-border p-8 text-center">
          <p className="text-sm font-medium">We couldn&apos;t load your returns.</p>
          <Button className="mt-3" variant="outline" size="sm" onClick={() => void load()}>
            Try again
          </Button>
        </div>
      ) : rows.length === 0 ? (
        <Card className="p-10 text-center text-muted-foreground">
          <p className="font-medium text-foreground">
            {status ? "No returns with this status." : "No returns yet"}
          </p>
        </Card>
      ) : (
        rows.map((row) => {
          const action =
            side === "wholesaler"
              ? nextWholesalerAction(row.status, { canProcess, canManage })
              : null;
          return (
            <Card key={row.id} className="p-4">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-display text-lg font-bold">{row.return_number}</span>
                    <Badge
                      variant={
                        row.status === "rejected"
                          ? "destructive"
                          : row.status === "resolved"
                            ? "outline"
                            : "secondary"
                      }
                    >
                      {RETURN_STATUS_LABELS[row.status]}
                    </Badge>
                  </div>
                  <div className="mt-1 text-sm text-muted-foreground">
                    Order {row.order_number} · {side === "pharmacy" ? "Supplier" : "Customer"}{" "}
                    <span className="font-medium text-foreground">{row.counterparty_name}</span> ·{" "}
                    {timeAgo(row.created_at)}
                  </div>
                  <div className="mt-1 text-sm">
                    Reason: {reasonLabel(row.reason)}
                    {row.note && <span className="text-muted-foreground"> — {row.note}</span>}
                  </div>
                </div>
                <div className="flex flex-wrap items-center gap-2">
                  {side === "pharmacy" && row.status === "requested" && canProcess && (
                    <Button
                      variant="outline"
                      size="sm"
                      disabled={busyId === row.id}
                      onClick={() =>
                        void run(
                          row,
                          "cancel_order_return",
                          { p_return_id: row.id },
                          "Return cancelled.",
                        )
                      }
                    >
                      Cancel request
                    </Button>
                  )}
                  {action === "review" && (
                    <Button variant="hero" size="sm" onClick={() => setDialog({ action, row })}>
                      Review
                    </Button>
                  )}
                  {action === "receive" && (
                    <Button
                      variant="hero"
                      size="sm"
                      disabled={busyId === row.id}
                      onClick={() =>
                        void run(
                          row,
                          "mark_order_return_returned",
                          { p_return_id: row.id },
                          "Marked as received.",
                        )
                      }
                    >
                      Mark goods received
                    </Button>
                  )}
                  {action === "inspect" && (
                    <Button variant="hero" size="sm" onClick={() => setDialog({ action, row })}>
                      Inspect
                    </Button>
                  )}
                  {action === "resolve" && (
                    <Button variant="hero" size="sm" onClick={() => setDialog({ action, row })}>
                      Resolve
                    </Button>
                  )}
                </div>
              </div>

              <ul className="mt-3 divide-y divide-border rounded-xl border border-border text-sm">
                {row.items.map((item) => (
                  <li key={item.id} className="flex flex-wrap justify-between gap-2 p-2">
                    <span>{item.product_name}</span>
                    <span className="text-muted-foreground tabular-nums">
                      {item.quantity_requested} requested
                      {item.quantity_accepted !== null && ` · ${item.quantity_accepted} accepted`}
                      {item.restock && " · restocked"}
                    </span>
                  </li>
                ))}
              </ul>

              {row.wholesaler_note && (
                <p className="mt-2 text-sm">
                  <span className="text-muted-foreground">Supplier note: </span>
                  {row.wholesaler_note}
                </p>
              )}
              {row.status === "resolved" && row.resolution && (
                <p className="mt-2 text-sm font-medium">
                  {RESOLUTION_LABELS[row.resolution]}
                  {row.resolution !== "none" &&
                    row.resolution !== "replacement" &&
                    ` · ${formatGHS(row.resolved_amount_ghs ?? 0)}`}
                </p>
              )}
              <Timeline status={row.status} />
            </Card>
          );
        })
      )}

      {!loading && !error && total > PAGE_SIZE && (
        <div className="flex items-center justify-between text-sm text-muted-foreground">
          <span>
            Page {page + 1} of {pageCount} · {total} returns
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

      <ReviewDialog
        row={dialog?.action === "review" ? dialog.row : null}
        onClose={() => setDialog(null)}
        onDone={() => void load()}
      />
      <InspectDialog
        row={dialog?.action === "inspect" ? dialog.row : null}
        onClose={() => setDialog(null)}
        onDone={() => void load()}
      />
      <ResolveDialog
        row={dialog?.action === "resolve" ? dialog.row : null}
        onClose={() => setDialog(null)}
        onDone={() => void load()}
      />
    </div>
  );
}
