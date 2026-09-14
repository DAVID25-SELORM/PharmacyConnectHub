import { useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import type { Database } from "@/integrations/supabase/types";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { toast } from "sonner";
import { persistentOperation } from "@/lib/checkout-request";

type Movement = Database["public"]["Tables"]["inventory_movements"]["Row"];
export function StockDialog({
  product,
  reload,
}: {
  product: { id: string; name: string; stock: number };
  reload: () => Promise<void>;
}) {
  const [open, setOpen] = useState(false);
  const [operation, setOperation] = useState("add");
  const [quantity, setQuantity] = useState("");
  const [reason, setReason] = useState("");
  const [stock, setStock] = useState(product.stock);
  const [history, setHistory] = useState<Movement[]>([]);
  const [busy, setBusy] = useState(false);
  const [loaded, setLoaded] = useState(false);
  async function load() {
    setLoaded(false);
    const [current, movements] = await Promise.all([
      supabase.from("products").select("stock").eq("id", product.id).single(),
      supabase
        .from("inventory_movements")
        .select("*")
        .eq("product_id", product.id)
        .order("created_at", { ascending: false })
        .limit(100),
    ]);
    if (current.error || movements.error) {
      toast.error(current.error?.message ?? movements.error?.message);
      return;
    }
    setStock(current.data.stock);
    setHistory(movements.data);
    setLoaded(true);
  }
  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (
      !/^\d+$/.test(quantity) ||
      !Number.isSafeInteger(Number(quantity)) ||
      (operation !== "reconcile" && Number(quantity) === 0)
    ) {
      toast.error("Enter a whole quantity; Add and Remove require more than zero.");
      return;
    }
    setBusy(true);
    try {
      const {
        data: { session },
      } = await supabase.auth.getSession();
      if (!session) throw new Error("Sign in first.");
      const expected = operation === "reconcile" ? stock : undefined;
      const payload = JSON.stringify([operation, quantity, reason, expected]);
      const next = persistentOperation(`stock.${session.user.id}.${product.id}`, payload);
      const { error } = await supabase.rpc("adjust_product_stock", {
        _product_id: product.id,
        _operation: operation,
        _quantity: Number(quantity),
        _request_id: next.id,
        _expected_stock: expected,
        _reason: reason,
      });
      if (error) throw new Error(error.message);
      localStorage.removeItem(next.key);
      setQuantity("");
      setReason("");
      toast.success("Stock operation completed");
      await load();
      await reload();
    } catch (error) {
      toast.error(
        error instanceof Error
          ? error.message
          : "Stock operation failed. Retry the same action safely.",
      );
    } finally {
      setBusy(false);
    }
  }
  return (
    <Dialog
      open={open}
      onOpenChange={(value) => {
        setOpen(value);
        if (value) void load();
      }}
    >
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">
          Stock
        </Button>
      </DialogTrigger>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-3xl">
        <DialogHeader>
          <DialogTitle>Stock: {product.name}</DialogTitle>
        </DialogHeader>
        <p>Current system stock: {loaded ? stock : "Loading…"}</p>
        <form onSubmit={submit} className="space-y-3">
          <Label htmlFor={`stock-operation-${product.id}`}>Operation</Label>
          <select
            id={`stock-operation-${product.id}`}
            className="w-full rounded border p-2"
            value={operation}
            onChange={(e) => setOperation(e.target.value)}
            disabled={busy}
          >
            <option value="add">Add stock</option>
            <option value="remove">Remove stock</option>
            <option value="reconcile">Reconcile physical count</option>
          </select>
          <Label htmlFor={`stock-quantity-${product.id}`}>
            {operation === "reconcile" ? "New physical count" : "Quantity"}
          </Label>
          <Input
            id={`stock-quantity-${product.id}`}
            type="number"
            min={operation === "reconcile" ? 0 : 1}
            step="1"
            required
            value={quantity}
            onChange={(e) => setQuantity(e.target.value)}
            disabled={busy}
          />
          {quantity !== "" && (
            <p>
              Difference:{" "}
              {operation === "reconcile"
                ? Number(quantity) - stock
                : operation === "remove"
                  ? -Number(quantity)
                  : Number(quantity)}
            </p>
          )}
          <Label htmlFor={`stock-reason-${product.id}`}>Reason (optional)</Label>
          <Input
            id={`stock-reason-${product.id}`}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            disabled={busy}
          />
          <Button type="submit" disabled={busy || !loaded}>
            {busy
              ? "Saving…"
              : operation === "reconcile"
                ? "Confirm reconciliation"
                : "Confirm stock adjustment"}
          </Button>
          <Button type="button" variant="outline" disabled={busy} onClick={() => void load()}>
            Refresh stock
          </Button>
        </form>
        <h3 className="font-semibold">Recent inventory movements (latest 100)</h3>
        <div className="overflow-x-auto">
          <table className="w-full text-xs">
            <thead>
              <tr>
                <th>Date</th>
                <th>Type</th>
                <th>Change</th>
                <th>Before → After</th>
                <th>Reference / actor / reason</th>
              </tr>
            </thead>
            <tbody>
              {history.map((m) => (
                <tr key={m.id} className="border-t">
                  <td className="p-2">{new Date(m.created_at).toLocaleString()}</td>
                  <td>{m.movement_type}</td>
                  <td>
                    {m.quantity_delta > 0 ? "+" : ""}
                    {m.quantity_delta}
                  </td>
                  <td>
                    {m.quantity_before} → {m.quantity_after}
                  </td>
                  <td className="max-w-64 break-all p-2">
                    {m.order_id ??
                      m.import_run_id ??
                      m.request_id ??
                      "Product creation / maintenance"}
                    <br />
                    Actor: {m.actor_id ?? "Database maintenance (human not recorded)"}
                    <br />
                    {m.reason}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {loaded && history.length === 0 && (
          <p>No stock movements recorded since the opening balance.</p>
        )}
      </DialogContent>
    </Dialog>
  );
}
