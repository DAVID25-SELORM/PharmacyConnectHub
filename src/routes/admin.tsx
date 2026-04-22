import { Outlet, createFileRoute, Link, useNavigate, useRouterState } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import {
  ArrowRight,
  Building2,
  Edit,
  Eye,
  FileText,
  Loader2,
  Pill,
  ShieldCheck,
  ShieldX,
  Store,
  Users,
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
import { Textarea } from "@/components/ui/textarea";
import { toast } from "sonner";
import { DashboardHeader } from "@/components/DashboardShell";
import { useSession } from "@/hooks/use-session";
import { getIncompleteVerificationFields } from "@/lib/business-verification";
import { timeAgo, formatGHS } from "@/lib/format";
import { formatGhanaPhone, normalizeGhanaPhone } from "@/lib/ghana-phone";
import { shouldShowPrivateTeamGuidance } from "@/lib/private-team-guidance";
import { supabase } from "@/integrations/supabase/client";

export const Route = createFileRoute("/admin")({
  head: () => ({
    meta: [{ title: "Admin - PharmaHub GH" }],
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
  address: string | null;
  public_email: string | null;
  working_hours: string | null;
  location_description: string | null;
  verification_status: "pending" | "approved" | "rejected";
  rejection_reason: string | null;
  created_at: string;
  owner_id: string;
};

type DocRow = {
  id: string;
  doc_type: string;
  storage_path: string;
  uploaded_at: string;
};

type PrivateContact = {
  business_id: string;
  owner_full_name: string | null;
  owner_phone: string | null;
  owner_email: string | null;
  superintendent_full_name: string | null;
  superintendent_phone: string | null;
  superintendent_email: string | null;
};

type EditForm = {
  name: string;
  license_number: string;
  owner_is_superintendent: boolean;
  superintendent_name: string;
  city: string;
  region: string;
  phone: string;
  address: string;
  public_email: string;
  working_hours: string;
  location_description: string;
  owner_full_name: string;
  owner_phone: string;
  owner_email: string;
  superintendent_phone: string;
  superintendent_email: string;
};

type IncompleteVerificationRecord = {
  businessId: string;
  businessName: string;
  type: Biz["type"];
  verificationStatus: Biz["verification_status"];
  ownerIsSuperintendent: boolean;
  missingFields: string[];
};

function firstNonEmpty(...values: Array<string | null | undefined>) {
  for (const value of values) {
    if (value?.trim()) {
      return value;
    }
  }

  return null;
}

function buildEditForm(biz: Biz, privateContact: PrivateContact | null): EditForm {
  return {
    name: biz.name,
    license_number: biz.license_number ?? "",
    owner_is_superintendent: biz.owner_is_superintendent,
    superintendent_name:
      firstNonEmpty(privateContact?.superintendent_full_name, biz.superintendent_name) ?? "",
    city: biz.city ?? "",
    region: biz.region ?? "",
    phone: biz.phone ?? "",
    address: biz.address ?? "",
    public_email: biz.public_email ?? "",
    working_hours: biz.working_hours ?? "",
    location_description: biz.location_description ?? "",
    owner_full_name: privateContact?.owner_full_name ?? "",
    owner_phone: privateContact?.owner_phone ?? "",
    owner_email: privateContact?.owner_email ?? "",
    superintendent_phone: biz.owner_is_superintendent
      ? (privateContact?.owner_phone ?? "")
      : (privateContact?.superintendent_phone ?? ""),
    superintendent_email: biz.owner_is_superintendent
      ? (privateContact?.owner_email ?? "")
      : (privateContact?.superintendent_email ?? ""),
  };
}

function looksLikeEmail(value: string) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

function DetailField({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="mb-1 text-xs font-medium uppercase tracking-wider text-muted-foreground">
        {label}
      </div>
      <div className="break-words text-sm">{value}</div>
    </div>
  );
}

function AdminPanel() {
  const navigate = useNavigate();
  const pathname = useRouterState({ select: (state) => state.location.pathname });
  const { loading, user, roles, business, businesses } = useSession();
  const [businessRows, setBusinessRows] = useState<Biz[]>([]);
  const [privateContactsByBusinessId, setPrivateContactsByBusinessId] = useState<
    Record<string, PrivateContact>
  >({});
  const [incompleteVerificationRecords, setIncompleteVerificationRecords] = useState<
    IncompleteVerificationRecord[]
  >([]);
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
    }
  }, [loading, navigate, roles, user]);

  const load = async () => {
    const [bizResult, orderResult, privateContactsResult] = await Promise.all([
      supabase.from("businesses").select("*").order("created_at", { ascending: false }),
      supabase.from("orders").select("total_ghs,status"),
      supabase.from("business_private_contacts").select("*"),
    ]);

    const all = (bizResult.data as Biz[]) ?? [];
    setBusinessRows(all);

    const pharmacies = all.filter((row) => row.type === "pharmacy");
    const wholesalers = all.filter((row) => row.type === "wholesaler");
    const orders = (orderResult.data as { total_ghs: number; status: string }[]) ?? [];

    if (!privateContactsResult.error) {
      const privateContacts = (privateContactsResult.data as PrivateContact[]) ?? [];
      const privateContactsIndex = Object.fromEntries(
        privateContacts.map((contact) => [contact.business_id, contact]),
      ) as Record<string, PrivateContact>;

      setPrivateContactsByBusinessId(privateContactsIndex);
      setIncompleteVerificationRecords(
        all
          .map((row) => {
            const missingFields = getIncompleteVerificationFields(
              row,
              privateContactsIndex[row.id] ?? null,
            );

            if (missingFields.length === 0) {
              return null;
            }

            return {
              businessId: row.id,
              businessName: row.name,
              type: row.type,
              verificationStatus: row.verification_status,
              ownerIsSuperintendent: row.owner_is_superintendent,
              missingFields,
            } satisfies IncompleteVerificationRecord;
          })
          .filter((record): record is IncompleteVerificationRecord => record !== null),
      );
    } else {
      setPrivateContactsByBusinessId({});
      setIncompleteVerificationRecords([]);
    }

    setStats({
      pharmacies: {
        total: pharmacies.length,
        pending: pharmacies.filter((row) => row.verification_status === "pending").length,
        approved: pharmacies.filter((row) => row.verification_status === "approved").length,
        rejected: pharmacies.filter((row) => row.verification_status === "rejected").length,
      },
      wholesalers: {
        total: wholesalers.length,
        pending: wholesalers.filter((row) => row.verification_status === "pending").length,
        approved: wholesalers.filter((row) => row.verification_status === "approved").length,
        rejected: wholesalers.filter((row) => row.verification_status === "rejected").length,
      },
      orders: orders.length,
      gmv: orders.reduce((sum, order) => sum + Number(order.total_ghs), 0),
    });
  };

  useEffect(() => {
    if (pathname === "/admin" && roles.includes("admin")) {
      void load();
    }
  }, [pathname, roles]);

  if (loading || !user || !roles.includes("admin")) {
    return (
      <div className="flex min-h-screen items-center justify-center text-muted-foreground">
        <Pill className="h-5 w-5 animate-pulse" />
        <span className="ml-2">Loading...</span>
      </div>
    );
  }

  if (pathname !== "/admin") {
    return <Outlet />;
  }

  const pending = businessRows.filter((row) => row.verification_status === "pending");
  const approved = businessRows.filter((row) => row.verification_status === "approved");
  const rejected = businessRows.filter((row) => row.verification_status === "rejected");
  const workspaceRoute = business?.type === "wholesaler" ? "/wholesaler" : "/pharmacy";
  const showPrivateTeamGuidance = shouldShowPrivateTeamGuidance(user.email);

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="Admin console" />
      <main className="mx-auto max-w-7xl px-4 py-8 sm:px-6 lg:px-8">
        <h1 className="font-display text-3xl font-bold">Admin console</h1>
        <p className="mt-1 text-muted-foreground">
          Approve businesses and monitor platform health.
        </p>

        <div className="my-8 space-y-4">
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <Card className="border-primary/20 bg-primary/5 p-5">
              <div className="mb-3 flex items-center justify-between">
                <div className="text-sm font-semibold text-primary">Pharmacies</div>
                <Store className="h-5 w-5 text-primary" />
              </div>
              <div className="font-display text-3xl font-bold">{stats.pharmacies.total}</div>
              <div className="mt-2 flex gap-3 text-xs">
                <span className="text-muted-foreground">{stats.pharmacies.approved} approved</span>
                <span className="text-muted-foreground">|</span>
                <span className="text-warning">{stats.pharmacies.pending} pending</span>
              </div>
            </Card>

            <Card className="border-accent/20 bg-accent/5 p-5">
              <div className="mb-3 flex items-center justify-between">
                <div className="text-sm font-semibold text-accent">Wholesalers</div>
                <Building2 className="h-5 w-5 text-accent" />
              </div>
              <div className="font-display text-3xl font-bold">{stats.wholesalers.total}</div>
              <div className="mt-2 flex gap-3 text-xs">
                <span className="text-muted-foreground">{stats.wholesalers.approved} approved</span>
                <span className="text-muted-foreground">|</span>
                <span className="text-warning">{stats.wholesalers.pending} pending</span>
              </div>
            </Card>

            <Card className="p-5">
              <div className="mb-3 flex items-center justify-between">
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
              <div className="mb-3 flex items-center justify-between">
                <div className="text-sm font-semibold text-muted-foreground">Total Orders</div>
                <FileText className="h-5 w-5 text-muted-foreground" />
              </div>
              <div className="font-display text-3xl font-bold">{stats.orders}</div>
              <div className="mt-2 text-xs text-muted-foreground">All-time platform orders</div>
            </Card>

            <Card className="p-5">
              <div className="mb-3 flex items-center justify-between">
                <div className="text-sm font-semibold text-muted-foreground">Platform GMV</div>
                <ShieldCheck className="h-5 w-5 text-success" />
              </div>
              <div className="font-display text-3xl font-bold">{formatGHS(stats.gmv)}</div>
              <div className="mt-2 text-xs text-muted-foreground">Gross merchandise value</div>
            </Card>
          </div>
        </div>

        {incompleteVerificationRecords.length > 0 && (
          <Card className="mb-8 border-warning/30 bg-warning/5 p-6">
            <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
              <div>
                <div className="flex items-center gap-2 text-sm font-semibold text-warning">
                  <ShieldX className="h-4 w-4" />
                  Incomplete verification records
                </div>
                <h2 className="mt-2 font-display text-2xl font-bold">
                  {incompleteVerificationRecords.length} business
                  {incompleteVerificationRecords.length === 1 ? "" : "es"} still need private
                  contact cleanup
                </h2>
                <p className="mt-2 max-w-3xl text-sm text-muted-foreground">
                  These are usually older records created before the new verification fields were
                  enforced. Open the matching business card below and complete the missing internal
                  details.
                </p>
              </div>
              <Badge variant="secondary" className="w-fit uppercase">
                {incompleteVerificationRecords.length} to review
              </Badge>
            </div>

            <div className="mt-4 space-y-3">
              {incompleteVerificationRecords.map((record) => (
                <div
                  key={record.businessId}
                  className="rounded-xl border border-border/70 bg-background/80 p-4"
                >
                  <div className="flex flex-wrap items-center gap-2">
                    <div className="font-semibold">{record.businessName}</div>
                    <Badge variant="secondary" className="uppercase">
                      {record.type}
                    </Badge>
                    <Badge
                      variant={
                        record.verificationStatus === "approved"
                          ? "default"
                          : record.verificationStatus === "rejected"
                            ? "destructive"
                            : "secondary"
                      }
                    >
                      {record.verificationStatus}
                    </Badge>
                  </div>
                  <div className="mt-2 text-sm text-muted-foreground">
                    Missing or invalid: {record.missingFields.join(", ")}
                  </div>
                  {record.type === "pharmacy" && !record.ownerIsSuperintendent && (
                    <div className="mt-1 text-xs text-muted-foreground">
                      This pharmacy requires a separate superintendent record.
                    </div>
                  )}
                </div>
              ))}
            </div>
          </Card>
        )}

        <Card className="mb-8 border-border/70 p-6">
          <div className="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
            <div>
              <div className="flex items-center gap-2 text-sm font-semibold">
                <Users className="h-4 w-4 text-primary" />
                Team Management
              </div>
              <h2 className="mt-2 font-display text-2xl font-bold">Manage platform staff</h2>
              <p className="mt-2 max-w-2xl text-sm text-muted-foreground">
                Platform staff live on the admin side at{" "}
                <span className="font-medium">/admin/staff</span>. Use the workspace team page for
                pharmacy or wholesaler staff.
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

          {showPrivateTeamGuidance && (
            <div className="mt-4 rounded-lg border border-dashed border-border px-4 py-3 text-sm text-muted-foreground">
              Platform staff stay on the admin side. Use the workspace route when you want to add
              staff inside a specific pharmacy or wholesaler account.
            </div>
          )}

          {!business && businesses.length === 0 && (
            <div className="mt-4 rounded-lg border border-dashed border-border px-4 py-3 text-sm text-muted-foreground">
              Workspace team management appears after your account has a business workspace.
            </div>
          )}
        </Card>

        <Tabs defaultValue="pending">
          <TabsList className="mb-6">
            <TabsTrigger value="pending">Pending ({pending.length})</TabsTrigger>
            <TabsTrigger value="approved">Approved ({approved.length})</TabsTrigger>
            <TabsTrigger value="rejected">Rejected ({rejected.length})</TabsTrigger>
          </TabsList>

          <TabsContent value="pending">
            <BusinessList
              items={pending}
              privateContactsByBusinessId={privateContactsByBusinessId}
              reload={load}
            />
          </TabsContent>
          <TabsContent value="approved">
            <BusinessList
              items={approved}
              privateContactsByBusinessId={privateContactsByBusinessId}
              reload={load}
            />
          </TabsContent>
          <TabsContent value="rejected">
            <BusinessList
              items={rejected}
              privateContactsByBusinessId={privateContactsByBusinessId}
              reload={load}
            />
          </TabsContent>
        </Tabs>
      </main>
    </div>
  );
}

function BusinessList({
  items,
  privateContactsByBusinessId,
  reload,
}: {
  items: Biz[];
  privateContactsByBusinessId: Record<string, PrivateContact>;
  reload: () => Promise<void>;
}) {
  if (items.length === 0) {
    return <Card className="p-10 text-center text-muted-foreground">Nothing here.</Card>;
  }

  return (
    <div className="space-y-3">
      {items.map((business) => (
        <BusinessCard
          key={business.id}
          biz={business}
          initialPrivateContact={privateContactsByBusinessId[business.id] ?? null}
          reload={reload}
        />
      ))}
    </div>
  );
}

function BusinessCard({
  biz,
  initialPrivateContact,
  reload,
}: {
  biz: Biz;
  initialPrivateContact: PrivateContact | null;
  reload: () => Promise<void>;
}) {
  const [docs, setDocs] = useState<DocRow[]>([]);
  const [privateContact, setPrivateContact] = useState<PrivateContact | null>(
    initialPrivateContact,
  );
  const [showRejectDialog, setShowRejectDialog] = useState(false);
  const [showViewDialog, setShowViewDialog] = useState(false);
  const [showEditDialog, setShowEditDialog] = useState(false);
  const [rejectReason, setRejectReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [editForm, setEditForm] = useState<EditForm>(() => buildEditForm(biz, null));

  useEffect(() => {
    let cancelled = false;

    void supabase
      .from("license_documents")
      .select("*")
      .eq("business_id", biz.id)
      .order("uploaded_at", { ascending: false })
      .then((docsResult) => {
        if (cancelled) {
          return;
        }

        setDocs((docsResult.data as DocRow[]) ?? []);
      });

    return () => {
      cancelled = true;
    };
  }, [biz.id]);

  useEffect(() => {
    setPrivateContact(initialPrivateContact);
  }, [initialPrivateContact]);

  useEffect(() => {
    setEditForm(buildEditForm(biz, privateContact));
  }, [biz, privateContact]);

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
    const reason = rejectReason.trim();

    if (!reason) {
      toast.error("Add a reason");
      return;
    }

    setBusy(true);

    const { error } = await supabase
      .from("businesses")
      .update({ verification_status: "rejected", rejection_reason: reason })
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
    const trimmedBusinessName = editForm.name.trim();
    const trimmedOwnerFullName = editForm.owner_full_name.trim();
    const trimmedOwnerEmail = editForm.owner_email.trim().toLowerCase();
    const trimmedPublicEmail = editForm.public_email.trim().toLowerCase();
    const trimmedSuperintendentName = editForm.superintendent_name.trim();
    const trimmedSuperintendentEmail = editForm.superintendent_email.trim().toLowerCase();

    if (!trimmedBusinessName) {
      toast.error("Business name is required");
      return;
    }

    if (!trimmedOwnerFullName) {
      toast.error("Owner full name is required");
      return;
    }

    if (!looksLikeEmail(trimmedOwnerEmail)) {
      toast.error("Enter a valid owner email address");
      return;
    }

    if (trimmedPublicEmail && !looksLikeEmail(trimmedPublicEmail)) {
      toast.error("Enter a valid public business email address");
      return;
    }

    if (
      biz.type === "pharmacy" &&
      !editForm.owner_is_superintendent &&
      !trimmedSuperintendentName
    ) {
      toast.error("Superintendent pharmacist name is required");
      return;
    }

    if (
      biz.type === "pharmacy" &&
      !editForm.owner_is_superintendent &&
      !looksLikeEmail(trimmedSuperintendentEmail)
    ) {
      toast.error("Enter a valid superintendent pharmacist email address");
      return;
    }

    let normalizedBusinessPhone: string | null = null;
    let normalizedOwnerPhone = "";
    let normalizedSuperintendentPhone: string | null = null;

    try {
      normalizedOwnerPhone = normalizeGhanaPhone(editForm.owner_phone);
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "Enter a valid owner phone number");
      return;
    }

    if (editForm.phone.trim()) {
      try {
        normalizedBusinessPhone = normalizeGhanaPhone(editForm.phone);
      } catch {
        toast.error("Enter a valid public business phone number");
        return;
      }
    }

    if (biz.type === "pharmacy") {
      if (editForm.owner_is_superintendent) {
        normalizedSuperintendentPhone = normalizedOwnerPhone;
      } else {
        try {
          normalizedSuperintendentPhone = normalizeGhanaPhone(editForm.superintendent_phone);
        } catch {
          toast.error("Enter a valid superintendent pharmacist phone number");
          return;
        }
      }
    }

    setBusy(true);

    const superintendentFullName =
      biz.type !== "pharmacy"
        ? null
        : editForm.owner_is_superintendent
          ? trimmedOwnerFullName
          : trimmedSuperintendentName;
    const superintendentEmail =
      biz.type !== "pharmacy"
        ? null
        : editForm.owner_is_superintendent
          ? trimmedOwnerEmail
          : trimmedSuperintendentEmail;

    const { data: updatedPrivateContacts, error } = await supabase.rpc(
      "update_business_profile_with_contacts",
      {
        _business_id: biz.id,
        _name: trimmedBusinessName,
        _license_number: editForm.license_number.trim() || null,
        _owner_is_superintendent: biz.type === "pharmacy" ? editForm.owner_is_superintendent : true,
        _superintendent_name: superintendentFullName,
        _city: editForm.city.trim() || null,
        _region: editForm.region.trim() || null,
        _phone: normalizedBusinessPhone,
        _address: editForm.address.trim() || null,
        _public_email: trimmedPublicEmail || null,
        _working_hours: editForm.working_hours.trim() || null,
        _location_description: editForm.location_description.trim() || null,
        _owner_full_name: trimmedOwnerFullName,
        _owner_phone: normalizedOwnerPhone,
        _owner_email: trimmedOwnerEmail,
        _superintendent_phone: normalizedSuperintendentPhone,
        _superintendent_email: superintendentEmail,
      },
    );

    setBusy(false);

    if (error) {
      toast.error(error.message);
      return;
    }

    setPrivateContact(((updatedPrivateContacts ?? [])[0] as PrivateContact | undefined) ?? null);
    toast.success("Business details updated");
    setShowEditDialog(false);
    void reload();
  };

  const TypeIcon = biz.type === "wholesaler" ? Building2 : Store;
  const ownerContact = {
    fullName: privateContact?.owner_full_name ?? "-",
    phone: privateContact?.owner_phone ? formatGhanaPhone(privateContact.owner_phone) : "-",
    email: privateContact?.owner_email ?? "-",
  };
  const superintendentContact =
    biz.type !== "pharmacy"
      ? null
      : biz.owner_is_superintendent
        ? ownerContact
        : {
            fullName:
              firstNonEmpty(privateContact?.superintendent_full_name, biz.superintendent_name) ??
              "-",
            phone: privateContact?.superintendent_phone
              ? formatGhanaPhone(privateContact.superintendent_phone)
              : "-",
            email: privateContact?.superintendent_email ?? "-",
          };
  const summaryLocation = [biz.city, biz.region].filter(Boolean).join(", ") || "-";
  const summaryLicense = biz.license_number ?? "-";
  const summaryPhone = biz.phone ? formatGhanaPhone(biz.phone) : "-";
  const summaryEmail = biz.public_email ?? "-";
  const currentSuperintendentName = editForm.owner_is_superintendent
    ? editForm.owner_full_name
    : editForm.superintendent_name;
  const currentSuperintendentPhone = editForm.owner_is_superintendent
    ? editForm.owner_phone
    : editForm.superintendent_phone;
  const currentSuperintendentEmail = editForm.owner_is_superintendent
    ? editForm.owner_email
    : editForm.superintendent_email;

  return (
    <Card className="p-5">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="flex items-start gap-3">
          <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-muted">
            <TypeIcon className="h-5 w-5 text-primary" />
          </div>

          <div>
            <div className="flex flex-wrap items-center gap-2">
              <h3 className="font-display text-lg font-bold">{biz.name}</h3>
              <Badge variant="secondary" className="text-[10px] uppercase">
                {biz.type}
              </Badge>
            </div>

            <div className="text-sm text-muted-foreground">
              {summaryLocation} | License {summaryLicense} | {summaryPhone}
            </div>
            <div className="mt-1 text-xs text-muted-foreground">Public email: {summaryEmail}</div>
            <div className="mt-1 text-xs text-muted-foreground">
              Owner: {ownerContact.fullName} | {ownerContact.phone}
            </div>
            {biz.type === "pharmacy" && superintendentContact && (
              <div className="mt-1 text-xs text-muted-foreground">
                Superintendent: {superintendentContact.fullName}
                {biz.owner_is_superintendent ? " (same as owner)" : ""}
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

        <div className="flex flex-wrap gap-2">
          <Button variant="ghost" size="sm" onClick={() => setShowViewDialog(true)}>
            <Eye className="h-4 w-4" /> View
          </Button>

          <Button
            variant="ghost"
            size="sm"
            onClick={() => {
              setEditForm(buildEditForm(biz, privateContact));
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
        <div className="mb-2 text-xs uppercase tracking-wider text-muted-foreground">Documents</div>
        {docs.length === 0 ? (
          <div className="text-sm italic text-muted-foreground">No documents uploaded yet.</div>
        ) : (
          <div className="flex flex-wrap gap-2">
            {docs.map((doc) => (
              <Button
                key={doc.id}
                variant="outline"
                size="sm"
                onClick={() => openDoc(doc.storage_path)}
              >
                <FileText className="h-4 w-4" /> {doc.doc_type}
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
            <Label htmlFor={`reject-reason-${biz.id}`}>Reason</Label>
            <Input
              id={`reject-reason-${biz.id}`}
              value={rejectReason}
              onChange={(event) => setRejectReason(event.target.value)}
              placeholder="Documents are not legible..."
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
        <DialogContent className="sm:max-w-4xl">
          <DialogHeader>
            <DialogTitle>Business Details</DialogTitle>
          </DialogHeader>

          <div className="max-h-[75vh] space-y-6 overflow-y-auto pr-1">
            <section className="space-y-4">
              <div>
                <h4 className="font-semibold">Public business profile</h4>
                <p className="text-sm text-muted-foreground">
                  These are the business details that can safely surface externally.
                </p>
              </div>

              <div className="grid gap-4 sm:grid-cols-2">
                <DetailField label="Business name" value={biz.name} />
                <div>
                  <div className="mb-1 text-xs font-medium uppercase tracking-wider text-muted-foreground">
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
                <DetailField label="Business type" value={biz.type} />
                <DetailField label="License number" value={biz.license_number ?? "-"} />
                <DetailField label="Public phone" value={summaryPhone} />
                <DetailField label="Public email" value={summaryEmail} />
                <DetailField label="City" value={biz.city ?? "-"} />
                <DetailField label="Region" value={biz.region ?? "-"} />
                <DetailField label="GPS address" value={biz.address ?? "-"} />
                <DetailField label="Working hours" value={biz.working_hours ?? "-"} />
                <DetailField label="Submitted" value={timeAgo(biz.created_at)} />
              </div>

              <div>
                <div className="mb-1 text-xs font-medium uppercase tracking-wider text-muted-foreground">
                  Exact location description
                </div>
                <div className="whitespace-pre-line rounded-lg border border-border bg-muted/20 p-3 text-sm">
                  {biz.location_description ?? "-"}
                </div>
              </div>
            </section>

            <section className="space-y-4">
              <div>
                <h4 className="font-semibold">Owner details</h4>
                <p className="text-sm text-muted-foreground">
                  Private contact details for verification and support.
                </p>
              </div>

              <div className="grid gap-4 sm:grid-cols-2">
                <DetailField label="Owner full name" value={ownerContact.fullName} />
                <DetailField label="Owner phone" value={ownerContact.phone} />
                <DetailField label="Owner email" value={ownerContact.email} />
              </div>
            </section>

            {biz.type === "pharmacy" && superintendentContact && (
              <section className="space-y-4">
                <div>
                  <h4 className="font-semibold">Superintendent pharmacist</h4>
                  <p className="text-sm text-muted-foreground">
                    Stored privately for compliance and admin review.
                  </p>
                </div>

                <div className="rounded-lg border border-border bg-muted/20 p-3 text-sm text-muted-foreground">
                  {biz.owner_is_superintendent
                    ? "The owner is also marked as the superintendent pharmacist."
                    : "A separate superintendent pharmacist is recorded for this pharmacy."}
                </div>

                <div className="grid gap-4 sm:grid-cols-2">
                  <DetailField label="Full name" value={superintendentContact.fullName} />
                  <DetailField label="Phone" value={superintendentContact.phone} />
                  <DetailField label="Email" value={superintendentContact.email} />
                </div>
              </section>
            )}

            {biz.rejection_reason && (
              <section>
                <div className="mb-1 text-xs font-medium uppercase tracking-wider text-destructive">
                  Rejection reason
                </div>
                <div className="rounded-lg border border-destructive/20 bg-destructive/5 p-3 text-sm text-destructive">
                  {biz.rejection_reason}
                </div>
              </section>
            )}

            <section>
              <div className="mb-2 text-xs font-medium uppercase tracking-wider text-muted-foreground">
                Documents
              </div>
              {docs.length === 0 ? (
                <div className="text-sm italic text-muted-foreground">No documents uploaded.</div>
              ) : (
                <div className="flex flex-wrap gap-2">
                  {docs.map((doc) => (
                    <Button
                      key={doc.id}
                      variant="outline"
                      size="sm"
                      onClick={() => openDoc(doc.storage_path)}
                    >
                      <FileText className="h-4 w-4" /> {doc.doc_type}
                    </Button>
                  ))}
                </div>
              )}
            </section>
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setShowViewDialog(false)}>
              Close
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={showEditDialog} onOpenChange={setShowEditDialog}>
        <DialogContent className="sm:max-w-4xl">
          <DialogHeader>
            <DialogTitle>Edit Business Details</DialogTitle>
          </DialogHeader>

          <div className="max-h-[75vh] space-y-6 overflow-y-auto pr-1">
            <section className="space-y-4">
              <div>
                <h4 className="font-semibold">Public business profile</h4>
                <p className="text-sm text-muted-foreground">
                  These details are safe to expose to buyers and marketplace listings.
                </p>
              </div>

              <div className="grid gap-4 sm:grid-cols-2">
                <div className="space-y-2 sm:col-span-2">
                  <Label htmlFor={`edit-name-${biz.id}`}>Business Name *</Label>
                  <Input
                    id={`edit-name-${biz.id}`}
                    value={editForm.name}
                    onChange={(event) =>
                      setEditForm((current) => ({ ...current, name: event.target.value }))
                    }
                    placeholder="Business name"
                  />
                </div>

                <div className="space-y-2">
                  <Label htmlFor={`edit-license-${biz.id}`}>License Number</Label>
                  <Input
                    id={`edit-license-${biz.id}`}
                    value={editForm.license_number}
                    onChange={(event) =>
                      setEditForm((current) => ({
                        ...current,
                        license_number: event.target.value,
                      }))
                    }
                    placeholder="PHA-2024-001"
                  />
                </div>

                <div className="space-y-2">
                  <Label htmlFor={`edit-public-phone-${biz.id}`}>Public Phone</Label>
                  <Input
                    id={`edit-public-phone-${biz.id}`}
                    value={editForm.phone}
                    onChange={(event) =>
                      setEditForm((current) => ({ ...current, phone: event.target.value }))
                    }
                    placeholder="+233 24 000 0000"
                  />
                </div>

                <div className="space-y-2">
                  <Label htmlFor={`edit-public-email-${biz.id}`}>Public Email</Label>
                  <Input
                    id={`edit-public-email-${biz.id}`}
                    type="email"
                    value={editForm.public_email}
                    onChange={(event) =>
                      setEditForm((current) => ({
                        ...current,
                        public_email: event.target.value,
                      }))
                    }
                    placeholder="hello@business.com"
                  />
                </div>

                <div className="space-y-2">
                  <Label htmlFor={`edit-working-hours-${biz.id}`}>Working Hours</Label>
                  <Input
                    id={`edit-working-hours-${biz.id}`}
                    value={editForm.working_hours}
                    onChange={(event) =>
                      setEditForm((current) => ({
                        ...current,
                        working_hours: event.target.value,
                      }))
                    }
                    placeholder="Mon-Sat 8am-9pm"
                  />
                </div>

                <div className="space-y-2">
                  <Label htmlFor={`edit-city-${biz.id}`}>City</Label>
                  <Input
                    id={`edit-city-${biz.id}`}
                    value={editForm.city}
                    onChange={(event) =>
                      setEditForm((current) => ({ ...current, city: event.target.value }))
                    }
                    placeholder="Accra"
                  />
                </div>

                <div className="space-y-2">
                  <Label htmlFor={`edit-region-${biz.id}`}>Region</Label>
                  <Input
                    id={`edit-region-${biz.id}`}
                    value={editForm.region}
                    onChange={(event) =>
                      setEditForm((current) => ({ ...current, region: event.target.value }))
                    }
                    placeholder="Greater Accra"
                  />
                </div>

                <div className="space-y-2 sm:col-span-2">
                  <Label htmlFor={`edit-address-${biz.id}`}>GPS Address</Label>
                  <Input
                    id={`edit-address-${biz.id}`}
                    value={editForm.address}
                    onChange={(event) =>
                      setEditForm((current) => ({ ...current, address: event.target.value }))
                    }
                    placeholder="GA-123-4567"
                  />
                </div>

                <div className="space-y-2 sm:col-span-2">
                  <Label htmlFor={`edit-location-description-${biz.id}`}>
                    Exact Location Description
                  </Label>
                  <Textarea
                    id={`edit-location-description-${biz.id}`}
                    value={editForm.location_description}
                    onChange={(event) =>
                      setEditForm((current) => ({
                        ...current,
                        location_description: event.target.value,
                      }))
                    }
                    placeholder="Near the clinic, opposite the station."
                    rows={4}
                  />
                </div>
              </div>
            </section>

            <section className="space-y-4">
              <div>
                <h4 className="font-semibold">Owner details</h4>
                <p className="text-sm text-muted-foreground">
                  Private fields used for onboarding, verification, and follow-up.
                </p>
              </div>

              <div className="grid gap-4 sm:grid-cols-2">
                <div className="space-y-2 sm:col-span-2">
                  <Label htmlFor={`edit-owner-full-name-${biz.id}`}>Owner Full Name *</Label>
                  <Input
                    id={`edit-owner-full-name-${biz.id}`}
                    value={editForm.owner_full_name}
                    onChange={(event) =>
                      setEditForm((current) => ({
                        ...current,
                        owner_full_name: event.target.value,
                      }))
                    }
                    placeholder="Owner's full name"
                  />
                </div>

                <div className="space-y-2">
                  <Label htmlFor={`edit-owner-phone-${biz.id}`}>Owner Phone Number *</Label>
                  <Input
                    id={`edit-owner-phone-${biz.id}`}
                    value={editForm.owner_phone}
                    onChange={(event) =>
                      setEditForm((current) => ({
                        ...current,
                        owner_phone: event.target.value,
                      }))
                    }
                    placeholder="+233 24 000 0000"
                  />
                </div>

                <div className="space-y-2">
                  <Label htmlFor={`edit-owner-email-${biz.id}`}>Owner Email Address *</Label>
                  <Input
                    id={`edit-owner-email-${biz.id}`}
                    type="email"
                    value={editForm.owner_email}
                    onChange={(event) =>
                      setEditForm((current) => ({
                        ...current,
                        owner_email: event.target.value,
                      }))
                    }
                    placeholder="owner@business.com"
                  />
                </div>
              </div>
            </section>

            {biz.type === "pharmacy" && (
              <section className="space-y-4">
                <div>
                  <h4 className="font-semibold">Superintendent pharmacist</h4>
                  <p className="text-sm text-muted-foreground">
                    Required for pharmacies and kept private from the marketplace.
                  </p>
                </div>

                <div className="rounded-xl border border-border bg-muted/30 p-4">
                  <div className="flex items-start gap-3">
                    <Checkbox
                      id={`edit-owner-is-superintendent-${biz.id}`}
                      checked={editForm.owner_is_superintendent}
                      onCheckedChange={(checked) =>
                        setEditForm((current) => ({
                          ...current,
                          owner_is_superintendent: checked === true,
                        }))
                      }
                    />
                    <div className="space-y-1">
                      <Label
                        htmlFor={`edit-owner-is-superintendent-${biz.id}`}
                        className="cursor-pointer text-sm font-medium"
                      >
                        Owner is also the Superintendent Pharmacist
                      </Label>
                      <p className="text-xs text-muted-foreground">
                        When enabled, the superintendent contact mirrors the owner details.
                      </p>
                    </div>
                  </div>
                </div>

                <div className="grid gap-4 sm:grid-cols-2">
                  <div className="space-y-2 sm:col-span-2">
                    <Label htmlFor={`edit-superintendent-name-${biz.id}`}>
                      Superintendent Full Name
                    </Label>
                    <Input
                      id={`edit-superintendent-name-${biz.id}`}
                      value={currentSuperintendentName}
                      onChange={(event) =>
                        setEditForm((current) => ({
                          ...current,
                          superintendent_name: event.target.value,
                        }))
                      }
                      placeholder="Superintendent pharmacist full name"
                      disabled={editForm.owner_is_superintendent}
                    />
                  </div>

                  <div className="space-y-2">
                    <Label htmlFor={`edit-superintendent-phone-${biz.id}`}>
                      Superintendent Phone Number
                    </Label>
                    <Input
                      id={`edit-superintendent-phone-${biz.id}`}
                      value={currentSuperintendentPhone}
                      onChange={(event) =>
                        setEditForm((current) => ({
                          ...current,
                          superintendent_phone: event.target.value,
                        }))
                      }
                      placeholder="+233 24 000 0000"
                      disabled={editForm.owner_is_superintendent}
                    />
                  </div>

                  <div className="space-y-2">
                    <Label htmlFor={`edit-superintendent-email-${biz.id}`}>
                      Superintendent Email Address
                    </Label>
                    <Input
                      id={`edit-superintendent-email-${biz.id}`}
                      type="email"
                      value={currentSuperintendentEmail}
                      onChange={(event) =>
                        setEditForm((current) => ({
                          ...current,
                          superintendent_email: event.target.value,
                        }))
                      }
                      placeholder="superintendent@business.com"
                      disabled={editForm.owner_is_superintendent}
                    />
                  </div>
                </div>
              </section>
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
