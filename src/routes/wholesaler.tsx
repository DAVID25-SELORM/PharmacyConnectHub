import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect, useEffectEvent, useState } from "react";
import {
  Package,
  ShoppingBag,
  TrendingUp,
  Wallet,
  Plus,
  Search,
  Pill,
  Loader2,
  Edit,
  Trash2,
  Upload,
  Download,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Textarea } from "@/components/ui/textarea";
import { toast } from "sonner";
import { useSession } from "@/hooks/use-session";
import { supabase } from "@/integrations/supabase/client";
import { formatGHS, timeAgo, PRODUCT_CATEGORIES } from "@/lib/format";
import { DashboardHeader, VerificationBanner } from "@/components/DashboardShell";
import {
  StatusBadge,
  PaymentBadge,
  OrderTimeline,
  type OrderStatus,
} from "@/components/order-status";

export const Route = createFileRoute("/wholesaler")({
  head: () => ({
    meta: [
      { title: "Wholesaler Dashboard — PharmaHub GH" },
      { name: "description", content: "Manage inventory, receive orders, update fulfilment." },
    ],
  }),
  component: WholesalerDashboard,
});

type Product = {
  id: string;
  name: string;
  brand: string | null;
  category: string | null;
  form: string | null;
  pack_size: string | null;
  price_ghs: number;
  stock: number;
  active: boolean;
};

type OrderRow = {
  id: string;
  order_number: string;
  status: OrderStatus;
  total_ghs: number;
  created_at: string;
  payment_method: "cod" | "paystack";
  payment_status: "unpaid" | "paid" | "refunded" | "failed";
  accepted_at: string | null;
  packed_at: string | null;
  dispatched_at: string | null;
  delivered_at: string | null;
  cancelled_at: string | null;
  cancellation_reason: string | null;
  pharmacy: { name: string; city: string | null } | null;
  order_items: { product_name: string; quantity: number; unit_price_ghs: number }[];
};

function WholesalerDashboard() {
  const navigate = useNavigate();
  const { loading, user, business, roles } = useSession();
  const businessId = business?.id ?? null;
  const [products, setProducts] = useState<Product[]>([]);
  const [orders, setOrders] = useState<OrderRow[]>([]);

  useEffect(() => {
    if (loading) return;
    if (!user) {
      navigate({ to: "/login" });
      return;
    }
    if (roles.includes("admin") && !business) {
      navigate({ to: "/admin" });
      return;
    }
    if (business && business.type !== "wholesaler") {
      navigate({ to: business.type === "pharmacy" ? "/pharmacy" : "/dashboard" });
    }
  }, [loading, user, business, roles, navigate]);

  const loadProducts = useEffectEvent(async () => {
    if (!business) return;
    const { data } = await supabase
      .from("products")
      .select("*")
      .eq("wholesaler_id", business.id)
      .order("created_at", { ascending: false });
    setProducts((data as Product[]) ?? []);
  });

  const loadOrders = useEffectEvent(async () => {
    if (!business) return;
    const { data } = await supabase
      .from("orders")
      .select(
        "id,order_number,status,total_ghs,created_at,payment_method,payment_status,accepted_at,packed_at,dispatched_at,delivered_at,cancelled_at,cancellation_reason,pharmacy:businesses!orders_pharmacy_id_fkey(name,city),order_items(product_name,quantity,unit_price_ghs)",
      )
      .eq("wholesaler_id", business.id)
      .order("created_at", { ascending: false });
    setOrders((data as unknown as OrderRow[]) ?? []);
  });

  useEffect(() => {
    if (businessId) {
      void loadProducts();
      void loadOrders();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [businessId]);

  const updateOrderStatus = async (id: string, status: OrderStatus) => {
    const { error } = await supabase.from("orders").update({ status }).eq("id", id);
    if (error) {
      toast.error(error.message);
      return;
    }
    toast.success(`Marked ${status}`);
    void loadOrders();
  };

  const cancelOrder = async (id: string, reason: string) => {
    const { error } = await supabase
      .from("orders")
      .update({ status: "cancelled", cancellation_reason: reason })
      .eq("id", id);
    if (error) {
      toast.error(error.message);
      return;
    }
    toast.success("Order cancelled");
    void loadOrders();
  };

  if (loading || !business) {
    return (
      <div className="flex min-h-screen items-center justify-center text-muted-foreground">
        <Pill className="h-5 w-5 animate-pulse" />
        <span className="ml-2">Loading…</span>
      </div>
    );
  }

  const canManageProducts = business.staff_role === "owner" || business.staff_role === "manager";
  const canProcessOrders = business.staff_role !== "assistant";
  const pending = orders.filter((o) => o.status === "pending").length;
  const revenue = orders
    .filter((o) => o.status === "delivered")
    .reduce((s, o) => s + Number(o.total_ghs), 0);

  const stats = [
    { label: "Pending orders", value: pending, icon: ShoppingBag, color: "text-warning" },
    {
      label: "Active SKUs",
      value: products.filter((p) => p.active).length,
      icon: Package,
      color: "text-primary",
    },
    {
      label: "Revenue (delivered)",
      value: formatGHS(revenue),
      icon: Wallet,
      color: "text-success",
    },
    { label: "Total orders", value: orders.length, icon: TrendingUp, color: "text-accent" },
  ];

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader
        subtitle="Wholesaler workspace"
        showNav={true}
        isAdmin={roles.includes("admin")}
      />
      <main className="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 py-8">
        <div className="mb-6">
          <h1 className="font-display text-3xl font-bold">{business.name}</h1>
          <p className="mt-1 text-muted-foreground">
            Manage incoming orders, inventory, and fulfilment.
          </p>
        </div>

        <VerificationBanner business={business} />

        <div className="grid gap-4 mb-8 sm:grid-cols-2 lg:grid-cols-4">
          {stats.map((s) => (
            <Card key={s.label} className="p-5">
              <div className="flex items-center justify-between">
                <div>
                  <div className="text-xs uppercase tracking-wider text-muted-foreground">
                    {s.label}
                  </div>
                  <div className="mt-2 font-display text-2xl font-bold">{s.value}</div>
                </div>
                <div
                  className={`flex h-10 w-10 items-center justify-center rounded-xl bg-muted ${s.color}`}
                >
                  <s.icon className="h-5 w-5" />
                </div>
              </div>
            </Card>
          ))}
        </div>

        <Tabs defaultValue="orders" className="w-full">
          <TabsList className="mb-6">
            <TabsTrigger value="orders">Incoming orders ({orders.length})</TabsTrigger>
            <TabsTrigger value="products">My products ({products.length})</TabsTrigger>
          </TabsList>

          <TabsContent value="orders">
            <OrdersInbox
              orders={orders}
              updateStatus={updateOrderStatus}
              cancelOrder={cancelOrder}
              canManageOrders={canProcessOrders}
            />
          </TabsContent>
          <TabsContent value="products">
            <ProductsManager
              products={products}
              businessId={business.id}
              reload={loadProducts}
              canManageProducts={canManageProducts}
            />
          </TabsContent>
        </Tabs>
      </main>
    </div>
  );
}

function OrdersInbox({
  orders,
  updateStatus,
  cancelOrder,
  canManageOrders,
}: {
  orders: OrderRow[];
  updateStatus: (id: string, status: OrderStatus) => void;
  cancelOrder: (id: string, reason: string) => Promise<void>;
  canManageOrders: boolean;
}) {
  const nextStatus: Record<OrderStatus, OrderStatus | null> = {
    pending: "accepted",
    accepted: "packed",
    packed: "dispatched",
    dispatched: "delivered",
    delivered: null,
    cancelled: null,
  };
  const nextLabel: Record<OrderStatus, string> = {
    pending: "Accept order",
    accepted: "Mark packed",
    packed: "Mark dispatched",
    dispatched: "Mark delivered",
    delivered: "Completed",
    cancelled: "Cancelled",
  };

  if (orders.length === 0) {
    return <Card className="p-12 text-center text-muted-foreground">No orders yet.</Card>;
  }

  return (
    <div className="space-y-4">
      {orders.map((o) => {
        const next = nextStatus[o.status];
        return (
          <Card key={o.id} className="p-5">
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div>
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-display text-lg font-bold">{o.order_number}</span>
                  <StatusBadge status={o.status} />
                  <PaymentBadge method={o.payment_method} status={o.payment_status} />
                </div>
                <div className="mt-1 text-sm">
                  <span className="text-muted-foreground">From</span>{" "}
                  <span className="font-medium">{o.pharmacy?.name ?? "—"}</span>
                  <span className="text-muted-foreground">
                    {" "}
                    · {o.pharmacy?.city ?? ""} · {timeAgo(o.created_at)}
                  </span>
                </div>
              </div>
              <div className="text-right">
                <div className="font-display text-xl font-bold">{formatGHS(o.total_ghs)}</div>
                <div className="text-xs text-muted-foreground">{o.order_items.length} item(s)</div>
              </div>
            </div>

            <OrderTimeline o={o} />

            <div className="mt-4 divide-y divide-border rounded-xl border border-border">
              {o.order_items.map((it, i) => (
                <div key={i} className="flex items-center justify-between p-3 text-sm">
                  <div>
                    <div className="font-medium">{it.product_name}</div>
                    <div className="text-xs text-muted-foreground">
                      {formatGHS(it.unit_price_ghs)} × {it.quantity}
                    </div>
                  </div>
                  <div className="font-medium">
                    {formatGHS(Number(it.unit_price_ghs) * it.quantity)}
                  </div>
                </div>
              ))}
            </div>

            <div className="mt-4 flex flex-wrap items-center justify-end gap-2">
              {canManageOrders && (o.status === "pending" || o.status === "accepted") && (
                <CancelOrderDialog
                  orderNumber={o.order_number}
                  onConfirm={(reason) => cancelOrder(o.id, reason)}
                />
              )}
              {canManageOrders && next && (
                <Button variant="hero" size="sm" onClick={() => updateStatus(o.id, next)}>
                  {nextLabel[o.status]}
                </Button>
              )}
            </div>
          </Card>
        );
      })}
    </div>
  );
}

function CancelOrderDialog({
  orderNumber,
  onConfirm,
}: {
  orderNumber: string;
  onConfirm: (reason: string) => Promise<void>;
}) {
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [submitting, setSubmitting] = useState(false);

  const submit = async () => {
    const trimmed = reason.trim();
    if (trimmed.length < 5) {
      toast.error("Please provide a brief reason (min 5 characters)");
      return;
    }
    setSubmitting(true);
    await onConfirm(trimmed);
    setSubmitting(false);
    setOpen(false);
    setReason("");
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">
          Decline
        </Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Decline order {orderNumber}</DialogTitle>
          <DialogDescription>
            The buyer will see this reason. Be clear so they can re-order if appropriate.
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-2">
          <Label htmlFor="cancel-reason">Reason for declining</Label>
          <Textarea
            id="cancel-reason"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="e.g. Out of stock, item discontinued, delivery area not served…"
            rows={4}
            maxLength={500}
          />
          <div className="text-right text-xs text-muted-foreground">{reason.length}/500</div>
        </div>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => setOpen(false)}>
            Keep order
          </Button>
          <Button type="button" variant="destructive" onClick={submit} disabled={submitting}>
            {submitting && <Loader2 className="h-4 w-4 animate-spin" />} Decline order
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function ProductsManager({
  products,
  businessId,
  reload,
  canManageProducts,
}: {
  products: Product[];
  businessId: string;
  reload: () => Promise<void>;
  canManageProducts: boolean;
}) {
  const [query, setQuery] = useState("");
  const list = products.filter((p) => !query || p.name.toLowerCase().includes(query.toLowerCase()));

  return (
    <div>
      <Card className="p-4 mb-6 shadow-soft">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
          <div className="relative flex-1">
            <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              placeholder="Search your products…"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              className="pl-9"
            />
          </div>
          {canManageProducts ? (
            <div className="flex gap-2">
              <BulkUploadDialog businessId={businessId} reload={reload} />
              <AddProductDialog businessId={businessId} reload={reload} />
            </div>
          ) : (
            <div className="text-sm text-muted-foreground">
              View-only access. Ask the business owner for manager access to edit products.
            </div>
          )}
        </div>
      </Card>

      {list.length === 0 ? (
        <Card className="p-12 text-center text-muted-foreground">
          {products.length === 0
            ? "Add your first product to start receiving orders."
            : "No products match."}
        </Card>
      ) : (
        <Card className="overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="bg-surface-muted text-left text-xs uppercase tracking-wider text-muted-foreground">
                <tr>
                  <th className="px-4 py-3 font-medium">Product</th>
                  <th className="px-4 py-3 font-medium">Category</th>
                  <th className="px-4 py-3 font-medium">Pack</th>
                  <th className="px-4 py-3 font-medium text-right">Price</th>
                  <th className="px-4 py-3 font-medium text-right">Stock</th>
                  <th className="px-4 py-3 font-medium">Status</th>
                  {canManageProducts && <th className="px-4 py-3 font-medium">Actions</th>}
                </tr>
              </thead>
              <tbody className="divide-y divide-border">
                {list.map((p) => (
                  <tr key={p.id} className="hover:bg-muted/40">
                    <td className="px-4 py-3">
                      <div className="font-medium">{p.name}</div>
                      <div className="text-xs text-muted-foreground">{p.brand ?? "—"}</div>
                    </td>
                    <td className="px-4 py-3 text-muted-foreground">{p.category ?? "—"}</td>
                    <td className="px-4 py-3 text-muted-foreground">{p.pack_size ?? "—"}</td>
                    <td className="px-4 py-3 text-right font-medium">{formatGHS(p.price_ghs)}</td>
                    <td className="px-4 py-3 text-right">{p.stock}</td>
                    <td className="px-4 py-3">
                      {p.stock < 100 ? (
                        <Badge
                          variant="secondary"
                          className="bg-warning/15 text-warning-foreground border border-warning/30"
                        >
                          Low stock
                        </Badge>
                      ) : (
                        <Badge
                          variant="secondary"
                          className="bg-success/15 text-success border border-success/25"
                        >
                          Active
                        </Badge>
                      )}
                    </td>
                    {canManageProducts && (
                      <td className="px-4 py-3">
                        <div className="flex items-center gap-2">
                          <EditProductDialog product={p} reload={reload} />
                          <DeleteProductDialog product={p} reload={reload} />
                        </div>
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Card>
      )}
    </div>
  );
}

function AddProductDialog({
  businessId,
  reload,
}: {
  businessId: string;
  reload: () => Promise<void>;
}) {
  const [open, setOpen] = useState(false);
  const [saving, setSaving] = useState(false);
  const [form, setForm] = useState({
    name: "",
    brand: "",
    category: "Antibiotics",
    form: "Tablet",
    pack_size: "",
    price_ghs: "",
    stock: "",
    image_hue: "200",
  });

  const update = (k: keyof typeof form, v: string) => setForm((s) => ({ ...s, [k]: v }));

  const onSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.name.trim() || !form.price_ghs) {
      toast.error("Name and price are required");
      return;
    }
    setSaving(true);
    const { error } = await supabase.from("products").insert({
      wholesaler_id: businessId,
      name: form.name.trim(),
      brand: form.brand.trim() || null,
      category: form.category,
      form: form.form,
      pack_size: form.pack_size.trim() || null,
      price_ghs: Number(form.price_ghs),
      stock: Number(form.stock || 0),
      image_hue: Number(form.image_hue || 200),
    });
    setSaving(false);
    if (error) {
      toast.error(error.message);
      return;
    }
    toast.success("Product added");
    setForm({
      name: "",
      brand: "",
      category: "Antibiotics",
      form: "Tablet",
      pack_size: "",
      price_ghs: "",
      stock: "",
      image_hue: "200",
    });
    setOpen(false);
    void reload();
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="hero">
          <Plus className="h-4 w-4" /> Add product
        </Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>Add a product</DialogTitle>
        </DialogHeader>
        <form onSubmit={onSubmit} className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="p-name">Name *</Label>
            <Input
              id="p-name"
              value={form.name}
              onChange={(e) => update("name", e.target.value)}
              placeholder="e.g. Amoxicillin 500mg"
              required
            />
          </div>
          <div className="grid gap-4 sm:grid-cols-2">
            <div className="space-y-2">
              <Label htmlFor="p-brand">Brand</Label>
              <Input
                id="p-brand"
                value={form.brand}
                onChange={(e) => update("brand", e.target.value)}
                placeholder="GSK"
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="p-cat">Category</Label>
              <Select value={form.category} onValueChange={(v) => update("category", v)}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {PRODUCT_CATEGORIES.map((c) => (
                    <SelectItem key={c} value={c}>
                      {c}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>
          <div className="grid gap-4 sm:grid-cols-2">
            <div className="space-y-2">
              <Label htmlFor="p-form">Form</Label>
              <Select value={form.form} onValueChange={(v) => update("form", v)}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {["Tablet", "Capsule", "Syrup", "Injection", "Cream", "Drops", "Sachet"].map(
                    (f) => (
                      <SelectItem key={f} value={f}>
                        {f}
                      </SelectItem>
                    ),
                  )}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-2">
              <Label htmlFor="p-pack">Pack size</Label>
              <Input
                id="p-pack"
                value={form.pack_size}
                onChange={(e) => update("pack_size", e.target.value)}
                placeholder="100s"
              />
            </div>
          </div>
          <div className="grid gap-4 sm:grid-cols-3">
            <div className="space-y-2">
              <Label htmlFor="p-price">Price (GH₵) *</Label>
              <Input
                id="p-price"
                type="number"
                step="0.01"
                min="0"
                value={form.price_ghs}
                onChange={(e) => update("price_ghs", e.target.value)}
                required
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="p-stock">Stock</Label>
              <Input
                id="p-stock"
                type="number"
                min="0"
                value={form.stock}
                onChange={(e) => update("stock", e.target.value)}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="p-hue">Color hue</Label>
              <Input
                id="p-hue"
                type="number"
                min="0"
                max="360"
                value={form.image_hue}
                onChange={(e) => update("image_hue", e.target.value)}
              />
            </div>
          </div>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => setOpen(false)}>
              Cancel
            </Button>
            <Button type="submit" variant="hero" disabled={saving}>
              {saving && <Loader2 className="h-4 w-4 animate-spin" />} Add product
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function EditProductDialog({
  product,
  reload,
}: {
  product: Product;
  reload: () => Promise<void>;
}) {
  const [open, setOpen] = useState(false);
  const [saving, setSaving] = useState(false);
  const [form, setForm] = useState({
    name: product.name,
    brand: product.brand ?? "",
    category: product.category ?? "Antibiotics",
    form: product.form ?? "Tablet",
    pack_size: product.pack_size ?? "",
    price_ghs: product.price_ghs.toString(),
    stock: product.stock.toString(),
    image_hue: (product.image_hue ?? 200).toString(),
  });

  const update = (k: keyof typeof form, v: string) => setForm((s) => ({ ...s, [k]: v }));

  const onSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.name.trim() || !form.price_ghs) {
      toast.error("Name and price are required");
      return;
    }
    setSaving(true);
    const { error } = await supabase
      .from("products")
      .update({
        name: form.name.trim(),
        brand: form.brand.trim() || null,
        category: form.category,
        form: form.form,
        pack_size: form.pack_size.trim() || null,
        price_ghs: Number(form.price_ghs),
        stock: Number(form.stock || 0),
        image_hue: Number(form.image_hue || 200),
      })
      .eq("id", product.id);
    setSaving(false);
    if (error) {
      toast.error(error.message);
      return;
    }
    toast.success("Product updated");
    setOpen(false);
    void reload();
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="ghost" size="sm">
          <Edit className="h-4 w-4" />
        </Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>Edit product</DialogTitle>
        </DialogHeader>
        <form onSubmit={onSubmit} className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="e-name">Name *</Label>
            <Input
              id="e-name"
              value={form.name}
              onChange={(e) => update("name", e.target.value)}
              placeholder="e.g. Amoxicillin 500mg"
              required
            />
          </div>
          <div className="grid gap-4 sm:grid-cols-2">
            <div className="space-y-2">
              <Label htmlFor="e-brand">Brand</Label>
              <Input
                id="e-brand"
                value={form.brand}
                onChange={(e) => update("brand", e.target.value)}
                placeholder="GSK"
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="e-cat">Category</Label>
              <Select value={form.category} onValueChange={(v) => update("category", v)}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {PRODUCT_CATEGORIES.map((c) => (
                    <SelectItem key={c} value={c}>
                      {c}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>
          <div className="grid gap-4 sm:grid-cols-2">
            <div className="space-y-2">
              <Label htmlFor="e-form">Form</Label>
              <Select value={form.form} onValueChange={(v) => update("form", v)}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {["Tablet", "Capsule", "Syrup", "Injection", "Cream", "Drops", "Sachet"].map(
                    (f) => (
                      <SelectItem key={f} value={f}>
                        {f}
                      </SelectItem>
                    ),
                  )}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-2">
              <Label htmlFor="e-pack">Pack size</Label>
              <Input
                id="e-pack"
                value={form.pack_size}
                onChange={(e) => update("pack_size", e.target.value)}
                placeholder="100s"
              />
            </div>
          </div>
          <div className="grid gap-4 sm:grid-cols-3">
            <div className="space-y-2">
              <Label htmlFor="e-price">Price (GH₵) *</Label>
              <Input
                id="e-price"
                type="number"
                step="0.01"
                min="0"
                value={form.price_ghs}
                onChange={(e) => update("price_ghs", e.target.value)}
                required
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="e-stock">Stock</Label>
              <Input
                id="e-stock"
                type="number"
                min="0"
                value={form.stock}
                onChange={(e) => update("stock", e.target.value)}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="e-hue">Color hue</Label>
              <Input
                id="e-hue"
                type="number"
                min="0"
                max="360"
                value={form.image_hue}
                onChange={(e) => update("image_hue", e.target.value)}
              />
            </div>
          </div>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => setOpen(false)}>
              Cancel
            </Button>
            <Button type="submit" variant="hero" disabled={saving}>
              {saving && <Loader2 className="h-4 w-4 animate-spin" />} Save changes
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function DeleteProductDialog({
  product,
  reload,
}: {
  product: Product;
  reload: () => Promise<void>;
}) {
  const [open, setOpen] = useState(false);
  const [deleting, setDeleting] = useState(false);

  const onDelete = async () => {
    setDeleting(true);
    const { error } = await supabase.from("products").delete().eq("id", product.id);
    setDeleting(false);
    if (error) {
      toast.error(error.message);
      return;
    }
    toast.success("Product deleted");
    setOpen(false);
    void reload();
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="ghost" size="sm">
          <Trash2 className="h-4 w-4 text-destructive" />
        </Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Delete product</DialogTitle>
          <DialogDescription>
            Are you sure you want to delete <strong>{product.name}</strong>? This action cannot be
            undone.
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => setOpen(false)}>
            Cancel
          </Button>
          <Button type="button" variant="destructive" onClick={onDelete} disabled={deleting}>
            {deleting && <Loader2 className="h-4 w-4 animate-spin" />} Delete
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function BulkUploadDialog({
  businessId,
  reload,
}: {
  businessId: string;
  reload: () => Promise<void>;
}) {
  const [open, setOpen] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [file, setFile] = useState<File | null>(null);

  const downloadTemplate = () => {
    const csvContent = `name,brand,category,form,pack_size,price_ghs,stock,image_hue
Paracetamol 500mg,GSK,Analgesics & Pain Relief,Tablet,1000s,42.00,500,70
Amoxicillin 500mg,Aurobindo,Antibiotics,Capsule,100s,28.50,240,195
Ibuprofen 400mg,Reckitt,Analgesics & Pain Relief,Tablet,100s,24.50,470,10`;
    
    const blob = new Blob([csvContent], { type: "text/csv" });
    const url = window.URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = "product-upload-template.csv";
    a.click();
    window.URL.revokeObjectURL(url);
  };

  const parseCSV = (text: string): Array<Record<string, string>> => {
    const lines = text.trim().split("\n");
    if (lines.length < 2) return [];
    
    const headers = lines[0].split(",").map((h) => h.trim());
    const rows: Array<Record<string, string>> = [];
    
    for (let i = 1; i < lines.length; i++) {
      const values = lines[i].split(",").map((v) => v.trim());
      if (values.length !== headers.length) continue;
      
      const row: Record<string, string> = {};
      headers.forEach((header, index) => {
        row[header] = values[index];
      });
      rows.push(row);
    }
    
    return rows;
  };

  const onUpload = async () => {
    if (!file) {
      toast.error("Please select a CSV file");
      return;
    }

    setUploading(true);
    try {
      const text = await file.text();
      const rows = parseCSV(text);

      if (rows.length === 0) {
        toast.error("No valid products found in CSV");
        setUploading(false);
        return;
      }

      const products = rows.map((row) => ({
        wholesaler_id: businessId,
        name: row.name?.trim() || "",
        brand: row.brand?.trim() || null,
        category: row.category?.trim() || "Other",
        form: row.form?.trim() || "Tablet",
        pack_size: row.pack_size?.trim() || null,
        price_ghs: Number(row.price_ghs) || 0,
        stock: Number(row.stock) || 0,
        image_hue: Number(row.image_hue) || 200,
      }));

      // Validate required fields
      const invalid = products.filter((p) => !p.name || p.price_ghs <= 0);
      if (invalid.length > 0) {
        toast.error(`${invalid.length} product(s) missing name or valid price. Please fix and retry.`);
        setUploading(false);
        return;
      }

      const { error } = await supabase.from("products").insert(products);

      if (error) {
        toast.error(error.message);
        setUploading(false);
        return;
      }

      toast.success(`Successfully uploaded ${products.length} product(s)`);
      setOpen(false);
      setFile(null);
      void reload();
    } catch (err) {
      toast.error("Failed to parse CSV file. Please check the format.");
    } finally {
      setUploading(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline">
          <Upload className="h-4 w-4" /> Bulk upload
        </Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>Bulk upload products</DialogTitle>
          <DialogDescription>
            Upload multiple products at once using a CSV file.
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-4">
          <div className="rounded-xl border border-border bg-muted/30 p-4">
            <h4 className="mb-2 text-sm font-medium">Step 1: Download template</h4>
            <p className="mb-3 text-xs text-muted-foreground">
              Download our CSV template with sample products to see the required format.
            </p>
            <Button variant="outline" size="sm" onClick={downloadTemplate}>
              <Download className="h-4 w-4" /> Download template
            </Button>
          </div>

          <div className="rounded-xl border border-border bg-muted/30 p-4">
            <h4 className="mb-2 text-sm font-medium">Step 2: Fill in your products</h4>
            <p className="mb-2 text-xs text-muted-foreground">
              Open the template in Excel or Google Sheets and add your products.
            </p>
            <ul className="space-y-1 text-xs text-muted-foreground">
              <li>• <strong>name</strong> and <strong>price_ghs</strong> are required</li>
              <li>• Use exact category names from the dropdown</li>
              <li>• Save as CSV format when done</li>
            </ul>
          </div>

          <div className="rounded-xl border border-border bg-muted/30 p-4">
            <h4 className="mb-2 text-sm font-medium">Step 3: Upload CSV file</h4>
            <Input
              type="file"
              accept=".csv"
              onChange={(e) => setFile(e.target.files?.[0] || null)}
            />
            {file && (
              <p className="mt-2 text-xs text-muted-foreground">
                Selected: {file.name} ({(file.size / 1024).toFixed(1)} KB)
              </p>
            )}
          </div>
        </div>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => setOpen(false)}>
            Cancel
          </Button>
          <Button type="button" variant="hero" onClick={onUpload} disabled={uploading || !file}>
            {uploading && <Loader2 className="h-4 w-4 animate-spin" />} Upload products
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}


