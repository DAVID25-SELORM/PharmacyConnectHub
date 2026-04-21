import { Outlet, createFileRoute, Link, useNavigate, useRouterState } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import {
  ArrowRight,
  Building2,
  FileText,
  Loader2,
  Pill,
  ShieldCheck,
  ShieldX,
  Store,
  Users,
  Eye,
  Edit,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Checkbox } from "@/components/ui/checkbox";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { toast } from "sonner";
import { useSession } from "@/hooks/use-session";
import { supabase } from "@/integrations/supabase/client";
import { timeAgo, formatGHS } from "@/lib/format";
import { shouldShowPrivateTeamGuidance } from "@/lib/private-team-guidance";
import { DashboardHeader } from "@/components/DashboardShell";

export const Route = createFileRoute("/admin")({
  head: () => ({
    meta: [{ title: "Admin — PharmaHub GH" }],
  }),
  component: AdminPanel,
});

type Biz = {
  id: string;
  type: "pharmacy" | "wholesaler";
  name: string;
  license_number: string | null;
  owner_is_superintendent: boolean;
  superintendent_name: string | null;
  city: string | null;
  region: string | null;
  phone: string | null;
  verification_status: "pending" | "approved" | "rejected";
  rejection_reason: string | null;
  created_at: string;
  owner_id: string;
};

type DocRow = { id: string; doc_type: string; storage_path: string; uploaded_at: string };

function AdminPanel() {
  const navigate = useNavigate();
  const pathname = useRouterState({ select: (state) => state.location.pathname });
  const { loading, user, roles, business, businesses } = useSession();
  const [businessRows, setBusinessRows] = useState<Biz[]>([]);
  const [stats, setStats] = useState({
    pharmacies: { total: 0, pending: 0, approved: 0, rejected: 0 },
    wholesalers: { total: 0, pending: 0, approved: 0, rejected: 0 },
    orders: 0,
    gmv: 0,
  });

  useEffect(() => {
    if (loading) return;
    if (!user) {
      navigate({ to: "/login" });
      return;
    }
    if (!roles.includes("admin")) {
      navigate({ to: "/dashboard" });
      return;
    }
  }, [loading, user, roles, navigate]);

  const load = async () => {
    const { data: bizData } = await supabase
      .from("businesses")
      .select("*")
      .order("created_at", { ascending: false });
    const all = (bizData as Biz[]) ?? [];
    setBusinessRows(all);

    const pharmacies = all.filter((b) => b.type === "pharmacy");
    const wholesalers = all.filter((b) => b.type === "wholesaler");

    const { data: orderAgg } = await supabase.from("orders").select("total_ghs,status");
    const orders = (orderAgg as { total_ghs: number; status: string }[]) ?? [];

    setStats({
      pharmacies: {
        total: pharmacies.length,
        pending: pharmacies.filter((b) => b.verification_status === "pending").length,
        approved: pharmacies.filter((b) => b.verification_status === "approved").length,
        rejected: pharmacies.filter((b) => b.verification_status === "rejected").length,
      },
      wholesalers: {
        total: wholesalers.length,
        pending: wholesalers.filter((b) => b.verification_status === "pending").length,
        approved: wholesalers.filter((b) => b.verification_status === "approved").length,
        rejected: wholesalers.filter((b) => b.verification_status === "rejected").length,
      },
      orders: orders.length,
      gmv: orders.reduce((s, o) => s + Number(o.total_ghs), 0),
    });
  };

  useEffect(() => {
    if (pathname === "/admin" && roles.includes("admin")) void load();
  }, [roles, pathname]);

  if (loading || !user || !roles.includes("admin")) {
    return (
      <div className="flex min-h-screen items-center justify-center text-muted-foreground">
        <Pill className="h-5 w-5 animate-pulse" />
        <span className="ml-2">Loading…</span>
      </div>
    );
  }

  if (pathname !== "/admin") {
    return <Outlet />;
  }

  const pending = businessRows.filter((b) => b.verification_status === "pending");
  const approved = businessRows.filter((b) => b.verification_status === "approved");
  const rejected = businessRows.filter((b) => b.verification_status === "rejected");
  const workspaceRoute = business?.type === "wholesaler" ? "/wholesaler" : "/pharmacy";
  const showPrivateTeamManagementCard = shouldShowPrivateTeamGuidance(user.email);

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="Admin console" />
      <main className="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 py-8">
        <h1 className="font-display text-3xl font-bold">Admin console</h1>
        <p className="mt-1 text-muted-foreground">
          Approve businesses and monitor platform health.
        </p>

        <div className="my-8 space-y-4">
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <Card className="p-5 border-primary/20 bg-primary/5">
              <div className="flex items-center justify-between mb-3">
                <div className="text-sm font-semibold text-primary">Pharmacies</div>
                <Store className="h-5 w-5 text-primary" />
              </div>
              <div className="font-display text-3xl font-bold">{stats.pharmacies.total}</div>
              <div className="mt-2 flex gap-3 text-xs">
                <span className="text-muted-foreground">{stats.pharmacies.approved} approved</span>
                <span className="text-muted-foreground">·</span>
                <span className="text-warning">{stats.pharmacies.pending} pending</span>
              </div>
            </Card>

            <Card className="p-5 border-accent/20 bg-accent/5">
              <div className="flex items-center justify-between mb-3">
                <div className="text-sm font-semibold text-accent">Wholesalers</div>
                <Building2 className="h-5 w-5 text-accent" />
              </div>
              <div className="font-display text-3xl font-bold">{stats.wholesalers.total}</div>
              <div className="mt-2 flex gap-3 text-xs">
                <span className="text-muted-foreground">{stats.wholesalers.approved} approved</span>
                <span className="text-muted-foreground">·</span>
                <span className="text-warning">{stats.wholesalers.pending} pending</span>
              </div>
            </Card>

            <Card className="p-5">
              <div className="flex items-center justify-between mb-3">
                <div className="text-sm font-semibold text-muted-foreground">
                  Pending Verification
                </div>
                <ShieldX className="h-5 w-5 text-warning" />
              </div>
              <div className="font-display text-3xl font-bold">
                {stats.pharmacies.pending + stats.wholesalers.pending}
              </div>
              <div className="mt-2 text-xs text-muted-foreground">Requires your approval</div>
            </Card>
          </div>

          <div className="grid gap-4 sm:grid-cols-2">
            <Card className="p-5">
              <div className="flex items-center justify-between mb-3">
                <div className="text-sm font-semibold text-muted-foreground">Total Orders</div>
                <FileText className="h-5 w-5 text-muted-foreground" />
              </div>
              <div className="font-display text-3xl font-bold">{stats.orders}</div>
              <div className="mt-2 text-xs text-muted-foreground">All-time platform orders</div>
            </Card>

            <Card className="p-5">
              <div className="flex items-center justify-between mb-3">
                <div className="text-sm font-semibold text-muted-foreground">Platform GMV</div>
                <ShieldCheck className="h-5 w-5 text-success" />
              </div>
              <div className="font-display text-3xl font-bold">{formatGHS(stats.gmv)}</div>
              <div className="mt-2 text-xs text-muted-foreground">Gross merchandise value</div>
            </Card>
          </div>
        </div>

        {showPrivateTeamManagementCard && (
          <Card className="mb-8 border-border/70 p-6">
            <div className="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
              <div>
                <div className="flex items-center gap-2 text-sm font-semibold">
                  <Users className="h-4 w-4 text-primary" />
                  Team Management
                </div>
                <h2 className="mt-2 font-display text-2xl font-bold">
                  Add staff from your interface
                </h2>
                <p className="mt-2 max-w-2xl text-sm text-muted-foreground">
                  Platform staff and business staff now live on separate routes. Use the admin team
                  page for platform access, and use the workspace team page for pharmacy or
                  wholesaler staff.
                </p>
              </div>
              <div className="flex flex-col gap-2 sm:flex-row">
                <Button asChild variant="hero">
                  <Link to="/admin/staff">
                    <ShieldCheck className="h-4 w-4" />
                    Platform team
                  </Link>
                </Button>
                {business ? (
                  <Button asChild variant="outline">
                    <Link to="/staff">
                      <Users className="h-4 w-4" />
                      Workspace team
                    </Link>
                  </Button>
                ) : businesses.length > 0 ? (
                  <Button asChild variant="outline">
                    <Link to="/dashboard">
                      <Users className="h-4 w-4" />
                      Choose workspace
                    </Link>
                  </Button>
                ) : null}
                {business ? (
                  <Button asChild variant="outline">
                    <Link to={workspaceRoute}>
                      Open workspace
                      <ArrowRight className="h-4 w-4" />
                    </Link>
                  </Button>
                ) : businesses.length > 0 ? (
                  <Button asChild variant="outline">
                    <Link to="/dashboard">
                      Choose workspace
                      <ArrowRight className="h-4 w-4" />
                    </Link>
                  </Button>
                ) : null}
              </div>
            </div>
            {!business && businesses.length === 0 && (
              <div className="mt-4 rounded-lg border border-dashed border-border px-4 py-3 text-sm text-muted-foreground">
                Team management appears after your account has a business workspace.
              </div>
            )}
          </Card>
        )}

        <Tabs defaultValue="pending">
          <TabsList className="mb-6">
            <TabsTrigger value="pending">Pending ({pending.length})</TabsTrigger>
            <TabsTrigger value="approved">Approved ({approved.length})</TabsTrigger>
            <TabsTrigger value="rejected">Rejected ({rejected.length})</TabsTrigger>
          </TabsList>
          <TabsContent value="pending">
            <BusinessList items={pending} reload={load} />
          </TabsContent>
          <TabsContent value="approved">
            <BusinessList items={approved} reload={load} />
          </TabsContent>
          <TabsContent value="rejected">
            <BusinessList items={rejected} reload={load} />
          </TabsContent>
        </Tabs>
      </main>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string | number }) {
  return (
    <Card className="p-5">
      <div className="text-xs uppercase tracking-wider text-muted-foreground">{label}</div>
      <div className="mt-2 font-display text-2xl font-bold">{value}</div>
    </Card>
  );
}

function BusinessList({ items, reload }: { items: Biz[]; reload: () => Promise<void> }) {
  if (items.length === 0) {
    return <Card className="p-10 text-center text-muted-foreground">Nothing here.</Card>;
  }
  return (
    <div className="space-y-3">
      {items.map((b) => (
        <BusinessCard key={b.id} biz={b} reload={reload} />
      ))}
    </div>
  );
}

function BusinessCard({ biz, reload }: { biz: Biz; reload: () => Promise<void> }) {
  const [docs, setDocs] = useState<DocRow[]>([]);
  const [showRejectDialog, setShowRejectDialog] = useState(false);
  const [showViewDialog, setShowViewDialog] = useState(false);
  const [showEditDialog, setShowEditDialog] = useState(false);
  const [rejectReason, setRejectReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [editForm, setEditForm] = useState({
    name: biz.name,
    license_number: biz.license_number ?? "",
    owner_is_superintendent: biz.owner_is_superintendent,
    superintendent_name: biz.superintendent_name ?? "",
    city: biz.city ?? "",
    region: biz.region ?? "",
    phone: biz.phone ?? "",
  });

  useEffect(() => {
    void supabase
      .from("license_documents")
      .select("*")
      .eq("business_id", biz.id)
      .order("uploaded_at", { ascending: false })
      .then(({ data }) => setDocs((data as DocRow[]) ?? []));
  }, [biz.id]);

  const openDoc = async (path: string) => {
    const { data, error } = await supabase.storage.from("licenses").createSignedUrl(path, 300);
    if (error) {
      toast.error(error.message);
      return;
    }
    window.open(data.signedUrl, "_blank");
  };

  const approve = async () => {
    setBusy(true);
    const { error } = await supabase
      .from("businesses")
      .update({
        verification_status: "approved",
        verified_at: new Date().toISOString(),
        rejection_reason: null,
      })
      .eq("id", biz.id);
    setBusy(false);
    if (error) {
      toast.error(error.message);
      return;
    }
    toast.success(`${biz.name} approved`);
    void reload();
  };

  const reject = async () => {
    if (!rejectReason.trim()) {
      toast.error("Add a reason");
      return;
    }
    setBusy(true);
    const { error } = await supabase
      .from("businesses")
      .update({ verification_status: "rejected", rejection_reason: rejectReason.trim() })
      .eq("id", biz.id);
    setBusy(false);
    if (error) {
      toast.error(error.message);
      return;
    }
    toast.success(`${biz.name} rejected`);
    setShowRejectDialog(false);
    setRejectReason("");
    void reload();
  };

  const saveEdit = async () => {
    if (!editForm.name.trim()) {
      toast.error("Business name is required");
      return;
    }
    if (
      biz.type === "pharmacy" &&
      !editForm.owner_is_superintendent &&
      !editForm.superintendent_name.trim()
    ) {
      toast.error("Superintendent pharmacist name is required");
      return;
    }
    setBusy(true);
    const { error } = await supabase
      .from("businesses")
      .update({
        name: editForm.name.trim(),
        license_number: editForm.license_number.trim() || null,
        owner_is_superintendent: biz.type === "pharmacy" ? editForm.owner_is_superintendent : true,
        superintendent_name:
          biz.type === "pharmacy" && !editForm.owner_is_superintendent
            ? editForm.superintendent_name.trim() || null
            : null,
        city: editForm.city.trim() || null,
        region: editForm.region.trim() || null,
        phone: editForm.phone.trim() || null,
      })
      .eq("id", biz.id);
    setBusy(false);
    if (error) {
      toast.error(error.message);
      return;
    }
    toast.success("Business details updated");
    setShowEditDialog(false);
    void reload();
  };

  const TypeIcon = biz.type === "wholesaler" ? Building2 : Store;

  return (
    <Card className="p-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="flex items-start gap-3">
          <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-muted">
            <TypeIcon className="h-5 w-5 text-primary" />
          </div>
          <div>
            <div className="flex items-center gap-2">
              <h3 className="font-display text-lg font-bold">{biz.name}</h3>
              <Badge variant="secondary" className="text-[10px] uppercase">
                {biz.type}
              </Badge>
            </div>
            <div className="text-sm text-muted-foreground">
              {biz.city ?? "—"}, {biz.region ?? "—"} · License {biz.license_number ?? "—"} ·{" "}
              {biz.phone ?? "—"}
            </div>
            {biz.type === "pharmacy" && (
              <div className="mt-1 text-xs text-muted-foreground">
                Superintendent:{" "}
                {biz.owner_is_superintendent
                  ? "Owner is also superintendent pharmacist"
                  : (biz.superintendent_name ?? "—")}
              </div>
            )}
            <div className="mt-1 text-xs text-muted-foreground">
              Submitted {timeAgo(biz.created_at)}
            </div>
            {biz.verification_status === "rejected" && biz.rejection_reason && (
              <div className="mt-2 text-xs text-destructive">Reason: {biz.rejection_reason}</div>
            )}
          </div>
        </div>
        <div className="flex gap-2">
          <Button variant="ghost" size="sm" onClick={() => setShowViewDialog(true)}>
            <Eye className="h-4 w-4" /> View
          </Button>
          <Button
            variant="ghost"
            size="sm"
            onClick={() => {
              setEditForm({
                name: biz.name,
                license_number: biz.license_number ?? "",
                owner_is_superintendent: biz.owner_is_superintendent,
                superintendent_name: biz.superintendent_name ?? "",
                city: biz.city ?? "",
                region: biz.region ?? "",
                phone: biz.phone ?? "",
              });
              setShowEditDialog(true);
            }}
          >
            <Edit className="h-4 w-4" /> Edit
          </Button>
          {biz.verification_status === "pending" && (
            <>
              <Button
                variant="outline"
                size="sm"
                onClick={() => setShowRejectDialog(true)}
                disabled={busy}
              >
                <ShieldX className="h-4 w-4" /> Reject
              </Button>
              <Button variant="hero" size="sm" onClick={approve} disabled={busy}>
                {busy ? (
                  <Loader2 className="h-4 w-4 animate-spin" />
                ) : (
                  <ShieldCheck className="h-4 w-4" />
                )}{" "}
                Approve
              </Button>
            </>
          )}
          {biz.verification_status === "approved" && (
            <Button variant="outline" size="sm" onClick={() => setShowRejectDialog(true)}>
              Revoke
            </Button>
          )}
          {biz.verification_status === "rejected" && (
            <Button variant="hero" size="sm" onClick={approve} disabled={busy}>
              Re-approve
            </Button>
          )}
        </div>
      </div>

      <div className="mt-4 border-t border-border pt-4">
        <div className="text-xs uppercase tracking-wider text-muted-foreground mb-2">Documents</div>
        {docs.length === 0 ? (
          <div className="text-sm text-muted-foreground italic">No documents uploaded yet.</div>
        ) : (
          <div className="flex flex-wrap gap-2">
            {docs.map((d) => (
              <Button
                key={d.id}
                variant="outline"
                size="sm"
                onClick={() => openDoc(d.storage_path)}
              >
                <FileText className="h-4 w-4" /> {d.doc_type}
              </Button>
            ))}
          </div>
        )}
      </div>

      <Dialog open={showRejectDialog} onOpenChange={setShowRejectDialog}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Reject {biz.name}</DialogTitle>
          </DialogHeader>
          <div className="space-y-2">
            <Label htmlFor="reason">Reason</Label>
            <Input
              id="reason"
              value={rejectReason}
              onChange={(e) => setRejectReason(e.target.value)}
              placeholder="Documents are not legible…"
            />
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setShowRejectDialog(false)}>
              Cancel
            </Button>
            <Button variant="hero" onClick={reject} disabled={busy}>
              Confirm reject
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={showViewDialog} onOpenChange={setShowViewDialog}>
        <DialogContent className="sm:max-w-2xl">
          <DialogHeader>
            <DialogTitle>Business Details</DialogTitle>
          </DialogHeader>
          <div className="space-y-4">
            <div className="grid gap-4 sm:grid-cols-2">
              <div>
                <div className="text-xs font-medium uppercase tracking-wider text-muted-foreground mb-1">
                  Business Name
                </div>
                <div className="font-semibold">{biz.name}</div>
              </div>
              <div>
                <div className="text-xs font-medium uppercase tracking-wider text-muted-foreground mb-1">
                  Type
                </div>
                <Badge variant="secondary" className="uppercase">
                  {biz.type}
                </Badge>
              </div>
              <div>
                <div className="text-xs font-medium uppercase tracking-wider text-muted-foreground mb-1">
                  License Number
                </div>
                <div>{biz.license_number ?? "—"}</div>
              </div>
              <div>
                <div className="text-xs font-medium uppercase tracking-wider text-muted-foreground mb-1">
                  Phone
                </div>
                <div>{biz.phone ?? "—"}</div>
              </div>
              {biz.type === "pharmacy" && (
                <div>
                  <div className="text-xs font-medium uppercase tracking-wider text-muted-foreground mb-1">
                    Superintendent Pharmacist
                  </div>
                  <div>
                    {biz.owner_is_superintendent
                      ? "Owner is also superintendent pharmacist"
                      : (biz.superintendent_name ?? "—")}
                  </div>
                </div>
              )}
              <div>
                <div className="text-xs font-medium uppercase tracking-wider text-muted-foreground mb-1">
                  City
                </div>
                <div>{biz.city ?? "—"}</div>
              </div>
              <div>
                <div className="text-xs font-medium uppercase tracking-wider text-muted-foreground mb-1">
                  Region
                </div>
                <div>{biz.region ?? "—"}</div>
              </div>
              <div>
                <div className="text-xs font-medium uppercase tracking-wider text-muted-foreground mb-1">
                  Status
                </div>
                <Badge
                  variant={
                    biz.verification_status === "approved"
                      ? "default"
                      : biz.verification_status === "rejected"
                        ? "destructive"
                        : "secondary"
                  }
                >
                  {biz.verification_status}
                </Badge>
              </div>
              <div>
                <div className="text-xs font-medium uppercase tracking-wider text-muted-foreground mb-1">
                  Submitted
                </div>
                <div className="text-sm">{timeAgo(biz.created_at)}</div>
              </div>
            </div>
            {biz.rejection_reason && (
              <div>
                <div className="text-xs font-medium uppercase tracking-wider text-destructive mb-1">
                  Rejection Reason
                </div>
                <div className="text-sm text-destructive">{biz.rejection_reason}</div>
              </div>
            )}
            <div>
              <div className="text-xs font-medium uppercase tracking-wider text-muted-foreground mb-2">
                Documents
              </div>
              {docs.length === 0 ? (
                <div className="text-sm text-muted-foreground italic">No documents uploaded</div>
              ) : (
                <div className="flex flex-wrap gap-2">
                  {docs.map((d) => (
                    <Button
                      key={d.id}
                      variant="outline"
                      size="sm"
                      onClick={() => openDoc(d.storage_path)}
                    >
                      <FileText className="h-4 w-4" /> {d.doc_type}
                    </Button>
                  ))}
                </div>
              )}
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setShowViewDialog(false)}>
              Close
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={showEditDialog} onOpenChange={setShowEditDialog}>
        <DialogContent className="sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>Edit Business Details</DialogTitle>
          </DialogHeader>
          <div className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="edit-name">Business Name *</Label>
              <Input
                id="edit-name"
                value={editForm.name}
                onChange={(e) => setEditForm({ ...editForm, name: e.target.value })}
                placeholder="Business name"
              />
            </div>
            <div className="grid gap-4 sm:grid-cols-2">
              <div className="space-y-2">
                <Label htmlFor="edit-license">License Number</Label>
                <Input
                  id="edit-license"
                  value={editForm.license_number}
                  onChange={(e) => setEditForm({ ...editForm, license_number: e.target.value })}
                  placeholder="PHA-2024-001"
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="edit-phone">Phone</Label>
                <Input
                  id="edit-phone"
                  value={editForm.phone}
                  onChange={(e) => setEditForm({ ...editForm, phone: e.target.value })}
                  placeholder="0240000000"
                />
              </div>
            </div>
            <div className="grid gap-4 sm:grid-cols-2">
              <div className="space-y-2">
                <Label htmlFor="edit-city">City</Label>
                <Input
                  id="edit-city"
                  value={editForm.city}
                  onChange={(e) => setEditForm({ ...editForm, city: e.target.value })}
                  placeholder="Accra"
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="edit-region">Region</Label>
                <Input
                  id="edit-region"
                  value={editForm.region}
                  onChange={(e) => setEditForm({ ...editForm, region: e.target.value })}
                  placeholder="Greater Accra"
                />
              </div>
            </div>
            {biz.type === "pharmacy" && (
              <div className="space-y-3 rounded-xl border border-border bg-muted/30 p-4">
                <div className="flex items-start gap-3">
                  <Checkbox
                    id="edit-owner-is-superintendent"
                    checked={editForm.owner_is_superintendent}
                    onCheckedChange={(checked) =>
                      setEditForm((current) => ({
                        ...current,
                        owner_is_superintendent: checked === true,
                        superintendent_name: checked === true ? "" : current.superintendent_name,
                      }))
                    }
                  />
                  <div className="space-y-1">
                    <Label
                      htmlFor="edit-owner-is-superintendent"
                      className="cursor-pointer text-sm font-medium"
                    >
                      Owner is also the Superintendent Pharmacist
                    </Label>
                    <p className="text-xs text-muted-foreground">
                      Turn this off only when the pharmacy owner and superintendent are different
                      people.
                    </p>
                  </div>
                </div>
                {!editForm.owner_is_superintendent && (
                  <div className="space-y-2">
                    <Label htmlFor="edit-superintendent-name">Superintendent Pharmacist Name</Label>
                    <Input
                      id="edit-superintendent-name"
                      value={editForm.superintendent_name}
                      onChange={(e) =>
                        setEditForm({ ...editForm, superintendent_name: e.target.value })
                      }
                      placeholder="Enter the superintendent pharmacist's name"
                    />
                  </div>
                )}
              </div>
            )}
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setShowEditDialog(false)}>
              Cancel
            </Button>
            <Button variant="hero" onClick={saveEdit} disabled={busy}>
              {busy && <Loader2 className="h-4 w-4 animate-spin" />} Save changes
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </Card>
  );
}
