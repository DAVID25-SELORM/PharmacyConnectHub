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
  Building2,
  MapPin,
  Pill,
  Printer,
} from "lucide-react";
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
import { createMarketplaceOrders } from "@/lib/order-actions";
import { DashboardHeader, VerificationBanner } from "@/components/DashboardShell";
import { StatusBadge, PaymentBadge, OrderTimeline } from "@/components/order-status";
import { SearchableSelect } from "@/components/ui/searchable-select";
import { OrderPrintActions } from "@/components/order-print";

export const Route = createFileRoute("/pharmacy")({
  head: () => ({
    meta: [
      { title: "Pharmacy Dashboard — Drugxone" },
      { name: "description", content: "Browse medicines, compare prices, place orders." },
    ],
  }),
  component: PharmacyDashboard,
});

type Product = {
  master_product_id: string;
  generic_name: string | null;
  strength: string | null;
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
  wholesaler: {
    id: string;
    name: string;
    city: string | null;
    region: string | null;
    verification_status: string;
  } | null;
};

type MasterCatalogueEntry = {
  id: string;
  name: string;
  generic_name: string | null;
  strength: string | null;
  brand_name: string | null;
  dosage_form: string | null;
  pack_size: string | null;
  category: string | null;
  offers: Product[];
};

type CartItem = { productId: string; quantity: number };

type WholesalerSummary = {
  id: string;
  name: string;
  city: string | null;
  region: string | null;
  productCount: number;
  categoryCount: number;
  stockTotal: number;
  lowestPrice: number | null;
};

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
  payment_confirmed_at: string | null;
  receipt_sent_at: string | null;
  receipt_sent_to: string | null;
  wholesaler: { name: string } | null;
  order_items: { product_name: string; quantity: number; unit_price_ghs: number }[];
};

function PharmacyDashboard() {
  const navigate = useNavigate();
  const { loading, user, business, businesses, roles } = useSession();
  const businessId = business?.id ?? null;
  const [cart, setCart] = useState<CartItem[]>([]);
  const [products, setProducts] = useState<Product[]>([]);
  const [orders, setOrders] = useState<OrderRow[]>([]);
  const [placing, setPlacing] = useState(false);

  useEffect(() => {
    if (loading) return;
    if (!user) {
      navigate({ to: "/login" });
      return;
    }
    if (!business) {
      if (businesses.length > 1) {
        navigate({ to: "/dashboard" });
        return;
      }
      if (roles.includes("admin")) {
        navigate({ to: "/admin" });
        return;
      }
      navigate({ to: "/onboarding" });
      return;
    }
    if (business && business.type !== "pharmacy") {
      navigate({ to: business.type === "wholesaler" ? "/wholesaler" : "/dashboard" });
      return;
    }
    if (business && business.verification_status === "rejected") {
      navigate({ to: "/onboarding" });
      return;
    }
  }, [loading, user, business, businesses, roles, navigate]);

  useEffect(() => {
    if (loading || !user) return;

    void supabase.rpc("list_marketplace_catalogue").then(({ data, error }) => {
      if (error) {
        toast.error("Could not load the medicine catalogue. Please refresh and try again.");
        return;
      }
      const catalogue = (Array.isArray(data) ? data : []) as unknown as MasterCatalogueEntry[];
      setProducts(
        (catalogue ?? []).flatMap((master) =>
          (Array.isArray(master.offers) ? master.offers : []).map((offer) => ({
            ...offer,
            master_product_id: master.id,
            name: master.name,
            generic_name: master.generic_name,
            strength: master.strength,
            brand: master.brand_name,
            form: master.dosage_form,
            pack_size: master.pack_size,
            category: master.category,
          })),
        ),
      );
    });
  }, [loading, user]);

  const loadOrders = useEffectEvent(async () => {
    if (!business) return;
    const { data, error } = await (supabase as any).rpc("list_pharmacy_order_history", {
      p_page: 1, p_page_size: 100, p_sort: "newest",
    });
    if (error) {
      toast.error("We couldn't load your orders. Please try again.");
      return;
    }
    const rows = Array.isArray(data?.orders) ? data.orders : [];
    setOrders(rows.map((row: Record<string, unknown>) => ({
      ...row, paystack_reference: null, accepted_at: null, packed_at: null,
      dispatched_at: null, delivered_at: null, cancelled_at: null, paid_at: null,
      payment_confirmed_at: null, receipt_sent_at: null, receipt_sent_to: null,
      wholesaler: row.wholesaler_name ? { name: String(row.wholesaler_name) } : null,
      order_items: [],
    })) as OrderRow[]);
  });

  const loadOrderDetail = async (orderId: string) => {
    const { data, error } = await (supabase as any).rpc("get_pharmacy_order_detail", { p_order_id: orderId });
    if (error || !data?.order) {
      toast.error("We couldn't load this order. Please try again.");
      return null;
    }
    const detail = data.order as OrderRow & { items?: OrderRow["order_items"] };
    const hydrated = { ...detail, order_items: detail.items ?? [] };
    setOrders((current) => current.map((order) => order.id === orderId ? { ...order, ...hydrated } : order));
    return hydrated;
  };
  useEffect(() => {
    if (businessId) {
      void loadOrders();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [businessId]);

  const productMap = useMemo(() => Object.fromEntries(products.map((p) => [p.id, p])), [products]);
  const approvedWholesalers = useMemo<WholesalerSummary[]>(() => {
    const grouped = new Map<
      string,
      Omit<WholesalerSummary, "categoryCount"> & { categories: Set<string> }
    >();

    for (const product of products) {
      const wholesaler = product.wholesaler;
      if (!wholesaler) continue;

      const existing = grouped.get(wholesaler.id);
      if (existing) {
        existing.productCount += 1;
        existing.stockTotal += product.stock;
        if (product.category) existing.categories.add(product.category);
        existing.lowestPrice =
          existing.lowestPrice === null
            ? Number(product.price_ghs)
            : Math.min(existing.lowestPrice, Number(product.price_ghs));
        continue;
      }

      grouped.set(wholesaler.id, {
        id: wholesaler.id,
        name: wholesaler.name,
        city: wholesaler.city,
        region: wholesaler.region,
        productCount: 1,
        categories: new Set(product.category ? [product.category] : []),
        stockTotal: product.stock,
        lowestPrice: Number(product.price_ghs),
      });
    }

    return Array.from(grouped.values())
      .map(({ categories, ...entry }) => ({
        ...entry,
        categoryCount: categories.size,
      }))
      .sort((left, right) => left.name.localeCompare(right.name));
  }, [products]);

  const addToCart = (productId: string) => {
    const product = productMap[productId];
    if (!product) {
      return;
    }

    if (product.stock <= 0) {
      toast.error(`${product.name} is currently out of stock.`);
      return;
    }

    let added = false;
    setCart((prev) => {
      const existing = prev.find((c) => c.productId === productId);
      if (existing) {
        if (existing.quantity >= product.stock) {
          return prev;
        }

        added = true;
        return prev.map((c) =>
          c.productId === productId ? { ...c, quantity: c.quantity + 1 } : c,
        );
      }

      added = true;
      return [...prev, { productId, quantity: 1 }];
    });

    if (added) {
      toast.success("Added to cart");
      return;
    }

    toast.error(`Only ${product.stock} unit(s) of ${product.name} are available right now.`);
  };

  const updateQty = (productId: string, qty: number) => {
    const product = productMap[productId];
    if (qty <= 0) {
      setCart((prev) => prev.filter((c) => c.productId !== productId));
      return;
    }

    if (!product) {
      setCart((prev) => prev.filter((c) => c.productId !== productId));
      return;
    }

    const clampedQty = Math.min(qty, product.stock);
    if (clampedQty !== qty) {
      toast.error(`Only ${product.stock} unit(s) of ${product.name} are available right now.`);
    }

    setCart((prev) =>
      prev.map((c) => (c.productId === productId ? { ...c, quantity: clampedQty } : c)),
    );
  };

  const placeOrder = async () => {
    if (!business) return false;
    if (business.staff_role === "assistant") {
      toast.error("Your role is view-only and cannot place orders.");
      return false;
    }
    if (business.verification_status !== "approved") {
      toast.error("Your business must be verified to place orders");
      return false;
    }
    if (cart.length === 0) {
      toast.error("Your cart is empty.");
      return false;
    }
    setPlacing(true);
    try {
      const result = await createMarketplaceOrders({
        pharmacyId: business.id,
        items: cart.map((item) => ({
          productId: item.productId,
          quantity: item.quantity,
        })),
      });

      toast.success(
        `Placed ${result.orderCount} order${result.orderCount > 1 ? "s" : ""} (Pay on Delivery)`,
      );
      setCart([]);
      void loadOrders();
      return true;
    } catch (error) {
      const message = error instanceof Error ? error.message : "Failed to place order.";
      toast.error(message);
      return false;
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

  if (business.verification_status === "pending") {
    return (
      <div className="min-h-screen bg-background">
        <DashboardHeader
          subtitle="Pharmacy workspace"
          showNav={false}
          isAdmin={roles.includes("admin")}
        />
        <main className="mx-auto max-w-3xl px-4 sm:px-6 lg:px-8 py-16">
          <Card className="p-8 text-center">
            <div className="mx-auto flex h-16 w-16 items-center justify-center rounded-full bg-warning/10">
              <Pill className="h-8 w-8 text-warning" />
            </div>
            <h2 className="mt-6 font-display text-2xl font-bold">Verification Pending</h2>
            <p className="mt-2 text-muted-foreground">
              Your pharmacy registration is being reviewed by our admin team. You'll receive access
              once your license and details are verified.
            </p>
            <p className="mt-4 text-sm text-muted-foreground">
              This usually takes 1-2 business days. We'll notify you once approved.
            </p>
          </Card>
        </main>
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
          <p className="mt-2 text-sm text-muted-foreground">
            {approvedWholesalers.length > 0
              ? `${approvedWholesalers.length} approved wholesaler${approvedWholesalers.length > 1 ? "s are" : " is"} available for comparison right now.`
              : "Approved wholesalers will appear here as soon as they finish onboarding."}
          </p>
        </div>

        <VerificationBanner business={business} />

        <Tabs defaultValue="catalog" className="w-full">
          <TabsList className="mb-6">
            <TabsTrigger value="catalog">
              Catalog ({approvedWholesalers.length} wholesaler
              {approvedWholesalers.length === 1 ? "" : "s"})
            </TabsTrigger>
            <TabsTrigger value="orders">My orders ({orders.length})</TabsTrigger>
          </TabsList>

          <TabsContent value="catalog">
            <CatalogView
              products={products}
              wholesalers={approvedWholesalers}
              addToCart={addToCart}
              canOrder={business.verification_status === "approved" && canPlaceOrders}
            />
          </TabsContent>
          <TabsContent value="orders">
            <OrdersView orders={orders} loadOrderDetail={loadOrderDetail} />
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
  placing,
  canPlaceOrders,
}: {
  cart: CartItem[];
  cartCount: number;
  subtotal: number;
  productMap: Record<string, Product>;
  updateQty: (id: string, qty: number) => void;
  placeOrder: () => Promise<boolean>;
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
                <div className="flex items-center justify-between text-sm">
                  <span className="text-muted-foreground">Subtotal</span>
                  <span className="font-semibold">{formatGHS(subtotal)}</span>
                </div>
                <div className="flex items-center justify-between text-sm">
                  <span className="text-muted-foreground">Payment</span>
                  <span className="font-medium">Cash on delivery</span>
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
                    const placed = await placeOrder();
                    if (placed) {
                      setOpen(false);
                    }
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
  wholesalers,
  addToCart,
  canOrder,
}: {
  products: Product[];
  wholesalers: WholesalerSummary[];
  addToCart: (id: string) => void;
  canOrder: boolean;
}) {
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState<string>("all");
  const [sort, setSort] = useState<string>("relevance");
  const [wholesalerId, setWholesalerId] = useState<string>("all");

  useEffect(() => {
    if (wholesalerId === "all") return;
    if (!wholesalers.some((wholesaler) => wholesaler.id === wholesalerId)) {
      setWholesalerId("all");
    }
  }, [wholesalerId, wholesalers]);

  const categoryCount = useMemo(
    () => new Set(products.map((product) => product.category).filter(Boolean)).size,
    [products],
  );

  const filtered = useMemo(() => {
    let list = products.filter((p) => {
      const q = query.toLowerCase();
      const matchQ =
        !q ||
        p.name.toLowerCase().includes(q) ||
        (p.brand ?? "").toLowerCase().includes(q) ||
        (p.category ?? "").toLowerCase().includes(q) ||
        (p.generic_name ?? "").toLowerCase().includes(q) ||
        p.name
          .toLowerCase()
          .replace(/[^a-z0-9.]/g, "")
          .includes(q.replace(/[^a-z0-9.]/g, ""));
      const matchC = category === "all" || p.category === category;
      const matchW = wholesalerId === "all" || p.wholesaler_id === wholesalerId;
      return matchQ && matchC && matchW;
    });
    if (sort === "price-asc")
      list = [...list].sort((a, b) => Number(a.price_ghs) - Number(b.price_ghs));
    if (sort === "price-desc")
      list = [...list].sort((a, b) => Number(b.price_ghs) - Number(a.price_ghs));
    if (sort === "name") list = [...list].sort((a, b) => a.name.localeCompare(b.name));
    return list;
  }, [query, category, sort, products, wholesalerId]);

  const groupedProducts = useMemo(() => {
    const groups = new Map<string, Product[]>();
    for (const product of filtered) {
      const offers = groups.get(product.master_product_id) ?? [];
      offers.push(product);
      groups.set(product.master_product_id, offers);
    }
    return [...groups.values()];
  }, [filtered]);

  const filteredWholesalerCount = useMemo(
    () => new Set(filtered.map((product) => product.wholesaler_id)).size,
    [filtered],
  );

  return (
    <div>
      <div className="mb-6 grid gap-4 md:grid-cols-3">
        <Card className="p-5">
          <div className="text-xs uppercase tracking-wider text-muted-foreground">
            Approved Wholesalers
          </div>
          <div className="mt-2 font-display text-3xl font-bold">{wholesalers.length}</div>
          <p className="mt-2 text-sm text-muted-foreground">
            Verified suppliers currently live in the marketplace.
          </p>
        </Card>
        <Card className="p-5">
          <div className="text-xs uppercase tracking-wider text-muted-foreground">Medicines</div>
          <div className="mt-2 font-display text-3xl font-bold">
            {new Set(products.map((product) => product.master_product_id)).size}
          </div>
          <p className="mt-2 text-sm text-muted-foreground">
            Medicines grouped across verified suppliers.
          </p>
        </Card>
        <Card className="p-5">
          <div className="text-xs uppercase tracking-wider text-muted-foreground">Categories</div>
          <div className="mt-2 font-display text-3xl font-bold">{categoryCount}</div>
          <p className="mt-2 text-sm text-muted-foreground">
            Therapeutic groups represented in the current catalog.
          </p>
        </Card>
      </div>

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
            <SearchableSelect
              options={[
                {
                  value: "all",
                  label: `All wholesalers (${wholesalers.length})`,
                  keywords: ["all", "all wholesalers", "marketplace", "everyone"],
                  searchText: `all wholesalers ${wholesalers.length}`,
                },
                ...wholesalers.map((wholesaler) => {
                  const location =
                    [wholesaler.city, wholesaler.region].filter(Boolean).join(", ") ||
                    "Location pending";

                  return {
                    value: wholesaler.id,
                    label: wholesaler.name,
                    description: `${location} · ${wholesaler.productCount} product${wholesaler.productCount === 1 ? "" : "s"}`,
                    keywords: [
                      wholesaler.name,
                      wholesaler.city ?? "",
                      wholesaler.region ?? "",
                      String(wholesaler.productCount),
                    ],
                    searchText: `${wholesaler.name} ${location}`,
                  };
                }),
              ]}
              value={wholesalerId}
              onValueChange={setWholesalerId}
              placeholder={`All wholesalers (${wholesalers.length})`}
              searchPlaceholder="Search wholesalers..."
              emptyLabel="No wholesaler found."
            />
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
        <div className="mt-4 text-sm text-muted-foreground">
          Showing {groupedProducts.length} medicine{groupedProducts.length === 1 ? "" : "s"} from{" "}
          {filteredWholesalerCount} wholesaler{filteredWholesalerCount === 1 ? "" : "s"}.
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
        <div className="space-y-4">
          {groupedProducts.map((offers) => {
            const medicine = offers[0];
            const supplierCount = new Set(offers.map((offer) => offer.wholesaler_id)).size;
            return (
              <Card key={medicine.master_product_id} className="p-5">
                <div className="flex items-start gap-3">
                  <Pill className="mt-1 h-6 w-6 text-primary" />
                  <div>
                    <h3 className="font-semibold">{medicine.name}</h3>
                    <p className="text-sm text-muted-foreground">
                      {[
                        medicine.form,
                        medicine.pack_size && `Pack: ${medicine.pack_size}`,
                        medicine.category,
                      ]
                        .filter(Boolean)
                        .join(" | ")}
                    </p>
                    {medicine.generic_name && (
                      <p className="text-sm text-muted-foreground">{medicine.generic_name}</p>
                    )}
                    <p className="mt-2 flex items-center gap-1 text-sm">
                      <ShieldCheck className="h-4 w-4 text-success" />
                      {supplierCount} verified supplier{supplierCount === 1 ? "" : "s"}
                    </p>
                  </div>
                </div>
                <details className="mt-4">
                  <summary className="cursor-pointer text-sm font-medium text-primary">
                    Compare suppliers - from{" "}
                    {formatGHS(Math.min(...offers.map((offer) => Number(offer.price_ghs))))}
                  </summary>
                  <div className="mt-3 overflow-x-auto">
                    <table className="w-full text-left text-sm">
                      <thead>
                        <tr>
                          <th className="p-2">Supplier</th>
                          <th className="p-2">Price</th>
                          <th className="p-2">Available</th>
                          <th className="p-2">
                            <span className="sr-only">Order</span>
                          </th>
                        </tr>
                      </thead>
                      <tbody>
                        {[...offers]
                          .sort((a, b) => Number(a.price_ghs) - Number(b.price_ghs))
                          .map((offer) => (
                            <tr key={offer.id} className="border-t">
                              <td className="p-2">
                                <div className="font-medium">{offer.wholesaler?.name}</div>
                                <div className="text-xs text-muted-foreground">
                                  {offer.wholesaler?.city}
                                </div>
                              </td>
                              <td className="p-2 font-semibold">{formatGHS(offer.price_ghs)}</td>
                              <td className="p-2">
                                {offer.stock > 0 ? `${offer.stock} in stock` : "Out of stock"}
                              </td>
                              <td className="p-2 text-right">
                                <Button
                                  size="sm"
                                  variant="hero"
                                  onClick={() => addToCart(offer.id)}
                                  disabled={!canOrder || offer.stock <= 0}
                                >
                                  <Plus className="h-4 w-4" />
                                  Add
                                </Button>
                              </td>
                            </tr>
                          ))}
                      </tbody>
                    </table>
                  </div>
                </details>
              </Card>
            );
          })}
        </div>
      )}
    </div>
  );
}

function OrdersView({ orders, loadOrderDetail }: { orders: OrderRow[]; loadOrderDetail: (id: string) => Promise<OrderRow | null> }) {
  const [openOrderId, setOpenOrderId] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState("all");
  const [payment, setPayment] = useState("all");
  const [sort, setSort] = useState("newest");
  const [page, setPage] = useState(1);
  const pageSize = 20;
  const counts = useMemo(() => ({
    active: orders.filter((o) => ["pending", "accepted", "packed", "dispatched"].includes(o.status)).length,
    awaiting: orders.filter((o) => o.payment_status === "unpaid").length,
    transit: orders.filter((o) => ["packed", "dispatched"].includes(o.status)).length,
    delivered: orders.filter((o) => o.status === "delivered").length,
  }), [orders]);
  const filtered = useMemo(() => {
    const term = query.trim().toLowerCase();
    return [...orders]
      .filter((o) => status === "all" || (status === "active" ? ["pending", "accepted", "packed"].includes(o.status) : o.status === status))
      .filter((o) => payment === "all" || o.payment_status === payment)
      .filter((o) => !term || `${o.order_number} ${o.wholesaler?.name ?? ""} ${o.order_items.map((i) => i.product_name).join(" ")}`.toLowerCase().includes(term))
      .sort((a, b) => {
        if (sort === "highest") return Number(b.total_ghs) - Number(a.total_ghs);
        if (sort === "lowest") return Number(a.total_ghs) - Number(b.total_ghs);
        const result = new Date(a.created_at).getTime() - new Date(b.created_at).getTime();
        return sort === "oldest" ? result : -result;
      });
  }, [orders, payment, query, sort, status]);
  const pageCount = Math.max(1, Math.ceil(filtered.length / pageSize));
  const pageOrders = filtered.slice((page - 1) * pageSize, page * pageSize);
  useEffect(() => { if (page > pageCount) setPage(pageCount); }, [page, pageCount]);

  if (orders.length === 0) {
    return (
      <Card className="p-12 text-center text-muted-foreground">
        <p>No orders yet</p>
        <p className="mt-2 text-sm">Orders you place with approved wholesalers will appear here.</p>
      </Card>
    );
  }
  return (
    <div className="space-y-4">
      <div className="grid gap-3 sm:grid-cols-4">
        <SummaryCard label="Active Orders" value={counts.active} />
        <SummaryCard label="Awaiting Payment" value={counts.awaiting} />
        <SummaryCard label="In Transit" value={counts.transit} />
        <SummaryCard label="Delivered" value={counts.delivered} />
      </div>
      <div className="flex flex-col gap-3 rounded-xl border border-border bg-card p-3 sm:flex-row">
        <div className="relative flex-1"><Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" /><Input aria-label="Search orders" value={query} onChange={(e) => { setQuery(e.target.value); setPage(1); }} placeholder="Search orders..." className="pl-9" /></div>
        <Select value={status} onValueChange={(value) => { setStatus(value); setPage(1); }}><SelectTrigger className="sm:w-40"><SelectValue placeholder="Status" /></SelectTrigger><SelectContent><SelectItem value="all">All statuses</SelectItem><SelectItem value="active">Active</SelectItem><SelectItem value="packed">Packed</SelectItem><SelectItem value="dispatched">Dispatched</SelectItem><SelectItem value="delivered">Delivered</SelectItem><SelectItem value="cancelled">Cancelled</SelectItem></SelectContent></Select>
        <Select value={payment} onValueChange={(value) => { setPayment(value); setPage(1); }}><SelectTrigger className="sm:w-40"><SelectValue placeholder="Payment" /></SelectTrigger><SelectContent><SelectItem value="all">All payments</SelectItem><SelectItem value="paid">Paid</SelectItem><SelectItem value="unpaid">Awaiting payment</SelectItem><SelectItem value="failed">Failed</SelectItem><SelectItem value="refunded">Refunded</SelectItem></SelectContent></Select>
        <Select value={sort} onValueChange={setSort}><SelectTrigger className="sm:w-40"><SelectValue /></SelectTrigger><SelectContent><SelectItem value="newest">Newest first</SelectItem><SelectItem value="oldest">Oldest first</SelectItem><SelectItem value="highest">Highest amount</SelectItem><SelectItem value="lowest">Lowest amount</SelectItem></SelectContent></Select>
      </div>
      <div className="flex gap-2 overflow-x-auto pb-1">{["all", "active", "packed", "dispatched", "delivered", "cancelled"].map((item) => <Button key={item} size="sm" variant={status === item ? "secondary" : "ghost"} onClick={() => { setStatus(item); setPage(1); }}>{item[0].toUpperCase() + item.slice(1)}</Button>)}</div>
      {pageOrders.length === 0 ? <Card className="p-10 text-center text-muted-foreground">No orders match your filters.</Card> : null}
      {pageOrders.map((o) => {
        const open = openOrderId === o.id;
        const units = o.order_items.reduce((total, item) => total + item.quantity, 0);
        return <Card key={o.id} className={`p-4 ${open ? "ring-2 ring-primary/20" : ""}`}>
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
                {new Date(o.created_at).toLocaleDateString()} · {timeAgo(o.created_at)}
              </div>
            </div>
            <div className="text-right">
              <div className="font-display text-xl font-bold">{formatGHS(o.total_ghs)}</div>
              <div className="text-xs text-muted-foreground">{o.order_items.length} item(s) · {units} unit(s)</div>
            </div>
          </div>

          <div className="mt-3 flex justify-end border-t border-border pt-3"><Button type="button" variant="outline" size="sm" onClick={() => { if (!open && o.order_items.length === 0) void loadOrderDetail(o.id); setOpenOrderId(open ? null : o.id); }} aria-expanded={open}>{open ? "Hide Order" : "View Order"}</Button></div>
          {open && <>
          <OrderTimeline o={o} />

          <ReceiptStatusPanel order={o} />

          <OrderPrintActions
            order={{ ...o, wholesaler: o.wholesaler ? { name: o.wholesaler.name } : null }}
          />

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
          </div></>}
        </Card>;
      })}
      <div className="flex items-center justify-between text-sm text-muted-foreground"><span>Showing {pageOrders.length} of {filtered.length} orders</span><div className="flex gap-2"><Button size="sm" variant="outline" disabled={page <= 1} onClick={() => setPage((value) => value - 1)}>Previous</Button><Button size="sm" variant="outline" disabled={page >= pageCount} onClick={() => setPage((value) => value + 1)}>Next</Button></div></div>
    </div>
  );
}

function SummaryCard({ label, value }: { label: string; value: number }) {
  return <Card className="p-4"><div className="text-sm text-muted-foreground">{label}</div><div className="mt-1 font-display text-2xl font-bold">{value}</div></Card>;
}

function ReceiptStatusPanel({ order }: { order: OrderRow }) {
  let title = "Receipt pending";
  let body = "Your receipt will be emailed after the wholesaler confirms payment.";

  if (order.payment_status === "paid" && order.receipt_sent_at) {
    title = "Receipt emailed";
    body = `The receipt was emailed ${timeAgo(order.receipt_sent_at)}${order.receipt_sent_to ? ` to ${order.receipt_sent_to}` : ""}.`;
  } else if (order.payment_status === "paid") {
    title = "Payment confirmed";
    body = "Payment has been confirmed. Your receipt email is being prepared by the wholesaler.";
  } else if (order.status !== "delivered") {
    title = "Receipt locked";
    body = "The receipt will only be issued after the order is delivered and payment is confirmed.";
  }

  return (
    <div className="mt-4 rounded-xl border border-border bg-muted/40 p-3 text-sm">
      <div className="font-medium">{title}</div>
      <div className="mt-1 text-muted-foreground">{body}</div>
    </div>
  );
}
