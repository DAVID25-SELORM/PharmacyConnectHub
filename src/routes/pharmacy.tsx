import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect, useEffectEvent, useMemo, useState } from "react";
import {
  Search,
  ShoppingCart,
  Plus,
  Minus,
  Trash2,
  Package,
  ShieldCheck,
  CreditCard,
  Banknote,
} from "lucide-react";
import { Pill } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
  SheetFooter,
} from "@/components/ui/sheet";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { toast } from "sonner";
import { useSession } from "@/hooks/use-session";
import { supabase } from "@/integrations/supabase/client";
import { formatGHS, timeAgo, PRODUCT_CATEGORIES } from "@/lib/format";
import { DashboardHeader, VerificationBanner } from "@/components/DashboardShell";
import { StatusBadge, PaymentBadge, OrderTimeline } from "@/components/order-status";

export const Route = createFileRoute("/pharmacy")({
  head: () => ({
    meta: [
      { title: "Pharmacy Dashboard — PharmaHub GH" },
      { name: "description", content: "Browse medicines, compare prices, place orders." },
    ],
  }),
  component: PharmacyDashboard,
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
  image_hue: number | null;
  wholesaler_id: string;
  wholesaler: { id: string; name: string; city: string | null; region: string | null } | null;
};

type CartItem = { productId: string; quantity: number };

type OrderRow = {
  id: string;
  order_number: string;
  status: "pending" | "accepted" | "packed" | "dispatched" | "delivered" | "cancelled";
  total_ghs: number;
  created_at: string;
  payment_method: "cod" | "paystack";
  payment_status: "unpaid" | "paid" | "refunded" | "failed";
  paystack_reference: string | null;
  accepted_at: string | null;
  packed_at: string | null;
  dispatched_at: string | null;
  delivered_at: string | null;
  cancelled_at: string | null;
  paid_at: string | null;
  wholesaler: { name: string } | null;
  order_items: { product_name: string; quantity: number; unit_price_ghs: number }[];
};

function PharmacyDashboard() {
  const navigate = useNavigate();
  const { loading, user, business, roles } = useSession();
  const businessId = business?.id ?? null;
  const [cart, setCart] = useState<CartItem[]>([]);
  const [products, setProducts] = useState<Product[]>([]);
  const [orders, setOrders] = useState<OrderRow[]>([]);
  const [paymentMethod, setPaymentMethod] = useState<"cod" | "paystack">("paystack");
  const [placing, setPlacing] = useState(false);

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
    if (business && business.type !== "pharmacy") {
      navigate({ to: business.type === "wholesaler" ? "/wholesaler" : "/dashboard" });
    }
  }, [loading, user, business, roles, navigate]);

  useEffect(() => {
    void supabase
      .from("products")
      .select("*, wholesaler:businesses!products_wholesaler_id_fkey(id,name,city,region)")
      .eq("active", true)
      .order("created_at", { ascending: false })
      .then(({ data }) => setProducts((data as unknown as Product[]) ?? []));
  }, []);

  const loadOrders = useEffectEvent(async () => {
    if (!business) return;
    const { data } = await supabase
      .from("orders")
      .select(
        "id,order_number,status,total_ghs,created_at,payment_method,payment_status,paystack_reference,accepted_at,packed_at,dispatched_at,delivered_at,cancelled_at,paid_at,wholesaler:businesses!orders_wholesaler_id_fkey(name),order_items(product_name,quantity,unit_price_ghs)",
      )
      .eq("pharmacy_id", business.id)
      .order("created_at", { ascending: false });
    setOrders((data as unknown as OrderRow[]) ?? []);
  });
  useEffect(() => {
    if (businessId) {
      void loadOrders();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [businessId]);

  // Verify Paystack payment when returning from checkout (?reference=...)
  useEffect(() => {
    if (typeof window === "undefined") return;
    const params = new URLSearchParams(window.location.search);
    const reference = params.get("reference") || params.get("trxref");
    if (!reference) return;
    void (async () => {
      try {
        const res = await fetch("/api/paystack/verify", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ reference }),
        });
        const j = await res.json();
        if (res.ok && j.status === "paid") toast.success("Payment confirmed!");
        else toast.error(`Payment ${j.status ?? "not confirmed"}`);
      } catch {
        toast.error("Failed to verify payment");
      } finally {
        const url = new URL(window.location.href);
        url.searchParams.delete("reference");
        url.searchParams.delete("trxref");
        window.history.replaceState({}, "", url.toString());
        void loadOrders();
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const productMap = useMemo(() => Object.fromEntries(products.map((p) => [p.id, p])), [products]);

  const addToCart = (productId: string) => {
    setCart((prev) => {
      const existing = prev.find((c) => c.productId === productId);
      if (existing)
        return prev.map((c) =>
          c.productId === productId ? { ...c, quantity: c.quantity + 1 } : c,
        );
      return [...prev, { productId, quantity: 1 }];
    });
    toast.success("Added to cart");
  };

  const updateQty = (productId: string, qty: number) => {
    if (qty <= 0) {
      setCart((prev) => prev.filter((c) => c.productId !== productId));
      return;
    }
    setCart((prev) => prev.map((c) => (c.productId === productId ? { ...c, quantity: qty } : c)));
  };

  const payForOrder = async (orderId: string) => {
    const { data: sess } = await supabase.auth.getSession();
    const res = await fetch("/api/paystack/init", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${sess.session?.access_token ?? ""}`,
      },
      body: JSON.stringify({ orderId }),
    });
    const j = await res.json();
    if (!res.ok) {
      toast.error(j.error ?? "Failed to start payment");
      return;
    }
    window.location.href = j.authorization_url;
  };

  const placeOrder = async () => {
    if (!business) return;
    if (business.staff_role === "assistant") {
      toast.error("Your role is view-only and cannot place orders.");
      return;
    }
    if (business.verification_status !== "approved") {
      toast.error("Your business must be verified to place orders");
      return;
    }
    setPlacing(true);
    try {
      const grouped: Record<string, CartItem[]> = {};
      for (const c of cart) {
        const p = productMap[c.productId];
        if (!p) continue;
        (grouped[p.wholesaler_id] ??= []).push(c);
      }
      const placedOrders: { id: string }[] = [];
      for (const [wid, items] of Object.entries(grouped)) {
        const total = items.reduce((s, c) => {
          const p = productMap[c.productId];
          return s + (p ? Number(p.price_ghs) * c.quantity : 0);
        }, 0);
        const { data: order, error } = await supabase
          .from("orders")
          .insert({
            pharmacy_id: business.id,
            wholesaler_id: wid,
            total_ghs: total,
            payment_method: paymentMethod,
          })
          .select()
          .single();
        if (error) {
          toast.error(error.message);
          continue;
        }
        const itemRows = items.map((c) => {
          const p = productMap[c.productId]!;
          return {
            order_id: order.id,
            product_id: p.id,
            product_name: p.name,
            unit_price_ghs: p.price_ghs,
            quantity: c.quantity,
          };
        });
        const { error: iErr } = await supabase.from("order_items").insert(itemRows);
        if (iErr) {
          toast.error(iErr.message);
          continue;
        }
        placedOrders.push({ id: order.id });
      }
      if (placedOrders.length === 0) return;

      if (paymentMethod === "paystack") {
        toast.success(
          placedOrders.length > 1
            ? `${placedOrders.length} orders placed. Pay each from "My orders".`
            : "Redirecting to Paystack…",
        );
        setCart([]);
        void loadOrders();
        if (placedOrders.length === 1) {
          await payForOrder(placedOrders[0].id);
        }
        return;
      }

      toast.success(
        `Placed ${placedOrders.length} order${placedOrders.length > 1 ? "s" : ""} (Pay on Delivery)`,
      );
      setCart([]);
      void loadOrders();
    } finally {
      setPlacing(false);
    }
  };

  const cartCount = cart.reduce((sum, c) => sum + c.quantity, 0);
  const subtotal = cart.reduce((s, c) => {
    const p = productMap[c.productId];
    return s + (p ? Number(p.price_ghs) * c.quantity : 0);
  }, 0);
  const canPlaceOrders = business?.staff_role !== "assistant";

  if (loading || !business) {
    return (
      <div className="flex min-h-screen items-center justify-center text-muted-foreground">
        <Pill className="h-5 w-5 animate-pulse" />
        <span className="ml-2">Loading…</span>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader
        subtitle="Pharmacy workspace"
        showNav={true}
        isAdmin={roles.includes("admin")}
        rightSlot={
          <CartSheet
            cart={cart}
            cartCount={cartCount}
            subtotal={subtotal}
            productMap={productMap}
            updateQty={updateQty}
            placeOrder={placeOrder}
            paymentMethod={paymentMethod}
            setPaymentMethod={setPaymentMethod}
            placing={placing}
            canPlaceOrders={canPlaceOrders}
          />
        }
      />
      <main className="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 py-8">
        <div className="mb-6">
          <h1 className="font-display text-3xl font-bold">{business.name}</h1>
          <p className="mt-1 text-muted-foreground">
            Browse the catalog and order from verified wholesalers across Ghana.
          </p>
        </div>

        <VerificationBanner business={business} />

        <Tabs defaultValue="catalog" className="w-full">
          <TabsList className="mb-6">
            <TabsTrigger value="catalog">Catalog</TabsTrigger>
            <TabsTrigger value="orders">My orders ({orders.length})</TabsTrigger>
          </TabsList>

          <TabsContent value="catalog">
            <CatalogView
              products={products}
              addToCart={addToCart}
              canOrder={business.verification_status === "approved" && canPlaceOrders}
            />
          </TabsContent>
          <TabsContent value="orders">
            <OrdersView orders={orders} payForOrder={payForOrder} />
          </TabsContent>
        </Tabs>
      </main>
    </div>
  );
}

function CartSheet({
  cart,
  cartCount,
  subtotal,
  productMap,
  updateQty,
  placeOrder,
  paymentMethod,
  setPaymentMethod,
  placing,
  canPlaceOrders,
}: {
  cart: CartItem[];
  cartCount: number;
  subtotal: number;
  productMap: Record<string, Product>;
  updateQty: (id: string, qty: number) => void;
  placeOrder: () => Promise<void>;
  paymentMethod: "cod" | "paystack";
  setPaymentMethod: (m: "cod" | "paystack") => void;
  placing: boolean;
  canPlaceOrders: boolean;
}) {
  const [open, setOpen] = useState(false);
  const items = cart
    .map((c) => ({ p: productMap[c.productId], qty: c.quantity }))
    .filter((x) => x.p);

  const grouped = items.reduce<Record<string, typeof items>>((acc, it) => {
    const key = it.p!.wholesaler_id;
    (acc[key] ??= []).push(it);
    return acc;
  }, {});

  return (
    <Sheet open={open} onOpenChange={setOpen}>
      <SheetTrigger asChild>
        <Button variant="hero" size="sm" className="relative">
          <ShoppingCart className="h-4 w-4" /> Cart
          {cartCount > 0 && (
            <span className="absolute -right-1.5 -top-1.5 flex h-5 min-w-5 items-center justify-center rounded-full bg-accent px-1 text-[10px] font-bold text-accent-foreground ring-2 ring-background">
              {cartCount}
            </span>
          )}
        </Button>
      </SheetTrigger>
      <SheetContent className="flex w-full flex-col sm:max-w-md">
        <SheetHeader>
          <SheetTitle>Your cart</SheetTitle>
        </SheetHeader>
        {items.length === 0 ? (
          <div className="flex flex-1 flex-col items-center justify-center text-center">
            <div className="flex h-16 w-16 items-center justify-center rounded-full bg-muted">
              <ShoppingCart className="h-7 w-7 text-muted-foreground" />
            </div>
            <p className="mt-4 font-medium">Your cart is empty</p>
            <p className="mt-1 text-sm text-muted-foreground">Add medicines from the catalog.</p>
          </div>
        ) : (
          <>
            <div className="flex-1 overflow-y-auto py-4 pr-1 space-y-5">
              {Object.entries(grouped).map(([wid, group]) => (
                <div key={wid}>
                  <div className="mb-2 flex items-center gap-2 text-xs font-medium text-muted-foreground">
                    <Package className="h-3.5 w-3.5" />
                    {group[0].p!.wholesaler?.name ?? "Wholesaler"}
                  </div>
                  <div className="space-y-2">
                    {group.map((it) => (
                      <div
                        key={it.p!.id}
                        className="flex items-center gap-3 rounded-xl border border-border p-3"
                      >
                        <div
                          className="h-12 w-12 shrink-0 rounded-lg"
                          style={{
                            background: `linear-gradient(135deg, oklch(0.85 0.08 ${it.p!.image_hue ?? 200}), oklch(0.7 0.13 ${it.p!.image_hue ?? 200}))`,
                          }}
                        />
                        <div className="min-w-0 flex-1">
                          <div className="truncate text-sm font-medium">{it.p!.name}</div>
                          <div className="text-xs text-muted-foreground">
                            {formatGHS(it.p!.price_ghs)} · {it.p!.pack_size ?? "—"}
                          </div>
                        </div>
                        <div className="flex items-center gap-1">
                          <Button
                            variant="outline"
                            size="icon"
                            className="h-7 w-7"
                            onClick={() => updateQty(it.p!.id, it.qty - 1)}
                          >
                            <Minus className="h-3 w-3" />
                          </Button>
                          <span className="w-6 text-center text-sm font-medium">{it.qty}</span>
                          <Button
                            variant="outline"
                            size="icon"
                            className="h-7 w-7"
                            onClick={() => updateQty(it.p!.id, it.qty + 1)}
                          >
                            <Plus className="h-3 w-3" />
                          </Button>
                        </div>
                        <button
                          onClick={() => updateQty(it.p!.id, 0)}
                          className="text-muted-foreground hover:text-destructive"
                        >
                          <Trash2 className="h-4 w-4" />
                        </button>
                      </div>
                    ))}
                  </div>
                </div>
              ))}
            </div>
            <SheetFooter className="border-t border-border pt-4">
              <div className="w-full space-y-4">
                <div>
                  <div className="mb-2 text-xs font-medium uppercase tracking-wider text-muted-foreground">
                    Payment method
                  </div>
                  <div className="grid grid-cols-2 gap-2">
                    <button
                      type="button"
                      onClick={() => setPaymentMethod("paystack")}
                      className={`flex flex-col items-start rounded-xl border p-3 text-left transition ${paymentMethod === "paystack" ? "border-primary bg-primary/5 ring-1 ring-primary/30" : "border-border hover:bg-muted/40"}`}
                    >
                      <div className="flex items-center gap-1.5 text-sm font-semibold">
                        <CreditCard className="h-4 w-4" /> Paystack
                      </div>
                      <div className="mt-0.5 text-[11px] text-muted-foreground">
                        Card · MoMo · Bank
                      </div>
                    </button>
                    <button
                      type="button"
                      onClick={() => setPaymentMethod("cod")}
                      className={`flex flex-col items-start rounded-xl border p-3 text-left transition ${paymentMethod === "cod" ? "border-primary bg-primary/5 ring-1 ring-primary/30" : "border-border hover:bg-muted/40"}`}
                    >
                      <div className="flex items-center gap-1.5 text-sm font-semibold">
                        <Banknote className="h-4 w-4" /> Pay on delivery
                      </div>
                      <div className="mt-0.5 text-[11px] text-muted-foreground">
                        Cash to courier
                      </div>
                    </button>
                  </div>
                </div>
                <div className="flex items-center justify-between text-sm">
                  <span className="text-muted-foreground">Subtotal</span>
                  <span className="font-semibold">{formatGHS(subtotal)}</span>
                </div>
                {!canPlaceOrders && (
                  <div className="text-xs text-muted-foreground">
                    Your access is view-only. Ask the business owner for cashier or manager access
                    to place orders.
                  </div>
                )}
                <Button
                  variant="hero"
                  size="lg"
                  className="w-full"
                  disabled={placing || !canPlaceOrders}
                  onClick={async () => {
                    await placeOrder();
                    setOpen(false);
                  }}
                >
                  {placing ? "Placing…" : `Place order · ${formatGHS(subtotal)}`}
                </Button>
              </div>
            </SheetFooter>
          </>
        )}
      </SheetContent>
    </Sheet>
  );
}

function CatalogView({
  products,
  addToCart,
  canOrder,
}: {
  products: Product[];
  addToCart: (id: string) => void;
  canOrder: boolean;
}) {
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState<string>("all");
  const [sort, setSort] = useState<string>("relevance");

  const filtered = useMemo(() => {
    let list = products.filter((p) => {
      const q = query.toLowerCase();
      const matchQ =
        !q ||
        p.name.toLowerCase().includes(q) ||
        (p.brand ?? "").toLowerCase().includes(q) ||
        (p.category ?? "").toLowerCase().includes(q);
      const matchC = category === "all" || p.category === category;
      return matchQ && matchC;
    });
    if (sort === "price-asc")
      list = [...list].sort((a, b) => Number(a.price_ghs) - Number(b.price_ghs));
    if (sort === "price-desc")
      list = [...list].sort((a, b) => Number(b.price_ghs) - Number(a.price_ghs));
    if (sort === "name") list = [...list].sort((a, b) => a.name.localeCompare(b.name));
    return list;
  }, [query, category, sort, products]);

  return (
    <div>
      <Card className="p-4 mb-6 shadow-soft">
        <div className="flex flex-col gap-3 lg:flex-row">
          <div className="relative flex-1">
            <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              placeholder="Search drug, brand, category…"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              className="pl-9"
            />
          </div>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:flex">
            <Select value={category} onValueChange={setCategory}>
              <SelectTrigger className="lg:w-44">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="all">All categories</SelectItem>
                {PRODUCT_CATEGORIES.map((c) => (
                  <SelectItem key={c} value={c}>
                    {c}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Select value={sort} onValueChange={setSort}>
              <SelectTrigger className="lg:w-40">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="relevance">Relevance</SelectItem>
                <SelectItem value="price-asc">Price: low to high</SelectItem>
                <SelectItem value="price-desc">Price: high to low</SelectItem>
                <SelectItem value="name">Name A–Z</SelectItem>
              </SelectContent>
            </Select>
          </div>
        </div>
      </Card>

      {filtered.length === 0 ? (
        <Card className="p-12 text-center">
          <p className="text-muted-foreground">
            {products.length === 0
              ? "No products yet — wholesalers are still being onboarded. Check back soon."
              : "No products match your filters."}
          </p>
        </Card>
      ) : (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
          {filtered.map((p) => (
            <Card
              key={p.id}
              className="group flex flex-col overflow-hidden border-border transition-all hover:shadow-elegant hover:-translate-y-0.5"
            >
              <div
                className="relative h-32 w-full"
                style={{
                  background: `linear-gradient(135deg, oklch(0.92 0.05 ${p.image_hue ?? 200}), oklch(0.78 0.12 ${p.image_hue ?? 200}))`,
                }}
              >
                <div className="absolute inset-0 flex items-center justify-center">
                  <Pill className="h-12 w-12 text-white/70" />
                </div>
                {p.stock < 100 && (
                  <Badge
                    variant="secondary"
                    className="absolute right-2 top-2 bg-warning text-warning-foreground"
                  >
                    Low stock
                  </Badge>
                )}
              </div>
              <div className="flex flex-1 flex-col p-4">
                <div className="text-xs text-muted-foreground">{p.category ?? "—"}</div>
                <h3 className="mt-1 font-semibold leading-tight">{p.name}</h3>
                <div className="mt-1 text-xs text-muted-foreground">
                  {p.brand ?? "—"} · {p.form ?? "—"} · {p.pack_size ?? "—"}
                </div>
                <div className="mt-3 flex items-center gap-1.5 text-xs text-muted-foreground">
                  <ShieldCheck className="h-3.5 w-3.5 text-success" />
                  <span className="truncate">{p.wholesaler?.name ?? "Verified wholesaler"}</span>
                </div>
                <div className="mt-auto flex items-center justify-between pt-4">
                  <div>
                    <div className="font-display text-lg font-bold">{formatGHS(p.price_ghs)}</div>
                    <div className="text-[11px] text-muted-foreground">{p.stock} in stock</div>
                  </div>
                  <Button
                    size="sm"
                    variant="hero"
                    onClick={() => addToCart(p.id)}
                    disabled={!canOrder}
                  >
                    <Plus className="h-4 w-4" /> Add
                  </Button>
                </div>
              </div>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}

function OrdersView({
  orders,
  payForOrder,
}: {
  orders: OrderRow[];
  payForOrder: (id: string) => Promise<void>;
}) {
  if (orders.length === 0) {
    return (
      <Card className="p-12 text-center text-muted-foreground">
        You haven't placed any orders yet.
      </Card>
    );
  }
  return (
    <div className="space-y-4">
      {orders.map((o) => (
        <Card key={o.id} className="p-5">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <div className="flex items-center gap-2 flex-wrap">
                <span className="font-display text-lg font-bold">{o.order_number}</span>
                <StatusBadge status={o.status} />
                <PaymentBadge method={o.payment_method} status={o.payment_status} />
              </div>
              <div className="mt-1 text-sm text-muted-foreground">
                From{" "}
                <span className="font-medium text-foreground">{o.wholesaler?.name ?? "—"}</span> ·{" "}
                {timeAgo(o.created_at)}
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

          {o.payment_method === "paystack" &&
            o.payment_status === "unpaid" &&
            o.status !== "cancelled" && (
              <div className="mt-4 flex justify-end">
                <Button variant="hero" size="sm" onClick={() => payForOrder(o.id)}>
                  <CreditCard className="h-4 w-4" /> Pay {formatGHS(o.total_ghs)}
                </Button>
              </div>
            )}
        </Card>
      ))}
    </div>
  );
}
