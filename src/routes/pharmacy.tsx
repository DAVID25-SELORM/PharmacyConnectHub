import { WorkspaceGate } from "@/components/WorkspaceGate";
import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useCallback, useEffect, useEffectEvent, useMemo, useState } from "react";
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
  SheetDescription,
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
import { formatGHS, timeAgo } from "@/lib/format";
import { createMarketplaceOrders } from "@/lib/order-actions";
import { DashboardHeader, VerificationBanner } from "@/components/DashboardShell";
import { StatusBadge, PaymentBadge, OrderTimeline } from "@/components/order-status";
import { SearchableSelect } from "@/components/ui/searchable-select";
import { OrderPrintActions } from "@/components/order-print";
import { SupplierComparison } from "@/components/pharmacy/SupplierComparison";
import { AddToListMenu } from "@/components/pharmacy/AddToListMenu";
import { ReorderListsView } from "@/components/pharmacy/ReorderListsView";
import { DeliveryPanel } from "@/components/delivery/DeliveryPanel";
import { RequestReturnDialog } from "@/components/returns/RequestReturnDialog";
import { ReturnsPanel } from "@/components/returns/ReturnsPanel";
import { PharmacyStatements } from "@/components/statements/PharmacyStatements";
import { ReorderReviewDialog } from "@/components/pharmacy/ReorderReviewDialog";
import { useReorderLists, type ReorderListsApi } from "@/hooks/use-reorder-lists";
import {
  groupOffersByMaster,
  mergeIntoCart,
  netPrice,
  resolveLine,
  type CatalogueOffer,
  type ResolvedLine,
} from "@/lib/reorder";

export const Route = createFileRoute("/pharmacy")({
  head: () => ({
    meta: [
      { title: "Pharmacy Dashboard — Drugxone" },
      { name: "description", content: "Browse medicines, compare prices, place orders." },
    ],
  }),
  component: PharmacyRoute,
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
  minimum_order_quantity?: number | null;
  lead_time_days?: number | null;
  image_hue: number | null;
  wholesaler_id: string;
  wholesaler: {
    id: string;
    name: string;
    city: string | null;
    region: string | null;
    verification_status: string;
  } | null;
  customer_price_ghs?: number | null;
  customer_discount_percent?: number | null;
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
  item_count?: number;
  unit_count?: number;
};

type OrderHistoryQuery = { page: number; search: string; status: string; payment: string; sort: string };

function customerPrice(product: Product, discounts: Record<string, { discount_type: string; discount_percent?: number; discount_amount?: number; minimum_order_value: number }>) {
  return netPrice(product, discounts[product.wholesaler_id]);
}

function PharmacyDashboardContent() {
  const navigate = useNavigate();
  const { loading, user, business, businesses, roles } = useSession();
  const businessId = business?.id ?? null;
  const [cart, setCart] = useState<CartItem[]>([]);
  const [products, setProducts] = useState<Product[]>([]);
  const [discounts, setDiscounts] = useState<Record<string, { discount_type: string; discount_percent?: number; discount_amount?: number; minimum_order_value: number }>>({});
  const [orders, setOrders] = useState<OrderRow[]>([]);
  const [totalOrderCount, setTotalOrderCount] = useState(0);
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

    void supabase.rpc("list_marketplace_catalogue").then(async ({ data, error }) => {
      if (error) {
        toast.error("Could not load the medicine catalogue. Please refresh and try again.");
        return;
      }
      const catalogue = (Array.isArray(data) ? data : []) as unknown as MasterCatalogueEntry[];
      const loadedProducts = (catalogue ?? []).flatMap((master) =>
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
        );
      setProducts(loadedProducts);
      const wholesalerIds = [...new Set(loadedProducts.map((p) => p.wholesaler_id))];
      const discountResults = await Promise.all(wholesalerIds.map(async (id) => {
        const result = await (supabase as any).rpc("get_my_customer_discount", { p_wholesaler_id: id });
        return [id, Array.isArray(result.data) ? result.data[0] : null] as const;
      }));
      setDiscounts(Object.fromEntries(discountResults.filter(([, value]) => value)));
    });
  }, [loading, user]);

  const loadOrders = useCallback(async (query: OrderHistoryQuery = { page: 1, search: "", status: "all", payment: "all", sort: "newest" }) => {
    if (!businessId) return;
    const { data, error } = await (supabase as any).rpc("list_pharmacy_order_history", {
      p_page: query.page, p_page_size: 20, p_search: query.search || null,
      p_status: query.status === "all" ? null : query.status,
      p_payment_status: query.payment === "all" ? null : query.payment, p_sort: query.sort,
    });
    if (error) {
      toast.error("We couldn't load your orders. Please try again.");
      return;
    }
    const rows = Array.isArray(data?.orders) ? data.orders : [];
    setTotalOrderCount(Number(data?.total_count ?? 0));
    setOrders((current) => rows.map((row: Record<string, unknown>) => ({
      ...row, paystack_reference: null, accepted_at: null, packed_at: null,
      dispatched_at: null, delivered_at: null, cancelled_at: null, paid_at: null,
      payment_confirmed_at: null, receipt_sent_at: null, receipt_sent_to: null,
      ...current.find((order) => order.id === row.id),
      ...row,
      wholesaler: row.wholesaler_name ? { name: String(row.wholesaler_name) } : null,
      order_items: current.find((order) => order.id === row.id)?.order_items ?? [], item_count: Number(row.item_count ?? 0), unit_count: Number(row.unit_count ?? 0),
    })) as OrderRow[]);
  }, [businessId]);

  const loadOrderDetail = async (orderId: string, expectedItemCount?: number) => {
    const { data, error } = await (supabase as any).rpc("get_pharmacy_order_detail", { p_order_id: orderId });
    if (error || !data?.order) {
      console.error("[Drugxone] get_pharmacy_order_detail failed", {
        orderId,
        error,
        response: data,
      });
      toast.error("We couldn't load this order. Please try again.");
      return null;
    }
    const detail = data.order as OrderRow & { items?: OrderRow["order_items"] };
    let items = Array.isArray(detail.items) ? detail.items : [];
    if (items.length === 0) {
      const fallback = await supabase
        .from("order_items")
        .select("product_name,quantity,unit_price_ghs")
        .eq("order_id", orderId)
        .order("id");
      if (!fallback.error && Array.isArray(fallback.data)) {
        items = fallback.data as OrderRow["order_items"];
      } else if (fallback.error) {
        console.error("[Drugxone] order_items fallback query failed", {
          orderId,
          error: fallback.error,
        });
      }
    }
    const hydrated = { ...detail, order_items: items };
    if ((expectedItemCount ?? hydrated.item_count ?? 0) > 0 && hydrated.order_items.length === 0) {
      console.error("[Drugxone] order detail returned no items", {
        orderId,
        expectedItemCount: expectedItemCount ?? hydrated.item_count,
        response: data,
      });
      toast.error("This order has items, but the detail response was empty. Check the Supabase migration and browser console.");
      return null;
    }
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
  const reorderLists = useReorderLists(businessId);
  const [returnOrder, setReturnOrder] = useState<{ id: string; order_number: string } | null>(null);
  const [returnsVersion, setReturnsVersion] = useState(0);
  const [reviewLines, setReviewLines] = useState<{ title: string; lines: ResolvedLine[] } | null>(null);
  const offersByMaster = useMemo(
    () => groupOffersByMaster(products as unknown as Array<CatalogueOffer>),
    [products],
  );

  const addLinesToCart = (lines: Array<{ offer: { id: string }; quantity: number }>) => {
    const { cart: nextCart, added } = mergeIntoCart(
      cart,
      lines.map((line) => ({
        productId: line.offer.id,
        quantity: line.quantity,
        stock: productMap[line.offer.id]?.stock ?? 0,
      })),
    );
    setCart(nextCart);
    return added;
  };

  const reorderFromOrder = async (orderId: string, orderLabel: string) => {
    const { data, error } = await (supabase as any).rpc("get_order_reorder_lines", { p_order_id: orderId });
    if (error || !Array.isArray(data)) {
      toast.error("We couldn't load this order to reorder it. Please try again.");
      return;
    }
    const lines = (data as Array<{
      master_product_id: string | null;
      product_name: string;
      quantity: number;
      wholesaler_id: string;
    }>).map((row) =>
      resolveLine(
        {
          masterProductId: row.master_product_id,
          name: row.product_name,
          quantity: Number(row.quantity),
          preferredWholesalerId: row.wholesaler_id,
        },
        offersByMaster,
        discounts,
      ),
    );
    setReviewLines({ title: `Reorder ${orderLabel}`, lines });
  };
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
      return [...prev, { productId, quantity: Math.min(Math.max(1, Number(product.minimum_order_quantity ?? 1)), product.stock) }];
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
  const canOrder = business?.verification_status === "approved" && canPlaceOrders;
  const canEditLists = canOrder;

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

        <RequestReturnDialog
          order={returnOrder}
          onClose={() => setReturnOrder(null)}
          onDone={() => setReturnsVersion((value) => value + 1)}
        />

        <ReorderReviewDialog
          title={reviewLines?.title ?? ""}
          lines={reviewLines?.lines ?? null}
          canOrder={canOrder}
          onClose={() => setReviewLines(null)}
          onConfirm={(lines) => {
            const added = addLinesToCart(
              lines.filter((line) => line.status !== "unavailable" && line.offer).map((line) => ({ offer: line.offer!, quantity: line.quantity })),
            );
            const unavailable = lines.filter((line) => line.status === "unavailable").length;
            toast.success(
              unavailable > 0
                ? `Added ${added} of ${lines.length} products to your cart. ${unavailable} unavailable.`
                : `Added ${added} product${added === 1 ? "" : "s"} to your cart.`,
            );
            setReviewLines(null);
          }}
        />

        <Tabs
          defaultValue={(() => {
            const tab = typeof window !== "undefined" ? new URLSearchParams(window.location.search).get("tab") : null;
            return tab === "orders" || tab === "lists" || tab === "returns" || tab === "statements" ? tab : "catalog";
          })()}
          className="w-full"
        >
          <TabsList className="mb-6 max-w-full justify-start overflow-x-auto">
            <TabsTrigger value="catalog">
              Catalog ({approvedWholesalers.length} wholesaler
              {approvedWholesalers.length === 1 ? "" : "s"})
            </TabsTrigger>
            <TabsTrigger value="lists">Reorder lists ({reorderLists.lists.length})</TabsTrigger>
            <TabsTrigger value="orders">My orders ({orders.length})</TabsTrigger>
            <TabsTrigger value="returns">Returns</TabsTrigger>
            <TabsTrigger value="statements">Statements</TabsTrigger>
          </TabsList>

          <TabsContent value="catalog">
            <CatalogView
              products={products}
              discounts={discounts}
              wholesalers={approvedWholesalers}
              addToCart={addToCart}
              canOrder={canOrder}
              canEditLists={canEditLists}
              reorderLists={reorderLists}
            />
          </TabsContent>
          <TabsContent value="lists">
            <ReorderListsView
              api={reorderLists}
              products={products as unknown as Array<CatalogueOffer>}
              discounts={discounts}
              canEdit={canEditLists}
              canOrder={canOrder}
              onAddLines={addLinesToCart}
            />
          </TabsContent>
          <TabsContent value="returns">
            <ReturnsPanel
              businessId={business.id}
              side="pharmacy"
              canProcess={canOrder}
              canManage={false}
              refreshKey={returnsVersion}
            />
          </TabsContent>
          <TabsContent value="statements">
            <PharmacyStatements pharmacyId={business.id} wholesalers={approvedWholesalers} />
          </TabsContent>
          <TabsContent value="orders">
            <OrdersView
              orders={orders}
              totalCount={totalOrderCount}
              loadOrders={loadOrders}
              loadOrderDetail={loadOrderDetail}
              onReorder={canOrder ? reorderFromOrder : undefined}
              onRequestReturn={canOrder ? (id, label) => setReturnOrder({ id, order_number: label }) : undefined}
            />
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
          <SheetDescription>Review your items before placing your order.</SheetDescription>
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
  discounts,
  wholesalers,
  addToCart,
  canOrder,
  canEditLists,
  reorderLists,
}: {
  products: Product[];
  discounts: Record<string, { discount_type: string; discount_percent?: number; discount_amount?: number; minimum_order_value: number }>;
  wholesalers: WholesalerSummary[];
  addToCart: (id: string) => void;
  canOrder: boolean;
  canEditLists: boolean;
  reorderLists: ReorderListsApi;
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

  const availableCategories = useMemo(
    () => [...new Set(products.map((product) => product.category).filter((value): value is string => Boolean(value)))].sort((a, b) => a.localeCompare(b)),
    [products],
  );

  useEffect(() => {
    if (category !== "all" && !availableCategories.includes(category)) setCategory("all");
  }, [availableCategories, category]);

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
          <div className="mt-2 font-display text-3xl font-bold">{availableCategories.length}</div>
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
                {availableCategories.map((c) => (
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
                  {canEditLists && (
                    <div className="ml-auto">
                      <AddToListMenu
                        masterProductId={medicine.master_product_id}
                        name={medicine.name}
                        lists={reorderLists}
                      />
                    </div>
                  )}
                </div>
                <details className="mt-4">
                  <summary className="cursor-pointer text-sm font-medium text-primary">
                    Compare suppliers - from{" "}
                    {formatGHS(
                      Math.min(...offers.map((offer) => customerPrice(offer, discounts))),
                    )}
                  </summary>
                  <SupplierComparison
                    offers={offers as unknown as CatalogueOffer[]}
                    discounts={discounts}
                    canOrder={canOrder}
                    addToCart={addToCart}
                  />
                </details>
              </Card>
            );
          })}
        </div>
      )}
    </div>
  );
}

function OrdersView({ orders, totalCount, loadOrders, loadOrderDetail, onReorder, onRequestReturn }: {
  onRequestReturn?: (orderId: string, orderLabel: string) => void;
  onReorder?: (orderId: string, orderLabel: string) => Promise<void>;
  orders: OrderRow[];
  totalCount: number;
  loadOrders: (query?: OrderHistoryQuery) => Promise<void>;
  loadOrderDetail: (id: string, expectedItemCount?: number) => Promise<OrderRow | null>;
}) {
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
  const hasFilters = query.trim() !== "" || status !== "all" || payment !== "all";
  const pageCount = Math.max(1, Math.ceil(totalCount / pageSize));
  const pageOrders = orders;
  useEffect(() => { void loadOrders({ page, search: query, status, payment, sort }); }, [loadOrders, page, payment, query, sort, status]);
  useEffect(() => { if (page > pageCount) setPage(pageCount); }, [page, pageCount]);

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
      {pageOrders.length === 0 && (
        <Card className="p-10 text-center text-muted-foreground" role="status">
          <p>{hasFilters ? "No orders match your filters." : "No orders yet"}</p>
          <p className="mt-2 text-sm">
            {hasFilters ? "Try different filters or clear the filters to see all orders." : "Orders you place with approved wholesalers will appear here."}
          </p>
          {hasFilters && (
            <Button className="mt-4" variant="outline" onClick={() => {
              setQuery(""); setStatus("all"); setPayment("all"); setPage(1);
            }}>Clear filters</Button>
          )}
        </Card>
      )}
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
              <div className="text-xs text-muted-foreground">{o.item_count ?? o.order_items.length} item(s) · {o.unit_count ?? units} unit(s)</div>
            </div>
          </div>

          <div className="mt-3 flex justify-end gap-2 border-t border-border pt-3">{onRequestReturn && o.status === "delivered" && <Button type="button" variant="outline" size="sm" onClick={() => onRequestReturn(o.id, o.order_number)}>Request return</Button>}{onReorder && <Button type="button" variant="secondary" size="sm" onClick={() => void onReorder(o.id, o.order_number)}>Reorder</Button>}<Button type="button" variant="outline" size="sm" onClick={async () => { if (open) { setOpenOrderId(null); return; } if (o.order_items.length === 0) { const detail = await loadOrderDetail(o.id, o.item_count); if (!detail) return; } setOpenOrderId(o.id); }} aria-expanded={open}>{open ? "Hide Order" : "View Order"}</Button></div>
          {open && <>
          <OrderTimeline o={o} />

          <ReceiptStatusPanel order={o} />

          <DeliveryPanel orderId={o.id} status={o.status} side="pharmacy" canEdit={false} />

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
      <div className="flex items-center justify-between text-sm text-muted-foreground"><span>Showing {pageOrders.length} of {totalCount} orders</span><div className="flex gap-2"><Button size="sm" variant="outline" disabled={page <= 1} onClick={() => setPage((value) => value - 1)}>Previous</Button><Button size="sm" variant="outline" disabled={page >= pageCount} onClick={() => setPage((value) => value + 1)}>Next</Button></div></div>
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

function PharmacyRoute() {
  return (
    <WorkspaceGate>
      <PharmacyDashboardContent />
    </WorkspaceGate>
  );
}
