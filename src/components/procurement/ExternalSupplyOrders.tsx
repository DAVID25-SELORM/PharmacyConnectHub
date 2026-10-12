import { ProcurementDocumentReport } from "./ProcurementDocumentReport";
import { SupplyEditor } from "./SupplyEditor";
import { confirmAction } from "@/lib/confirm-action";
import { useEffect, useState } from "react";
import { toast } from "sonner";
import { useBlocker } from "@tanstack/react-router";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import { db, externalRpc, type Draft } from "@/lib/external-procurement";
import {
  receivedQuantity,
  receiptFromSupplyOrder,
  supplyDraft,
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
  receivingEnabled = true,
}: {
  receivingEnabled?: boolean;
  pharmacyId: string;
  canRecord: boolean;
  onReceive: (draft: Draft) => void;
  onReceipt: (id: string) => void;
}) {
  const [showReport, setShowReport] = useState(false);
  const [showCancelled, setShowCancelled] = useState(false);
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
    shouldBlockFn: async () =>
      busy || (!!draft && !(await confirmAction("Discard this unsaved document?"))),
    enableBeforeUnload: false,
  });
  useEffect(() => {
    const protect = (event: Event) => {
      if (draft || busy) {
        event.preventDefault();
        toast.info("Save or close your current changes before switching business.");
      }
    };
    window.addEventListener("drugxone:before-workspace-change", protect);
    return () => window.removeEventListener("drugxone:before-workspace-change", protect);
  }, [draft, busy]);
  useEffect(() => {
    let live = true;
    setLoading(true);
    setError("");
    let query = db
      .from("external_supply_orders")
      .select("*", { count: "exact" })
      .eq("pharmacy_id", pharmacyId);
    if (!showCancelled) query = query.neq("status", "cancelled");
    query
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
  }, [pharmacyId, revision, page, showCancelled]);
  async function run(fn: () => Promise<void>) {
    setBusy(true);
    try {
      await fn();
      setError("");
    } catch (e) {
      setError(e instanceof Error ? e.message : "Action failed. Retry.");
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
      receivingEnabled
        ? db
            .from("external_purchases")
            .select("id,reference,review_status,external_order_allocations")
            .eq("pharmacy_id", pharmacyId)
            .eq("external_order_id", id)
        : Promise.resolve({ data: [], error: null }),
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
    setError("");
    setDraft(structuredClone(value));
    setEditing(original);
    setRequestId(crypto.randomUUID());
    setSelected(null);
  };
  const transition = (action: string) =>
    void run(async () => {
      if (!selected) return;
      await externalRpc("transition_external_supply_order", {
        p_id: selected.id,
        p_version: selected.version,
        p_action: action,
      });
      await open(selected.id);
      setPage(0);
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
    const { loadDocumentLogo } = await import('@/lib/business-document-pdf');
    const path = order.issuer?.branding?.logo_path;
    const logo = await loadDocumentLogo(path ? db.storage.from('business-document-logos').getPublicUrl(path).data.publicUrl : order.issuer?.branding?.logo_url);
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
      <Button variant="outline" onClick={() => setShowReport((v) => !v)}>
        Document history report
      </Button>
      {showReport && <ProcurementDocumentReport businessId={pharmacyId} />}
      <label className="flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          checked={showCancelled}
          onChange={(e) => {
            setShowCancelled(e.target.checked);
            setPage(0);
          }}
        />
        Include cancelled documents and removed drafts
      </label>
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
        onOpenChange={async (v) => {
          if (!v && !busy && (await confirmAction("Discard this unsaved document?")))
            setDraft(null);
        }}
      >
        <DialogContent className="max-h-[94dvh] w-[calc(100vw-1rem)] max-w-6xl overflow-y-auto">
          <DialogHeader>
            <DialogTitle>{editing ? "Edit draft" : "New request / purchase order"}</DialogTitle>
            <DialogDescription>
              Save your draft to continue later, including before closing or refreshing this browser
              tab. Issuing freezes the document.
            </DialogDescription>
          </DialogHeader>
          {draft && (
            <SupplyEditor
              businessId={pharmacyId}
              draft={draft}
              onChange={setDraft}
              busy={busy}
              saveError={error}
              saved={!!editing && JSON.stringify(draft) === JSON.stringify(editing.data)}
              save={() =>
                void run(async () => {
                  const issue = validateSupplyDraft(draft);
                  if (issue) throw new Error(issue);
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
                  toast.success("Draft saved. Continue editing or issue after review.");
                })
              }
            />
          )}
        </DialogContent>
      </Dialog>
      <Dialog
        open={!!selected}
        onOpenChange={async (v) => {
          if (!v && !busy) setSelected(null);
        }}
      >
        <DialogContent className="max-h-[90vh] max-w-4xl overflow-y-auto">
          <DialogHeader>
            <DialogTitle>{selected?.reference}</DialogTitle>
            <DialogDescription>
              Review this document, continue its workflow, or view its history.
            </DialogDescription>
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
                      <th className="p-2">Ordered quantity</th>
                      <th className="p-2">Received quantity</th>
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
                        <td className="p-2">
                          {l.quantity} {l.unit || "packs"}
                        </td>
                        <td className="p-2">{receivedQuantity(l.id, receipts)}</td>
                        <td className="p-2">{l.unit_price?.toFixed(2) ?? "Quote requested"}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              <p className="text-sm text-muted-foreground">
                Issued documents cannot be edited; create a revised draft and cancel any superseded
                balance. Received means recorded physical delivery, including stock awaiting review
                or rejected. Returns do not reopen the order; create a replacement order if needed.
              </p>
              <div className="flex flex-wrap gap-2">
                {selected.issued_at && (
                  <Button disabled={busy} onClick={() => void run(download)}>
                    Download PDF to share
                  </Button>
                )}
                {canRecord && selected.status !== "draft" && (
                  <Button
                    disabled={busy}
                    variant="outline"
                    onClick={() =>
                      start({
                        ...selected.data,
                        source_request_id: undefined,
                        required_date: "",
                        notes: `Revised from ${selected.reference}. Confirm new prices and terms.`,
                        lines: selected.data.lines.map((line) => ({
                          ...line,
                          unit_price: null,
                          id: crypto.randomUUID(),
                        })),
                      })
                    }
                  >
                    Create revised draft
                  </Button>
                )}
                {canRecord && selected.status === "draft" && (
                  <>
                    <Button
                      disabled={busy}
                      variant="outline"
                      onClick={() => start(selected.data, selected)}
                    >
                      Continue / edit draft
                    </Button>
                    <Button
                      disabled={busy}
                      onClick={async () => {
                        if (
                          await confirmAction(
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
                    onClick={async () => {
                      if (
                        await confirmAction("Have you shared this PDF with the supplier yourself?")
                      )
                        transition("shared");
                    }}
                  >
                    Mark as shared manually
                  </Button>
                )}
                {canRecord && selected.kind === "order" && selected.status === "shared" && (
                  <Button
                    disabled={busy}
                    onClick={async () => {
                      if (
                        await confirmAction(
                          "Has the supplier confirmed this order outside Drugxone?",
                        )
                      )
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
                            unit_price: null,
                            id: crypto.randomUUID(),
                          })),
                        })
                      }
                    >
                      Create purchase order from request
                    </Button>
                  )}
                {canRecord &&
                  receivingEnabled &&
                  selected.kind === "order" &&
                  !["draft", "cancelled"].includes(selected.status) &&
                  selected.data.lines.some(
                    (l) => receivedQuantity(l.id, receipts) < l.quantity,
                  ) && (
                    <Button
                      disabled={busy}
                      onClick={async () => {
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
                    onClick={async () => {
                      if (
                        await confirmAction(
                          selected.status === "draft"
                            ? "Remove this draft from active work? It will be marked cancelled and retained in document history."
                            : "Cancel this document and any unreceived balance? Existing receipts remain. Notify the supplier yourself.",
                        )
                      )
                        transition("cancelled");
                    }}
                  >
                    {selected.status === "draft" ? "Remove draft" : "Cancel remaining order"}
                  </Button>
                )}
              </div>
              {selected.data.lines.some((l) => l.unit && l.unit !== "packs") && (
                <p className="text-sm">
                  When recording delivery, confirm inventory packs per ordered unit and the actual
                  cost per inventory pack. No conversion or stock is inferred.
                </p>
              )}
              <h3 className="font-semibold">Linked receipts</h3>
              {receipts.length ? (
                receipts.map((r) => (
                  <Button
                    key={r.id}
                    variant="outline"
                    disabled={busy}
                    onClick={async () => {
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
