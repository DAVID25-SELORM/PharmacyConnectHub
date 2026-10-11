import { useEffect, useState } from "react";
import { toast } from "sonner";
import { useBlocker } from "@tanstack/react-router";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { db, externalRpc, type Draft } from "@/lib/external-procurement";
import {
  receivedQuantity,
  receiptFromSupplyOrder,
  supplyDraft,
  supplyLine,
  supplyStatus,
  validateSupplyDraft,
  type SupplyDraft,
  type SupplyOrder,
  type SupplyReceipt,
} from "@/lib/external-supply-orders";

export function ExternalSupplyOrders({
  pharmacyId,
  canRecord,
  onReceive,
  onReceipt,
}: {
  pharmacyId: string;
  canRecord: boolean;
  onReceive: (draft: Draft) => void;
  onReceipt: (id: string) => void;
}) {
  const [page, setPage] = useState(0),
    [count, setCount] = useState(0);
  const [orders, setOrders] = useState<SupplyOrder[]>([]),
    [selected, setSelected] = useState<SupplyOrder | null>(null);
  const [receipts, setReceipts] = useState<SupplyReceipt[]>([]),
    [events, setEvents] = useState<{ id: string; action: string; occurred_at: string }[]>([]);
  const [draft, setDraft] = useState<SupplyDraft | null>(null),
    [editing, setEditing] = useState<SupplyOrder | null>(null);
  const [requestId, setRequestId] = useState(crypto.randomUUID()),
    [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [loading, setLoading] = useState(true),
    [revision, setRevision] = useState(0);
  useBlocker({
    shouldBlockFn: () => busy || (!!draft && !window.confirm("Discard this unsaved document?")),
    enableBeforeUnload: !!draft || busy,
  });
  useEffect(() => {
    const protect = (event: Event) => {
      if (
        busy ||
        (draft && !window.confirm("Discard this unsaved document before switching business?"))
      )
        event.preventDefault();
    };
    window.addEventListener("drugxone:before-workspace-change", protect);
    return () => window.removeEventListener("drugxone:before-workspace-change", protect);
  }, [draft, busy]);
  useEffect(() => {
    let live = true;
    setLoading(true);
    setError("");
    db.from("external_supply_orders")
      .select("*", { count: "exact" })
      .eq("pharmacy_id", pharmacyId)
      .order("created_at", { ascending: false })
      .order("id")
      .range(page * 20, page * 20 + 19)
      .then(({ data, error, count }) => {
        if (live) {
          if (error) setError(error.message);
          else {
            setOrders(data as SupplyOrder[]);
            setCount(count ?? 0);
          }
          setLoading(false);
        }
      });
    return () => {
      live = false;
    };
  }, [pharmacyId, revision, page]);
  async function run(fn: () => Promise<void>) {
    setBusy(true);
    try {
      await fn();
      setError("");
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Action failed. Retry.");
    } finally {
      setBusy(false);
    }
  }
  async function open(id: string) {
    const [order, linked, history] = await Promise.all([
      db
        .from("external_supply_orders")
        .select("*")
        .eq("pharmacy_id", pharmacyId)
        .eq("id", id)
        .single(),
      db
        .from("external_purchases")
        .select("id,reference,review_status,external_order_allocations")
        .eq("pharmacy_id", pharmacyId)
        .eq("external_order_id", id),
      db
        .from("external_supply_order_events")
        .select("id,action,occurred_at")
        .eq("order_id", id)
        .order("occurred_at"),
    ]);
    if (order.error || linked.error || history.error)
      throw new Error((order.error || linked.error || history.error)!.message);
    setSelected(order.data as SupplyOrder);
    setReceipts(linked.data as SupplyReceipt[]);
    setEvents(history.data!);
  }
  const start = (value: SupplyDraft, original: SupplyOrder | null = null) => {
    setDraft(structuredClone(value));
    setEditing(original);
    setRequestId(crypto.randomUUID());
    setSelected(null);
  };
  const patch = (p: Partial<SupplyDraft>) => setDraft((d) => (d ? { ...d, ...p } : d));
  const transition = (action: string) =>
    void run(async () => {
      if (!selected) return;
      await externalRpc("transition_external_supply_order", {
        p_id: selected.id,
        p_version: selected.version,
        p_action: action,
      });
      await open(selected.id);
      setRevision((x) => x + 1);
    });
  async function download() {
    if (!selected) return;
    const { data, error } = await db
      .from("external_supply_orders")
      .select("*")
      .eq("pharmacy_id", pharmacyId)
      .eq("id", selected.id)
      .single();
    if (error) throw new Error(error.message);
    const order = data as SupplyOrder;
    let logo: string | undefined;
    const path = order.issuer?.branding?.logo_path;
    if (path) {
      const url = db.storage.from("business-document-logos").getPublicUrl(path).data.publicUrl;
      const response = await fetch(url);
      if (!response.ok) throw new Error("Logo could not be loaded. Retry download.");
      const bitmap = await createImageBitmap(await response.blob());
      const canvas = document.createElement("canvas");
      canvas.width = 320;
      canvas.height = 160;
      const scale = Math.min(320 / bitmap.width, 160 / bitmap.height);
      canvas.getContext("2d")!.drawImage(bitmap, 0, 0, bitmap.width * scale, bitmap.height * scale);
      bitmap.close();
      logo = canvas.toDataURL("image/png");
    }
    const { buildSupplyOrderPdf } = await import("@/lib/external-supply-order-pdf");
    buildSupplyOrderPdf(order, logo).save(`${order.reference}.pdf`);
  }
  return (
    <section className="space-y-4 rounded-xl border p-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-lg font-semibold">Requests & purchase orders</h2>
          <p className="text-sm text-muted-foreground">
            Prepare PDFs to share yourself. Requests and orders do not add stock or make payments.
          </p>
        </div>
        {canRecord && <Button onClick={() => start(supplyDraft())}>New request / order</Button>}
      </div>
      {error && (
        <p role="alert">
          {error}{" "}
          <Button variant="outline" onClick={() => setRevision((x) => x + 1)}>
            Retry
          </Button>
        </p>
      )}
      {loading ? (
        <p role="status">Loading requests and orders…</p>
      ) : !orders.length && !error ? (
        <p>No requests or purchase orders yet.</p>
      ) : null}
      <p className="text-xs text-muted-foreground">
        Open a purchase order to see received quantities. All saved documents remain available
        through pagination.
      </p>
      <div className="grid gap-3 md:grid-cols-2">
        {orders.map((o) => (
          <button
            disabled={busy}
            key={o.id}
            className="rounded-lg border p-4 text-left"
            onClick={() => void run(() => open(o.id))}
          >
            <strong>{o.reference}</strong>
            <p>
              {o.kind === "request" ? "Purchase request" : "Purchase order"} · {o.status}
            </p>
            <p>
              {o.data.supplier} · {o.data.lines.length} items
            </p>
            <p>Required: {o.data.required_date || "To be agreed"}</p>
          </button>
        ))}
      </div>
      <div className="flex items-center gap-3">
        <Button
          variant="outline"
          disabled={busy || loading || page === 0}
          onClick={() => setPage((p) => p - 1)}
        >
          Previous
        </Button>
        <span>
          Page {page + 1} of {Math.max(1, Math.ceil(count / 20))}
        </span>
        <Button
          variant="outline"
          disabled={busy || loading || (page + 1) * 20 >= count}
          onClick={() => setPage((p) => p + 1)}
        >
          Next
        </Button>
      </div>
      <Dialog
        open={!!draft}
        onOpenChange={(v) => {
          if (!v && !busy && window.confirm("Discard this unsaved document?")) setDraft(null);
        }}
      >
        <DialogContent className="max-h-[90vh] max-w-4xl overflow-y-auto">
          <DialogHeader>
            <DialogTitle>{editing ? "Edit draft" : "New request / purchase order"}</DialogTitle>
          </DialogHeader>
          {draft && (
            <form
              className="space-y-4"
              onSubmit={(e) => {
                e.preventDefault();
                void run(async () => {
                  const error = validateSupplyDraft(draft);
                  if (error) throw new Error(error);
                  const id = await externalRpc<string>("save_external_supply_order", {
                    p_pharmacy_id: pharmacyId,
                    p_data: draft,
                    p_request_id: requestId,
                    p_id: editing?.id ?? null,
                    p_version: editing?.version ?? null,
                  });
                  setDraft(null);
                  setRevision((x) => x + 1);
                  await open(id);
                  toast.success("Draft saved. Issue it when ready to share.");
                });
              }}
            >
              <fieldset disabled={busy} className="space-y-4">
                <label className="block">
                  Document type
                  <select
                    className="block w-full rounded border p-2"
                    value={draft.kind}
                    onChange={(e) =>
                      patch({
                        kind: e.target.value as SupplyDraft["kind"],
                        source_request_id:
                          e.target.value === "request" ? undefined : draft.source_request_id,
                      })
                    }
                  >
                    <option value="request">Request availability / quotation</option>
                    <option value="order">Purchase order</option>
                  </select>
                </label>
                <div className="grid gap-3 sm:grid-cols-2">
                  {(
                    [
                      ["supplier", "Supplier / intended recipient"],
                      ["supplier_contact", "Supplier phone / email"],
                      ["required_date", "Required delivery date"],
                      ["delivery_address", "Delivery address"],
                    ] as const
                  ).map(([key, label]) => (
                    <label key={key}>
                      {label}
                      <Input
                        required={key === "supplier"}
                        maxLength={
                          key === "delivery_address" ? 1000 : key === "supplier" ? 200 : 300
                        }
                        type={key === "required_date" ? "date" : "text"}
                        value={draft[key]}
                        onChange={(e) => patch({ [key]: e.target.value })}
                      />
                    </label>
                  ))}
                </div>
                <p className="text-sm">
                  Use the exact medicine, strength and pack size. Quantities are packs. Leave
                  request prices blank when asking for a quotation.
                </p>
                {draft.lines.map((l, index) => (
                  <fieldset key={l.id} className="space-y-2 rounded border p-3">
                    <legend>Item {index + 1}</legend>
                    <div className="grid gap-3 sm:grid-cols-2">
                      {(
                        [
                          ["name", "Medicine / strength / pack"],
                          ["specification", "Specification"],
                        ] as const
                      ).map(([key, label]) => (
                        <label key={key}>
                          {label}
                          <Input
                            required={key === "name"}
                            maxLength={key === "name" ? 300 : 1000}
                            value={l[key]}
                            onChange={(e) =>
                              patch({
                                lines: draft.lines.map((x) =>
                                  x.id === l.id ? { ...x, [key]: e.target.value } : x,
                                ),
                              })
                            }
                          />
                        </label>
                      ))}
                      <label>
                        Quantity (packs)
                        <Input
                          type="number"
                          required
                          min="1"
                          max="1000000"
                          step="1"
                          value={l.quantity}
                          onChange={(e) =>
                            patch({
                              lines: draft.lines.map((x) =>
                                x.id === l.id ? { ...x, quantity: Number(e.target.value) } : x,
                              ),
                            })
                          }
                        />
                      </label>
                      <label>
                        Unit price GHS (optional until issue)
                        <Input
                          type="number"
                          min="0"
                          step="0.01"
                          value={l.unit_price ?? ""}
                          onChange={(e) =>
                            patch({
                              lines: draft.lines.map((x) =>
                                x.id === l.id
                                  ? {
                                      ...x,
                                      unit_price:
                                        e.target.value === "" ? null : Number(e.target.value),
                                    }
                                  : x,
                              ),
                            })
                          }
                        />
                      </label>
                    </div>
                    <Button
                      type="button"
                      variant="ghost"
                      disabled={draft.lines.length === 1}
                      onClick={() => patch({ lines: draft.lines.filter((x) => x.id !== l.id) })}
                    >
                      Remove item {index + 1}
                    </Button>
                  </fieldset>
                ))}
                <Button
                  type="button"
                  variant="outline"
                  disabled={draft.lines.length >= 200}
                  onClick={() => patch({ lines: [...draft.lines, supplyLine()] })}
                >
                  Add item
                </Button>
                <label className="block">
                  Instructions / agreed terms
                  <textarea
                    maxLength={2000}
                    className="block min-h-24 w-full rounded border p-2"
                    value={draft.notes}
                    onChange={(e) => patch({ notes: e.target.value })}
                  />
                </label>
                <Button type="submit">{busy ? "Saving…" : "Save draft"}</Button>
              </fieldset>
            </form>
          )}
        </DialogContent>
      </Dialog>
      <Dialog
        open={!!selected}
        onOpenChange={(v) => {
          if (!v && !busy) setSelected(null);
        }}
      >
        <DialogContent className="max-h-[90vh] max-w-4xl overflow-y-auto">
          <DialogHeader>
            <DialogTitle>{selected?.reference}</DialogTitle>
          </DialogHeader>
          {selected && (
            <div className="space-y-4">
              <p>
                {selected.kind === "request" ? "Request for quotation" : "Purchase order"} ·{" "}
                <strong>{supplyStatus(selected, receipts)}</strong>
              </p>
              <p>
                Supplier: {selected.data.supplier} · {selected.data.supplier_contact}
              </p>
              <p>
                Required: {selected.data.required_date || "To be agreed"} · Delivery:{" "}
                {selected.data.delivery_address || "To be agreed"}
              </p>
              <p className="whitespace-pre-wrap">{selected.data.notes}</p>
              <div className="overflow-x-auto">
                <table className="w-full text-left text-sm">
                  <thead>
                    <tr>
                      <th className="p-2">Item</th>
                      <th className="p-2">Ordered packs</th>
                      <th className="p-2">Received packs</th>
                      <th className="p-2">Unit GHS</th>
                    </tr>
                  </thead>
                  <tbody>
                    {selected.data.lines.map((l) => (
                      <tr key={l.id}>
                        <td className="p-2">
                          {l.name}
                          <p className="text-muted-foreground">{l.specification}</p>
                        </td>
                        <td className="p-2">{l.quantity}</td>
                        <td className="p-2">{receivedQuantity(l.id, receipts)}</td>
                        <td className="p-2">{l.unit_price?.toFixed(2) ?? "Quote requested"}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              <p className="text-sm text-muted-foreground">
                Received means recorded physical delivery, including stock awaiting review or
                rejected. Returns do not reopen the order; create a replacement order if needed.
              </p>
              <div className="flex flex-wrap gap-2">
                {selected.issued_at && (
                  <Button disabled={busy} onClick={() => void run(download)}>
                    Download PDF to share
                  </Button>
                )}
                {canRecord && selected.status === "draft" && (
                  <>
                    <Button
                      disabled={busy}
                      variant="outline"
                      onClick={() => start(selected.data, selected)}
                    >
                      Edit draft
                    </Button>
                    <Button
                      disabled={busy}
                      onClick={() => {
                        if (
                          window.confirm(
                            "Issue and freeze this document? Check supplier, quantities and prices first.",
                          )
                        )
                          transition("issued");
                      }}
                    >
                      Issue document
                    </Button>
                  </>
                )}
                {canRecord && selected.status === "issued" && (
                  <Button
                    disabled={busy}
                    onClick={() => {
                      if (window.confirm("Have you shared this PDF with the supplier yourself?"))
                        transition("shared");
                    }}
                  >
                    Mark as shared manually
                  </Button>
                )}
                {canRecord && selected.kind === "order" && selected.status === "shared" && (
                  <Button
                    disabled={busy}
                    onClick={() => {
                      if (window.confirm("Has the supplier confirmed this order outside Drugxone?"))
                        transition("confirmed");
                    }}
                  >
                    Record supplier confirmation
                  </Button>
                )}
                {canRecord &&
                  selected.kind === "request" &&
                  ["issued", "shared"].includes(selected.status) && (
                    <Button
                      disabled={busy}
                      onClick={() =>
                        start({
                          ...selected.data,
                          kind: "order",
                          source_request_id: selected.id,
                          lines: selected.data.lines.map((l) => ({
                            ...l,
                            id: crypto.randomUUID(),
                          })),
                        })
                      }
                    >
                      Create purchase order from request
                    </Button>
                  )}
                {canRecord &&
                  selected.kind === "order" &&
                  !["draft", "cancelled"].includes(selected.status) &&
                  selected.data.lines.some(
                    (l) => receivedQuantity(l.id, receipts) < l.quantity,
                  ) && (
                    <Button
                      disabled={busy}
                      onClick={() => {
                        onReceive(receiptFromSupplyOrder(selected, receipts));
                        setSelected(null);
                      }}
                    >
                      Record delivery against order
                    </Button>
                  )}
                {canRecord && selected.status !== "cancelled" && (
                  <Button
                    disabled={busy}
                    variant="outline"
                    onClick={() => {
                      if (
                        window.confirm(
                          "Cancel this document and any unreceived balance? Existing receipts remain. Notify the supplier yourself.",
                        )
                      )
                        transition("cancelled");
                    }}
                  >
                    Cancel remaining order
                  </Button>
                )}
              </div>
              <h3 className="font-semibold">Linked receipts</h3>
              {receipts.length ? (
                receipts.map((r) => (
                  <Button
                    key={r.id}
                    variant="outline"
                    disabled={busy}
                    onClick={() => {
                      setSelected(null);
                      onReceipt(r.id);
                    }}
                  >
                    {r.reference} · {r.review_status}
                  </Button>
                ))
              ) : (
                <p>No receipts recorded.</p>
              )}
              <h3 className="font-semibold">Document history</h3>
              {events.map((e) => (
                <p key={e.id} className="text-sm">
                  {e.occurred_at.slice(0, 19).replace("T", " ")} · {e.action.replaceAll("_", " ")}
                </p>
              ))}
            </div>
          )}
        </DialogContent>
      </Dialog>
    </section>
  );
}
