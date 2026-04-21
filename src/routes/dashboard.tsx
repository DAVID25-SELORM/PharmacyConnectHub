import { Link, createFileRoute, useNavigate } from "@tanstack/react-router";
import {
  ArrowRight,
  Building2,
  ClipboardList,
  Package,
  Pill,
  Receipt,
  ShoppingBag,
  Store,
  Users,
  Wallet,
} from "lucide-react";
import { useEffect, useEffectEvent, useState } from "react";
import { DashboardHeader, VerificationBanner } from "@/components/DashboardShell";
import {
  PaymentBadge,
  StatusBadge,
  type OrderStatus,
  type PaymentStatus,
} from "@/components/order-status";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { supabase } from "@/integrations/supabase/client";
import { formatGHS, timeAgo } from "@/lib/format";
import { useSession, type Business } from "@/hooks/use-session";

export const Route = createFileRoute("/dashboard")({
  component: WorkspaceDashboard,
});

type PharmacyOrderSummary = {
  id: string;
  order_number: string;
  status: OrderStatus;
  payment_method: "cod" | "paystack";
  payment_status: PaymentStatus;
  total_ghs: number;
  created_at: string;
  receipt_sent_at: string | null;
  wholesaler: { name: string } | null;
};

type WholesalerOrderSummary = {
  id: string;
  order_number: string;
  status: OrderStatus;
  payment_method: "cod" | "paystack";
  payment_status: PaymentStatus;
  total_ghs: number;
  created_at: string;
  receipt_sent_at: string | null;
  pharmacy: { name: string } | null;
};

type PharmacySnapshot = {
  type: "pharmacy";
  approvedWholesalers: number;
  listedProducts: number;
  categoryCount: number;
  openOrders: number;
  awaitingReceipts: number;
  recentOrders: PharmacyOrderSummary[];
};

type WholesalerSnapshot = {
  type: "wholesaler";
  pendingOrders: number;
  activeSkus: number;
  lowStockSkus: number;
  awaitingPayment: number;
  receiptsSent: number;
  collectedRevenue: number;
  recentOrders: WholesalerOrderSummary[];
};

type DashboardSnapshot = PharmacySnapshot | WholesalerSnapshot;

type QueryLikeError = {
  code?: string | null;
  details?: string | null;
  hint?: string | null;
  message?: string | null;
};

type DashboardOrderQueryResult<T> = {
  legacyReceiptTracking: boolean;
  rows: T[];
};

function workspaceRoute(business: Business) {
  return business.type === "wholesaler" ? "/wholesaler" : "/pharmacy";
}

function isMissingReceiptTrackingError(error: QueryLikeError | null | undefined) {
  if (!error) {
    return false;
  }

  const description =
    `${error.message ?? ""} ${error.details ?? ""} ${error.hint ?? ""}`.toLowerCase();
  return (
    description.includes("receipt_sent_at") &&
    (description.includes("column") ||
      description.includes("schema cache") ||
      description.includes("does not exist"))
  );
}

async function loadPharmacyOrderSummaries(
  businessId: string,
): Promise<DashboardOrderQueryResult<PharmacyOrderSummary>> {
  const primary = await supabase
    .from("orders")
    .select(
      "id,order_number,status,payment_method,payment_status,total_ghs,created_at,receipt_sent_at,wholesaler:businesses!orders_wholesaler_id_fkey(name)",
    )
    .eq("pharmacy_id", businessId)
    .order("created_at", { ascending: false });

  if (!primary.error) {
    return {
      legacyReceiptTracking: false,
      rows: (primary.data ?? []) as PharmacyOrderSummary[],
    };
  }

  if (!isMissingReceiptTrackingError(primary.error)) {
    throw primary.error;
  }

  const fallback = await supabase
    .from("orders")
    .select(
      "id,order_number,status,payment_method,payment_status,total_ghs,created_at,wholesaler:businesses!orders_wholesaler_id_fkey(name)",
    )
    .eq("pharmacy_id", businessId)
    .order("created_at", { ascending: false });

  if (fallback.error) {
    throw fallback.error;
  }

  return {
    legacyReceiptTracking: true,
    rows: ((fallback.data ?? []) as Omit<PharmacyOrderSummary, "receipt_sent_at">[]).map(
      (order) => ({
        ...order,
        receipt_sent_at: null,
      }),
    ),
  };
}

async function loadWholesalerOrderSummaries(
  businessId: string,
): Promise<DashboardOrderQueryResult<WholesalerOrderSummary>> {
  const primary = await supabase
    .from("orders")
    .select(
      "id,order_number,status,payment_method,payment_status,total_ghs,created_at,receipt_sent_at,pharmacy:businesses!orders_pharmacy_id_fkey(name)",
    )
    .eq("wholesaler_id", businessId)
    .order("created_at", { ascending: false });

  if (!primary.error) {
    return {
      legacyReceiptTracking: false,
      rows: (primary.data ?? []) as WholesalerOrderSummary[],
    };
  }

  if (!isMissingReceiptTrackingError(primary.error)) {
    throw primary.error;
  }

  const fallback = await supabase
    .from("orders")
    .select(
      "id,order_number,status,payment_method,payment_status,total_ghs,created_at,pharmacy:businesses!orders_pharmacy_id_fkey(name)",
    )
    .eq("wholesaler_id", businessId)
    .order("created_at", { ascending: false });

  if (fallback.error) {
    throw fallback.error;
  }

  return {
    legacyReceiptTracking: true,
    rows: ((fallback.data ?? []) as Omit<WholesalerOrderSummary, "receipt_sent_at">[]).map(
      (order) => ({
        ...order,
        receipt_sent_at: null,
      }),
    ),
  };
}

function WorkspaceDashboard() {
  const { loading, user, roles, business, businesses, setActiveBusiness } = useSession();
  const navigate = useNavigate();
  const [snapshot, setSnapshot] = useState<DashboardSnapshot | null>(null);
  const [loadingSnapshot, setLoadingSnapshot] = useState(false);
  const [snapshotError, setSnapshotError] = useState<string | null>(null);
  const [snapshotNotice, setSnapshotNotice] = useState<string | null>(null);

  useEffect(() => {
    if (loading) return;
    if (!user) {
      navigate({ to: "/login" });
      return;
    }
    if (!business) {
      if (businesses.length === 0) {
        if (roles.includes("admin")) {
          navigate({ to: "/admin" });
          return;
        }
        navigate({ to: "/onboarding" });
      }
      return;
    }
    if (business.verification_status === "rejected") {
      navigate({ to: "/onboarding" });
    }
  }, [loading, user, roles, business, businesses, navigate]);

  const loadSnapshot = useEffectEvent(async () => {
    if (!business) {
      setSnapshot(null);
      return;
    }

    setLoadingSnapshot(true);
    setSnapshotError(null);
    setSnapshotNotice(null);

    try {
      if (business.type === "pharmacy") {
        const [{ data: productRows, error: productErr }, ordersResult] = await Promise.all([
          supabase
            .from("products")
            .select(
              "id, category, wholesaler_id, wholesaler:businesses!products_wholesaler_id_fkey(verification_status)",
            )
            .eq("active", true),
          loadPharmacyOrderSummaries(business.id),
        ]);

        if (productErr) {
          throw productErr;
        }

        if (ordersResult.legacyReceiptTracking) {
          setSnapshotNotice(
            "Receipt metrics are limited until the latest order receipt migration is applied in Supabase.",
          );
        }

        const orderRows = ordersResult.rows;

        const approvedProducts = (
          (productRows ?? []) as {
            id: string;
            category: string | null;
            wholesaler_id: string;
            wholesaler: { verification_status: string } | null;
          }[]
        ).filter((product) => product.wholesaler?.verification_status === "approved");

        const pharmacyOrders = ((orderRows ?? []) as PharmacyOrderSummary[]).slice(0, 5);

        setSnapshot({
          type: "pharmacy",
          approvedWholesalers: new Set(approvedProducts.map((product) => product.wholesaler_id))
            .size,
          listedProducts: approvedProducts.length,
          categoryCount: new Set(
            approvedProducts.map((product) => product.category).filter(Boolean),
          ).size,
          openOrders: (orderRows ?? []).filter(
            (order) => order.status !== "delivered" && order.status !== "cancelled",
          ).length,
          awaitingReceipts: (orderRows ?? []).filter(
            (order) => order.status === "delivered" && !order.receipt_sent_at,
          ).length,
          recentOrders: pharmacyOrders,
        });
      } else {
        const [{ data: productRows, error: productErr }, ordersResult] = await Promise.all([
          supabase.from("products").select("id, active, stock").eq("wholesaler_id", business.id),
          loadWholesalerOrderSummaries(business.id),
        ]);

        if (productErr) {
          throw productErr;
        }

        if (ordersResult.legacyReceiptTracking) {
          setSnapshotNotice(
            "Receipt metrics are limited until the latest order receipt migration is applied in Supabase.",
          );
        }

        const wholesalerProducts = (productRows ?? []) as {
          id: string;
          active: boolean;
          stock: number;
        }[];
        const wholesalerOrders = ordersResult.rows;

        setSnapshot({
          type: "wholesaler",
          pendingOrders: wholesalerOrders.filter((order) => order.status === "pending").length,
          activeSkus: wholesalerProducts.filter((product) => product.active).length,
          lowStockSkus: wholesalerProducts.filter(
            (product) => product.active && product.stock < 100,
          ).length,
          awaitingPayment: wholesalerOrders.filter(
            (order) => order.status === "delivered" && order.payment_status !== "paid",
          ).length,
          receiptsSent: wholesalerOrders.filter((order) => Boolean(order.receipt_sent_at)).length,
          collectedRevenue: wholesalerOrders
            .filter((order) => order.payment_status === "paid")
            .reduce((sum, order) => sum + Number(order.total_ghs), 0),
          recentOrders: wholesalerOrders.slice(0, 5),
        });
      }
    } catch (error) {
      setSnapshot(null);
      const message =
        error &&
        typeof error === "object" &&
        "message" in error &&
        typeof error.message === "string"
          ? error.message
          : "Dashboard data could not be loaded.";
      setSnapshotError(message);
    } finally {
      setLoadingSnapshot(false);
    }
  });

  useEffect(() => {
    if (business) {
      void loadSnapshot();
    }
  }, [business, loadSnapshot]);

  const openWorkspace = (workspace: Business) => {
    setActiveBusiness(workspace.id);
    navigate({ to: "/dashboard" });
  };

  if (loading || !user) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <div className="flex items-center gap-3 text-muted-foreground">
          <Pill className="h-5 w-5 animate-pulse" />
          <span>Loading your workspace…</span>
        </div>
      </div>
    );
  }

  if (!business && businesses.length > 1) {
    return (
      <div className="min-h-screen bg-background">
        <main className="mx-auto max-w-5xl px-4 py-12 sm:px-6 lg:px-8">
          <div className="mx-auto max-w-3xl text-center">
            <h1 className="font-display text-3xl font-bold">Choose a workspace</h1>
            <p className="mt-3 text-muted-foreground">
              This account can access more than one business. Pick the dashboard you want to open
              now.
            </p>
          </div>

          <div className="mt-8 grid gap-4 md:grid-cols-2">
            {businesses.map((workspace) => {
              const Icon = workspace.type === "wholesaler" ? Building2 : Store;

              return (
                <Card key={workspace.id} className="p-6">
                  <div className="flex items-start justify-between gap-4">
                    <div className="flex items-start gap-3">
                      <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-muted">
                        <Icon className="h-5 w-5 text-primary" />
                      </div>
                      <div>
                        <h2 className="font-display text-xl font-bold">{workspace.name}</h2>
                        <p className="mt-1 text-sm text-muted-foreground">
                          {workspace.city ?? "Location pending"}
                          {workspace.region ? `, ${workspace.region}` : ""}
                        </p>
                      </div>
                    </div>
                    <Badge variant="secondary" className="capitalize">
                      {workspace.type}
                    </Badge>
                  </div>

                  <div className="mt-4 flex flex-wrap gap-2">
                    <Badge variant="outline" className="capitalize">
                      {workspace.staff_role}
                    </Badge>
                    <Badge variant="outline" className="capitalize">
                      {workspace.verification_status}
                    </Badge>
                  </div>

                  <div className="mt-6 flex gap-2">
                    <Button variant="hero" onClick={() => openWorkspace(workspace)}>
                      Open dashboard
                    </Button>
                    {roles.includes("admin") && (
                      <Button variant="outline" onClick={() => navigate({ to: "/admin" })}>
                        Admin console
                      </Button>
                    )}
                  </div>
                </Card>
              );
            })}
          </div>
        </main>
      </div>
    );
  }

  if (!business) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <div className="flex items-center gap-3 text-muted-foreground">
          <Pill className="h-5 w-5 animate-pulse" />
          <span>Loading your workspace…</span>
        </div>
      </div>
    );
  }

  const workspaceLink = workspaceRoute(business);
  const workspaceLabel = business.type === "pharmacy" ? "Browse catalog" : "Open workspace";

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader
        subtitle={business.type === "pharmacy" ? "Pharmacy workspace" : "Wholesaler workspace"}
        showNav={true}
        isAdmin={roles.includes("admin")}
      />
      <main className="mx-auto max-w-7xl px-4 py-8 sm:px-6 lg:px-8">
        <div className="mb-6 flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1 className="font-display text-3xl font-bold">{business.name}</h1>
            <p className="mt-1 text-muted-foreground">
              {business.type === "pharmacy"
                ? "Overview of your pharmacy workspace, orders, and marketplace access."
                : "Overview of your wholesaler workspace, fulfilment, and catalog health."}
            </p>
          </div>
          <div className="flex flex-wrap gap-2">
            <Button asChild variant="hero">
              <Link to={workspaceLink}>
                {workspaceLabel} <ArrowRight className="h-4 w-4" />
              </Link>
            </Button>
            <Button asChild variant="outline">
              <Link to="/staff">
                Team <Users className="h-4 w-4" />
              </Link>
            </Button>
          </div>
        </div>

        <VerificationBanner business={business} />

        {snapshotNotice && (
          <Card className="mb-6 border-warning/30 bg-warning/5 p-4 text-sm text-muted-foreground">
            {snapshotNotice}
          </Card>
        )}

        {loadingSnapshot ? (
          <Card className="p-8 text-center text-muted-foreground">Loading dashboard…</Card>
        ) : snapshotError ? (
          <Card className="p-8 text-center">
            <div className="font-medium">Dashboard unavailable</div>
            <p className="mt-2 text-sm text-muted-foreground">{snapshotError}</p>
            <div className="mt-4 flex justify-center">
              <Button asChild variant="outline">
                <Link to={workspaceLink}>Open workspace instead</Link>
              </Button>
            </div>
          </Card>
        ) : !snapshot ? (
          <Card className="p-8 text-center text-muted-foreground">
            Dashboard data is not available right now.
          </Card>
        ) : snapshot.type === "pharmacy" ? (
          <div className="space-y-8">
            <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
              <StatCard
                label="Approved Wholesalers"
                value={String(snapshot.approvedWholesalers)}
                helper="Verified suppliers available right now."
                icon={<Building2 className="h-5 w-5" />}
              />
              <StatCard
                label="Listed Products"
                value={String(snapshot.listedProducts)}
                helper="Active medicines visible in the marketplace."
                icon={<Package className="h-5 w-5" />}
              />
              <StatCard
                label="Open Orders"
                value={String(snapshot.openOrders)}
                helper="Orders still moving through fulfilment."
                icon={<ClipboardList className="h-5 w-5" />}
              />
              <StatCard
                label="Awaiting Receipts"
                value={String(snapshot.awaitingReceipts)}
                helper="Delivered orders that still need a receipt email."
                icon={<Receipt className="h-5 w-5" />}
              />
            </div>

            <div className="grid gap-6 lg:grid-cols-[1.4fr,0.9fr]">
              <RecentPharmacyOrdersCard orders={snapshot.recentOrders} />
              <QuickActionsCard
                title="Quick Actions"
                items={[
                  {
                    title: "Browse catalog",
                    description: "Compare verified wholesalers and place new orders.",
                    to: "/pharmacy",
                  },
                  {
                    title: "Manage team",
                    description: "Invite staff and control who can order for the pharmacy.",
                    to: "/staff",
                  },
                  ...(roles.includes("admin")
                    ? [
                        {
                          title: "Admin console",
                          description:
                            "Open platform oversight tools without leaving your workspace.",
                          to: "/admin",
                        },
                      ]
                    : []),
                ]}
              />
            </div>

            <Card className="p-5">
              <div className="flex flex-wrap items-center justify-between gap-3">
                <div>
                  <div className="text-sm font-semibold">Marketplace health</div>
                  <p className="mt-1 text-sm text-muted-foreground">
                    Browse stays focused on shopping. This dashboard keeps the top-level numbers in
                    one place.
                  </p>
                </div>
                <Badge variant="outline">{snapshot.categoryCount} categories live</Badge>
              </div>
            </Card>
          </div>
        ) : (
          <div className="space-y-8">
            <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-5">
              <StatCard
                label="Pending Orders"
                value={String(snapshot.pendingOrders)}
                helper="New orders waiting for action."
                icon={<ShoppingBag className="h-5 w-5" />}
              />
              <StatCard
                label="Active SKUs"
                value={String(snapshot.activeSkus)}
                helper="Products currently visible to pharmacies."
                icon={<Package className="h-5 w-5" />}
              />
              <StatCard
                label="Low Stock"
                value={String(snapshot.lowStockSkus)}
                helper="Active items below 100 units."
                icon={<Store className="h-5 w-5" />}
              />
              <StatCard
                label="Awaiting Payment"
                value={String(snapshot.awaitingPayment)}
                helper="Delivered COD orders still waiting for confirmation."
                icon={<Wallet className="h-5 w-5" />}
              />
              <StatCard
                label="Collected Revenue"
                value={formatGHS(snapshot.collectedRevenue)}
                helper={`${snapshot.receiptsSent} receipt email${snapshot.receiptsSent === 1 ? "" : "s"} sent`}
                icon={<Receipt className="h-5 w-5" />}
              />
            </div>

            <div className="grid gap-6 lg:grid-cols-[1.4fr,0.9fr]">
              <RecentWholesalerOrdersCard orders={snapshot.recentOrders} />
              <QuickActionsCard
                title="Quick Actions"
                items={[
                  {
                    title: "Open workspace",
                    description: "Process orders, confirm payments, and manage products.",
                    to: "/wholesaler",
                  },
                  {
                    title: "Manage team",
                    description: "Update wholesaler staff access and order-processing roles.",
                    to: "/staff",
                  },
                  ...(roles.includes("admin")
                    ? [
                        {
                          title: "Admin console",
                          description: "Jump to platform oversight without leaving this account.",
                          to: "/admin",
                        },
                      ]
                    : []),
                ]}
              />
            </div>
          </div>
        )}
      </main>
    </div>
  );
}

function StatCard({
  label,
  value,
  helper,
  icon,
}: {
  label: string;
  value: string;
  helper: string;
  icon: React.ReactNode;
}) {
  return (
    <Card className="p-5">
      <div className="flex items-start justify-between gap-3">
        <div>
          <div className="text-xs uppercase tracking-wider text-muted-foreground">{label}</div>
          <div className="mt-2 font-display text-3xl font-bold">{value}</div>
          <p className="mt-2 text-sm text-muted-foreground">{helper}</p>
        </div>
        <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-muted text-primary">
          {icon}
        </div>
      </div>
    </Card>
  );
}

function RecentPharmacyOrdersCard({ orders }: { orders: PharmacyOrderSummary[] }) {
  return (
    <Card className="p-5">
      <div className="flex items-center justify-between gap-3">
        <div>
          <div className="font-semibold">Recent Orders</div>
          <p className="mt-1 text-sm text-muted-foreground">
            Your latest pharmacy orders and where they stand.
          </p>
        </div>
        <Button asChild variant="outline" size="sm">
          <Link to="/pharmacy">Open browse</Link>
        </Button>
      </div>

      {orders.length === 0 ? (
        <div className="mt-4 rounded-xl border border-dashed border-border p-6 text-sm text-muted-foreground">
          You have not placed any orders yet.
        </div>
      ) : (
        <div className="mt-4 space-y-3">
          {orders.map((order) => (
            <div
              key={order.id}
              className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-border p-4"
            >
              <div>
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-medium">{order.order_number}</span>
                  <StatusBadge status={order.status} />
                  <PaymentBadge method={order.payment_method} status={order.payment_status} />
                </div>
                <div className="mt-1 text-sm text-muted-foreground">
                  {order.wholesaler?.name ?? "Wholesaler"} · {timeAgo(order.created_at)}
                </div>
              </div>
              <div className="text-right">
                <div className="font-semibold">{formatGHS(order.total_ghs)}</div>
                <div className="text-xs text-muted-foreground">
                  {order.receipt_sent_at ? "Receipt emailed" : "Receipt pending"}
                </div>
              </div>
            </div>
          ))}
        </div>
      )}
    </Card>
  );
}

function RecentWholesalerOrdersCard({ orders }: { orders: WholesalerOrderSummary[] }) {
  return (
    <Card className="p-5">
      <div className="flex items-center justify-between gap-3">
        <div>
          <div className="font-semibold">Recent Orders</div>
          <p className="mt-1 text-sm text-muted-foreground">
            Your latest incoming orders and payment state.
          </p>
        </div>
        <Button asChild variant="outline" size="sm">
          <Link to="/wholesaler">Open workspace</Link>
        </Button>
      </div>

      {orders.length === 0 ? (
        <div className="mt-4 rounded-xl border border-dashed border-border p-6 text-sm text-muted-foreground">
          No orders yet.
        </div>
      ) : (
        <div className="mt-4 space-y-3">
          {orders.map((order) => (
            <div
              key={order.id}
              className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-border p-4"
            >
              <div>
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-medium">{order.order_number}</span>
                  <StatusBadge status={order.status} />
                  <PaymentBadge method={order.payment_method} status={order.payment_status} />
                </div>
                <div className="mt-1 text-sm text-muted-foreground">
                  {order.pharmacy?.name ?? "Pharmacy"} · {timeAgo(order.created_at)}
                </div>
              </div>
              <div className="text-right">
                <div className="font-semibold">{formatGHS(order.total_ghs)}</div>
                <div className="text-xs text-muted-foreground">
                  {order.receipt_sent_at ? "Receipt sent" : "Receipt not sent"}
                </div>
              </div>
            </div>
          ))}
        </div>
      )}
    </Card>
  );
}

function QuickActionsCard({
  title,
  items,
}: {
  title: string;
  items: Array<{
    title: string;
    description: string;
    to: string;
  }>;
}) {
  return (
    <Card className="p-5">
      <div className="font-semibold">{title}</div>
      <div className="mt-4 space-y-3">
        {items.map((item) => (
          <Link
            key={item.title}
            to={item.to}
            className="block rounded-xl border border-border p-4 transition-colors hover:border-primary/40 hover:bg-muted/40"
          >
            <div className="flex items-start justify-between gap-3">
              <div>
                <div className="font-medium">{item.title}</div>
                <p className="mt-1 text-sm text-muted-foreground">{item.description}</p>
              </div>
              <ArrowRight className="mt-0.5 h-4 w-4 text-muted-foreground" />
            </div>
          </Link>
        ))}
      </div>
    </Card>
  );
}
