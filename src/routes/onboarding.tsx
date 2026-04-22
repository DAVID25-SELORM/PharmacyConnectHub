import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { Clock, FileCheck2, Loader2, Pill, Upload } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Progress } from "@/components/ui/progress";
import { toast } from "sonner";
import { DashboardHeader } from "@/components/DashboardShell";
import { useSession } from "@/hooks/use-session";
import { supabase } from "@/integrations/supabase/client";
import { compressImageForUpload, formatFileSize, MAX_UPLOAD_BYTES } from "@/lib/file-upload";

export const Route = createFileRoute("/onboarding")({
  head: () => ({
    meta: [
      { title: "Verify your business - PharmaHub GH" },
      { name: "description", content: "Upload your Pharmacy Council and FDA documents." },
    ],
  }),
  component: OnboardingPage,
});

type DocRow = { id: string; doc_type: string; storage_path: string; uploaded_at: string };
type UploadTone = "uploading" | "success" | "error";
type UploadFeedback = {
  fileName?: string;
  message?: string;
  tone?: UploadTone;
};
type AccessState =
  | "checking"
  | "none"
  | "pending-business"
  | "pending-platform"
  | "active-platform";

function workspaceRoute(type: "pharmacy" | "wholesaler") {
  return type === "wholesaler" ? "/wholesaler" : "/pharmacy";
}

function buildUploadPath(userId: string, businessId: string, docType: string, fileName: string) {
  const safeFileName = fileName.replace(/[^a-zA-Z0-9._-]/g, "-");
  return `${userId}/${businessId}/${docType}-${Date.now()}-${safeFileName}`;
}

function OnboardingPage() {
  const navigate = useNavigate();
  const { loading, user, business, businesses, roles, refresh } = useSession();
  const [docs, setDocs] = useState<DocRow[]>([]);
  const [uploading, setUploading] = useState<string | null>(null);
  const [uploadFeedback, setUploadFeedback] = useState<Record<string, UploadFeedback>>({});
  const [accessState, setAccessState] = useState<AccessState>("checking");
  const [refreshing, setRefreshing] = useState(false);

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

  const updateUploadFeedback = (docType: string, next: UploadFeedback) => {
    setUploadFeedback((current) => ({
      ...current,
      [docType]: { ...current[docType], ...next },
    }));
  };

  const onRefreshStatus = async () => {
    setRefreshing(true);
    try {
      await refresh();
      toast.success("Verification status refreshed");
    } catch {
      toast.error("We could not refresh your status right now");
    } finally {
      setRefreshing(false);
    }
  };

  const onUpload = async (docType: string, file: File) => {
    if (!user || !business) return;

    setUploading(docType);
    updateUploadFeedback(docType, {
      fileName: file.name,
      message: "Preparing upload...",
      tone: "uploading",
    });

    try {
      let uploadFile = file;

      if (file.type.startsWith("image/") && file.size > MAX_UPLOAD_BYTES) {
        updateUploadFeedback(docType, {
          fileName: file.name,
          message: "Large image detected. Compressing before upload...",
          tone: "uploading",
        });
        uploadFile = await compressImageForUpload(file);
      } else if (file.size > MAX_UPLOAD_BYTES) {
        throw new Error("This file is larger than 10MB. Please choose a smaller PDF or image.");
      }

      updateUploadFeedback(docType, {
        fileName: uploadFile.name,
        message: "Uploading...",
        tone: "uploading",
      });

      const path = buildUploadPath(user.id, business.id, docType, uploadFile.name);
      const { error: upErr } = await supabase.storage.from("licenses").upload(path, uploadFile, {
        upsert: false,
        contentType: uploadFile.type || file.type,
      });

      if (upErr) {
        throw upErr;
      }

      const { data: row, error: dbErr } = await supabase
        .from("license_documents")
        .insert({ business_id: business.id, doc_type: docType, storage_path: path })
        .select()
        .single();

      if (dbErr) {
        throw dbErr;
      }

      setDocs((current) => [row as DocRow, ...current]);
      updateUploadFeedback(docType, {
        fileName: uploadFile.name,
        message: "Upload successful",
        tone: "success",
      });
      toast.success("Document uploaded");
    } catch (error) {
      const message = error instanceof Error ? error.message : "Upload failed. Try again.";
      updateUploadFeedback(docType, {
        fileName: file.name,
        message,
        tone: "error",
      });
      toast.error(message);
    } finally {
      setUploading(null);
    }
  };

  if (loading || !user) {
    return (
      <div className="flex min-h-screen items-center justify-center text-muted-foreground">
        <Pill className="h-5 w-5 animate-pulse" /> <span className="ml-2">Loading...</span>
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
          <span className="ml-2">Opening your interface...</span>
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
          <Button variant="outline" onClick={() => void onRefreshStatus()} disabled={refreshing}>
            {refreshing ? "Checking..." : "Check again"}
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
        <span className="ml-2">Opening your dashboard...</span>
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

  const uploadedCount = docTypes.filter((docType) =>
    docs.some((doc) => doc.doc_type === docType.key),
  ).length;
  const progressValue =
    docTypes.length === 0 ? 0 : Math.round((uploadedCount / docTypes.length) * 100);

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="Verification" />
      <main className="mx-auto max-w-3xl px-4 py-8 sm:px-6 lg:px-8">
        <h1 className="font-display text-3xl font-bold">Verify your business</h1>
        <p className="mt-2 text-muted-foreground">
          We review every business to keep counterfeit drugs off the platform. Verification usually
          takes 24-48 hours.
        </p>

        <Card className="mt-6 border-primary/15 bg-primary/5 p-6">
          <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
            <div>
              <div className="text-sm font-semibold text-primary">Verification progress</div>
              <p className="mt-1 text-sm text-muted-foreground">
                {uploadedCount} of {docTypes.length} required document
                {docTypes.length === 1 ? "" : "s"} uploaded.
              </p>
            </div>
            <div className="text-left md:text-right">
              <div className="font-display text-3xl font-bold">{progressValue}%</div>
              <div className="text-xs text-muted-foreground">Ready for review</div>
            </div>
          </div>
          <Progress value={progressValue} className="mt-4 h-2.5" />
        </Card>

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
            <Field label="License #" value={business.license_number ?? "-"} />
            <Field label="Public phone" value={business.phone ?? "-"} />
            <Field label="Public email" value={business.public_email ?? "-"} />
            {business.type === "pharmacy" && (
              <Field
                label="Superintendent"
                value={
                  business.owner_is_superintendent
                    ? "Owner is also superintendent pharmacist"
                    : (business.superintendent_name ?? "-")
                }
              />
            )}
            <Field label="Location" value={`${business.city ?? "-"}, ${business.region ?? "-"}`} />
            <Field label="GPS address" value={business.address ?? "-"} />
            <Field label="Working hours" value={business.working_hours ?? "-"} />
            {business.location_description && (
              <Field label="Location note" value={business.location_description} />
            )}
          </div>
        </Card>

        <Card className="mt-6 p-6">
          <h2 className="font-display text-xl font-bold">What happens next</h2>
          <div className="mt-4 grid gap-3 md:grid-cols-3">
            <div className="rounded-xl border border-border/70 bg-muted/20 p-4">
              <div className="text-sm font-semibold">1. Upload your documents</div>
              <p className="mt-1 text-sm text-muted-foreground">
                Add the required files below. Images are compressed automatically if they are too
                large.
              </p>
            </div>
            <div className="rounded-xl border border-border/70 bg-muted/20 p-4">
              <div className="text-sm font-semibold">2. Our team reviews them</div>
              <p className="mt-1 text-sm text-muted-foreground">
                We check that your licenses match the business details on your account.
              </p>
            </div>
            <div className="rounded-xl border border-border/70 bg-muted/20 p-4">
              <div className="text-sm font-semibold">3. You get notified</div>
              <p className="mt-1 text-sm text-muted-foreground">
                Once approved, you can continue straight into your dashboard and start using the
                platform.
              </p>
            </div>
          </div>
        </Card>

        <h2 className="font-display mt-8 text-xl font-bold">Required documents</h2>
        <div className="mt-4 space-y-3">
          {docTypes.map((docType) => {
            const existing = docs.find((doc) => doc.doc_type === docType.key);
            const feedback = uploadFeedback[docType.key];
            const statusClassName =
              feedback?.tone === "error"
                ? "text-destructive"
                : feedback?.tone === "success"
                  ? "text-success"
                  : "text-muted-foreground";

            return (
              <Card key={docType.key} className="p-4">
                <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
                  <div className="min-w-0">
                    <div className="font-medium">{docType.label}</div>
                    <div className="mt-0.5 text-xs text-muted-foreground">
                      {existing
                        ? `Uploaded ${new Date(existing.uploaded_at).toLocaleDateString()}`
                        : `PDF, JPG or PNG (max ${formatFileSize(MAX_UPLOAD_BYTES)})`}
                    </div>
                    {feedback?.fileName && (
                      <div className="mt-2 text-sm text-foreground">{feedback.fileName}</div>
                    )}
                    {feedback?.message && (
                      <div className={`mt-1 text-xs ${statusClassName}`}>{feedback.message}</div>
                    )}
                  </div>

                  <div className="flex items-center gap-2">
                    {existing && <FileCheck2 className="h-5 w-5 text-success" />}
                    <Label
                      htmlFor={`file-${docType.key}`}
                      className={`inline-flex cursor-pointer items-center justify-center gap-2 rounded-md border border-input bg-background px-3 py-2 text-sm font-medium hover:bg-accent ${
                        uploading === docType.key ? "pointer-events-none opacity-70" : ""
                      }`}
                    >
                      {uploading === docType.key ? (
                        <Loader2 className="h-4 w-4 animate-spin" />
                      ) : (
                        <Upload className="h-4 w-4" />
                      )}
                      {existing ? "Replace" : "Upload"}
                    </Label>
                    <Input
                      id={`file-${docType.key}`}
                      type="file"
                      accept=".pdf,image/*"
                      className="hidden"
                      onChange={(event) => {
                        const file = event.target.files?.[0];
                        if (file) {
                          void onUpload(docType.key, file);
                        }
                        event.target.value = "";
                      }}
                    />
                  </div>
                </div>
              </Card>
            );
          })}
        </div>

        <div className="mt-8 flex items-center justify-between">
          <Button variant="ghost" onClick={() => void onRefreshStatus()} disabled={refreshing}>
            {refreshing ? "Checking..." : "Refresh status"}
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
