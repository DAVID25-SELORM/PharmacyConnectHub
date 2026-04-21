import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { Upload, FileCheck2, Pill, Loader2, Clock } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { toast } from "sonner";
import { useSession } from "@/hooks/use-session";
import { supabase } from "@/integrations/supabase/client";
import { DashboardHeader } from "@/components/DashboardShell";

export const Route = createFileRoute("/onboarding")({
  head: () => ({
    meta: [
      { title: "Verify your business — PharmaHub GH" },
      { name: "description", content: "Upload your Pharmacy Council and FDA documents." },
    ],
  }),
  component: OnboardingPage,
});

type DocRow = { id: string; doc_type: string; storage_path: string; uploaded_at: string };
type AccessState =
  | "checking"
  | "none"
  | "pending-business"
  | "pending-platform"
  | "active-platform";

function workspaceRoute(type: "pharmacy" | "wholesaler") {
  return type === "wholesaler" ? "/wholesaler" : "/pharmacy";
}

function OnboardingPage() {
  const navigate = useNavigate();
  const { loading, user, business, businesses, roles, refresh } = useSession();
  const [docs, setDocs] = useState<DocRow[]>([]);
  const [uploading, setUploading] = useState<string | null>(null);
  const [accessState, setAccessState] = useState<AccessState>("checking");

  useEffect(() => {
    if (!loading && !user) navigate({ to: "/login" });
  }, [loading, user, navigate]);

  useEffect(() => {
    if (loading || !user) {
      return;
    }

    if (business || businesses.length > 0) {
      setAccessState("none");
      return;
    }

    if (roles.includes("admin")) {
      setAccessState("active-platform");
      return;
    }

    let cancelled = false;
    setAccessState("checking");

    void Promise.all([
      supabase
        .from("business_staff")
        .select("id")
        .eq("user_id", user.id)
        .eq("status", "pending")
        .limit(1)
        .maybeSingle(),
      supabase
        .from("platform_staff")
        .select("status")
        .eq("user_id", user.id)
        .in("status", ["pending", "active"])
        .limit(1)
        .maybeSingle(),
    ])
      .then(([businessInvite, platformAccess]) => {
        if (cancelled) return;

        if (platformAccess.data?.status === "active") {
          setAccessState("active-platform");
          return;
        }

        if (businessInvite.data) {
          setAccessState("pending-business");
          return;
        }

        if (platformAccess.data?.status === "pending") {
          setAccessState("pending-platform");
          return;
        }

        setAccessState("none");
      })
      .catch(() => {
        if (!cancelled) {
          setAccessState("none");
        }
      });

    return () => {
      cancelled = true;
    };
  }, [loading, user, business, businesses.length, roles]);

  useEffect(() => {
    if (!business) return;
    void supabase
      .from("license_documents")
      .select("*")
      .eq("business_id", business.id)
      .order("uploaded_at", { ascending: false })
      .then(({ data }) => setDocs((data as DocRow[]) ?? []));
  }, [business]);

  useEffect(() => {
    if (loading || !business || business.verification_status !== "approved") {
      return;
    }

    navigate({ to: workspaceRoute(business.type) });
  }, [loading, business, navigate]);

  useEffect(() => {
    if (loading || business || businesses.length > 0 || accessState !== "active-platform") {
      return;
    }

    navigate({ to: "/admin" });
  }, [loading, business, businesses.length, accessState, navigate]);

  const onUpload = async (docType: string, file: File) => {
    if (!user || !business) return;
    setUploading(docType);
    const path = `${user.id}/${business.id}/${docType}-${Date.now()}-${file.name}`;
    const { error: upErr } = await supabase.storage.from("licenses").upload(path, file, {
      upsert: false,
      contentType: file.type,
    });
    if (upErr) {
      setUploading(null);
      toast.error(upErr.message);
      return;
    }
    const { data: row, error: dbErr } = await supabase
      .from("license_documents")
      .insert({ business_id: business.id, doc_type: docType, storage_path: path })
      .select()
      .single();
    setUploading(null);
    if (dbErr) {
      toast.error(dbErr.message);
      return;
    }
    setDocs((d) => [row as DocRow, ...d]);
    toast.success("Document uploaded");
  };

  if (loading || !user) {
    return (
      <div className="flex min-h-screen items-center justify-center text-muted-foreground">
        <Pill className="h-5 w-5 animate-pulse" /> <span className="ml-2">Loading…</span>
      </div>
    );
  }

  if (!business && businesses.length > 1) {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center gap-4 p-8 text-center">
        <h2 className="text-xl font-semibold">Choose a workspace first</h2>
        <p className="max-w-md text-muted-foreground">
          This account can access more than one business. Select the workspace you want before
          opening onboarding.
        </p>
        <Button onClick={() => navigate({ to: "/dashboard" })}>Choose workspace</Button>
      </div>
    );
  }

  if (!business) {
    if (accessState === "checking" || accessState === "active-platform") {
      return (
        <div className="flex min-h-screen items-center justify-center text-muted-foreground">
          <Pill className="h-5 w-5 animate-pulse" />
          <span className="ml-2">Opening your interface…</span>
        </div>
      );
    }

    if (accessState === "pending-business" || accessState === "pending-platform") {
      return (
        <div className="flex min-h-screen flex-col items-center justify-center gap-4 p-8 text-center">
          <Clock className="h-10 w-10 text-amber-500" />
          <h2 className="text-xl font-semibold">Invitation pending</h2>
          <p className="max-w-sm text-muted-foreground">
            {accessState === "pending-platform"
              ? "You've been invited to join the PharmaHub Admin interface. The owner needs to activate your access before you can continue."
              : "You've been invited to join a business on PharmaHub. The business owner needs to activate your access before you can continue."}
          </p>
          <Button variant="outline" onClick={() => refresh()}>
            Check again
          </Button>
        </div>
      );
    }
    return (
      <div className="flex min-h-screen flex-col items-center justify-center gap-4 p-8 text-center">
        <p>We couldn't find a business profile for your account.</p>
        <Button onClick={() => navigate({ to: "/signup" })}>Complete signup</Button>
      </div>
    );
  }

  if (business.verification_status === "approved") {
    return (
      <div className="flex min-h-screen items-center justify-center text-muted-foreground">
        <Pill className="h-5 w-5 animate-pulse" />
        <span className="ml-2">Opening your dashboard…</span>
      </div>
    );
  }

  const docTypes =
    business.type === "pharmacy"
      ? [
          { key: "pharmacy_council", label: "Pharmacy Council License" },
          { key: "business_registration", label: "Business Registration" },
        ]
      : [
          { key: "wholesale_license", label: "Wholesale Pharmacy License" },
          { key: "fda_certificate", label: "FDA Certificate" },
          { key: "business_registration", label: "Business Registration" },
        ];

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="Verification" />
      <main className="mx-auto max-w-3xl px-4 sm:px-6 lg:px-8 py-8">
        <h1 className="font-display text-3xl font-bold">Verify your business</h1>
        <p className="mt-2 text-muted-foreground">
          We review every business to keep counterfeit drugs off the platform. Verification usually
          takes 24–48 hours.
        </p>

        <Card className="mt-6 p-6">
          <div className="mb-4">
            <div className="text-xs uppercase tracking-wider text-muted-foreground">Status</div>
            <div className="mt-1 text-lg font-semibold capitalize">
              {business.verification_status}
            </div>
            {business.verification_status === "rejected" && business.rejection_reason && (
              <div className="mt-3 rounded-lg border border-destructive/20 bg-destructive/5 p-3 text-sm text-destructive">
                Rejection reason: {business.rejection_reason}
              </div>
            )}
          </div>
          <div className="space-y-3 text-sm">
            <Field label="Business name" value={business.name} />
            <Field label="License #" value={business.license_number ?? "—"} />
            <Field label="Location" value={`${business.city ?? "—"}, ${business.region ?? "—"}`} />
          </div>
        </Card>

        <h2 className="font-display mt-8 text-xl font-bold">Required documents</h2>
        <div className="mt-4 space-y-3">
          {docTypes.map((dt) => {
            const existing = docs.find((d) => d.doc_type === dt.key);
            return (
              <Card key={dt.key} className="p-4">
                <div className="flex items-center justify-between gap-4">
                  <div className="min-w-0">
                    <div className="font-medium">{dt.label}</div>
                    <div className="mt-0.5 text-xs text-muted-foreground">
                      {existing
                        ? `Uploaded ${new Date(existing.uploaded_at).toLocaleDateString()}`
                        : "PDF, JPG or PNG (max 10MB)"}
                    </div>
                  </div>
                  <div className="flex items-center gap-2">
                    {existing && <FileCheck2 className="h-5 w-5 text-success" />}
                    <Label
                      htmlFor={`file-${dt.key}`}
                      className="inline-flex cursor-pointer items-center justify-center gap-2 rounded-md border border-input bg-background px-3 py-2 text-sm font-medium hover:bg-accent"
                    >
                      {uploading === dt.key ? (
                        <Loader2 className="h-4 w-4 animate-spin" />
                      ) : (
                        <Upload className="h-4 w-4" />
                      )}
                      {existing ? "Replace" : "Upload"}
                    </Label>
                    <Input
                      id={`file-${dt.key}`}
                      type="file"
                      accept=".pdf,image/*"
                      className="hidden"
                      onChange={(e) => {
                        const f = e.target.files?.[0];
                        if (f) void onUpload(dt.key, f);
                        e.target.value = "";
                      }}
                    />
                  </div>
                </div>
              </Card>
            );
          })}
        </div>

        <div className="mt-8 flex items-center justify-between">
          <Button variant="ghost" onClick={() => refresh()}>
            Refresh status
          </Button>
          <Button
            variant="hero"
            onClick={() => navigate({ to: workspaceRoute(business.type) })}
            disabled={docs.length === 0}
          >
            Continue to dashboard
          </Button>
        </div>
      </main>
    </div>
  );
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between gap-4 border-b border-border pb-2 last:border-0 last:pb-0">
      <span className="text-muted-foreground">{label}</span>
      <span className="font-medium text-right">{value}</span>
    </div>
  );
}
