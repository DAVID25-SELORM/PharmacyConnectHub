import { useEffect, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { supabase } from "@/integrations/supabase/client";
import { useBlocker } from "@tanstack/react-router";
import { BusinessIdentityHeader } from "./BusinessDocument";
import { readableAccent } from "@/lib/document-branding";

type BrandingRow = {
  display_name: string | null;
  logo_path: string | null;
  accent_color: string;
  show_license: boolean;
  show_secondary_contact: boolean;
  footer_note: string | null;
  signatory_name: string | null;
  signatory_title: string | null;
  payment_instructions: string | null;
};

const blank: BrandingRow = {
  display_name: null,
  logo_path: null,
  accent_color: "#0f766e",
  show_license: true,
  show_secondary_contact: true,
  footer_note: null,
  signatory_name: null,
  signatory_title: null,
  payment_instructions: null,
};

/** Manager-only settings. The server RPC remains the authorization boundary. */
export function DocumentBrandingSettings({
  businessId,
  businessName,
}: {
  businessId: string;
  businessName: string;
}) {
  // Remount on organization changes so drafts/uploads can never carry into a new tenant.
  return <BrandingEditor key={businessId} businessId={businessId} businessName={businessName} />;
}

function BrandingEditor({
  businessId,
  businessName,
}: {
  businessId: string;
  businessName: string;
}) {
  const [value, setValue] = useState<BrandingRow>(blank);
  const [saved, setSaved] = useState<BrandingRow>(blank);
  const [previewType, setPreviewType] = useState("Invoice");
  const dirty = JSON.stringify(value) !== JSON.stringify(saved);
  useBlocker({
    shouldBlockFn: () => dirty && !window.confirm("Discard unsaved branding changes?"),
    enableBeforeUnload: dirty,
  });
  useEffect(() => {
    const protect = (event: Event) => {
      if (dirty && !window.confirm("Discard unsaved branding changes before switching business?"))
        event.preventDefault();
    };
    window.addEventListener("drugxone:before-workspace-change", protect);
    return () => window.removeEventListener("drugxone:before-workspace-change", protect);
  }, [dirty]);
  const [logoUrl, setLogoUrl] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  const load = async () => {
    setLoading(true);
    setLoadError(null);
    const { data, error } = await (supabase as any)
      .from("business_document_branding")
      .select("*")
      .eq("business_id", businessId)
      .maybeSingle();
    if (error) {
      setLoadError(
        "Document branding could not be loaded. Check that its migration has been applied, then reopen this panel.",
      );
      setLoading(false);
      return;
    }
    const next = (data as BrandingRow | null) ?? blank;
    setValue(next);
    setSaved(next);
    setLogoUrl(
      next.logo_path
        ? supabase.storage.from("business-document-logos").getPublicUrl(next.logo_path).data
            .publicUrl
        : null,
    );
    setLoading(false);
  };
  useEffect(() => {
    void load();
  }, [businessId]);
  const patch = (key: keyof BrandingRow, next: BrandingRow[keyof BrandingRow]) =>
    setValue((current) => ({ ...current, [key]: next }));
  const uploadLogo = async (file: File) => {
    if (
      !["image/png", "image/jpeg", "image/webp"].includes(file.type) ||
      file.size > 2 * 1024 * 1024
    ) {
      toast.error("Use a PNG, JPEG, or WebP logo up to 2 MB.");
      return;
    }
    setSaving(true);
    try {
      const bitmap = await createImageBitmap(file);
      const valid =
        bitmap.width >= 32 && bitmap.height >= 32 && bitmap.width <= 4096 && bitmap.height <= 4096;
      bitmap.close();
      if (!valid) throw new Error("Use a logo between 32 and 4096 pixels on each side.");
      const {
        data: { session },
      } = await supabase.auth.getSession();
      if (!session) throw new Error("Sign in again before uploading.");
      const bytes = new Uint8Array(await file.arrayBuffer());
      let binary = "";
      for (const byte of bytes) binary += String.fromCharCode(byte);
      const response = await fetch("/api/staff/branding-upload", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${session.access_token}`,
        },
        body: JSON.stringify({ businessId, image: btoa(binary) }),
      });
      const result = await response.json();
      if (!response.ok) throw new Error(result.error || "Upload failed.");
      const path = result.path as string;
      patch("logo_path", path);
      setLogoUrl(
        supabase.storage.from("business-document-logos").getPublicUrl(path).data.publicUrl,
      );
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "Logo upload failed.");
    } finally {
      setSaving(false);
    }
  };
  const save = async () => {
    setSaving(true);
    try {
      const { error } = await (supabase as any).rpc("save_document_presentation", {
        p_business_id: businessId,
        p_display_name: value.display_name,
        p_logo_path: value.logo_path,
        p_accent_color: value.accent_color,
        p_show_license: value.show_license,
        p_show_secondary_contact: value.show_secondary_contact,
        p_footer_note: value.footer_note,
      });
      if (error) throw error;
      setSaved(value);
      toast.success("Document branding saved.");
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "Could not save document branding.");
    } finally {
      setSaving(false);
    }
  };
  if (loading) return <p className="text-sm text-muted-foreground">Loading document branding…</p>;
  if (loadError)
    return (
      <div role="alert">
        <p>{loadError}</p>
        <Button onClick={() => void load()}>Retry</Button>
      </div>
    );
  return (
    <section className="space-y-4 border-t pt-6">
      <div>
        <h2 className="text-lg font-semibold">Business document branding</h2>
        <p className="text-sm text-muted-foreground">
          Commercial documents retain {businessName} as the verified issuer. These controls change
          presentation only.
        </p>
      </div>
      <fieldset disabled={saving} className="grid gap-3 sm:grid-cols-2">
        <label>
          <Label>Document display name</Label>
          <Input
            value={value.display_name ?? ""}
            maxLength={160}
            onChange={(e) => patch("display_name", e.target.value)}
            placeholder={businessName}
          />
        </label>
        <label>
          <Label>Accent colour</Label>
          <Input
            type="color"
            value={value.accent_color}
            onChange={(e) => patch("accent_color", e.target.value)}
          />
        </label>
        {readableAccent(value.accent_color) !== value.accent_color && (
          <p className="text-sm">
            This colour is too light for document text. A readable teal is used for text and table
            headers.
          </p>
        )}
        <label>
          <Label>Business logo</Label>
          <Input
            type="file"
            accept="image/png,image/jpeg,image/webp"
            disabled={saving}
            onChange={(e) => {
              const file = e.target.files?.[0];
              if (file) void uploadLogo(file);
              e.target.value = "";
            }}
          />
        </label>
        {logoUrl && (
          <img
            src={logoUrl}
            alt="Current business logo"
            className="h-16 max-w-48 object-contain object-left"
          />
        )}
        <p className="text-sm text-muted-foreground">
          PNG, JPEG or WebP, up to 2 MB; 32–4096 pixels on each side. Transparent PNG recommended.
          Uploading replaces the draft; save to apply.
        </p>
        {value.logo_path && (
          <Button
            variant="outline"
            disabled={saving}
            onClick={() => {
              patch("logo_path", null);
              setLogoUrl(null);
            }}
          >
            Remove logo
          </Button>
        )}
        <label className="sm:col-span-2">
          <Label>Footer note</Label>
          <Input
            value={value.footer_note ?? ""}
            maxLength={500}
            onChange={(e) => patch("footer_note", e.target.value)}
          />
        </label>
      </fieldset>
      <div className="flex flex-wrap gap-5 text-sm">
        <label className="flex items-center gap-2">
          <input
            type="checkbox"
            disabled={saving}
            checked={value.show_license}
            onChange={(e) => patch("show_license", e.target.checked)}
          />
          Show licence
        </label>
        <label className="flex items-center gap-2">
          <input
            type="checkbox"
            disabled={saving}
            checked={value.show_secondary_contact}
            onChange={(e) => patch("show_secondary_contact", e.target.checked)}
          />
          Show public email
        </label>
      </div>
      <section
        className="rounded-lg border bg-white p-6 text-black"
        aria-label="Sample document preview"
      >
        <label className="mb-4 block text-sm">
          Preview document
          <select
            aria-label="Preview document"
            value={previewType}
            onChange={(e) => setPreviewType(e.target.value)}
            className="ml-2 max-w-full rounded border p-2"
          >
            {["RFQ", "Quotation", "Pharmacy Order Copy", "Invoice", "Delivery Note"].map((type) => (
              <option key={type}>{type}</option>
            ))}
          </select>
        </label>
        <p className="mb-4 text-xs font-semibold">SAMPLE ONLY · CLASSIC TEMPLATE · A4</p>
        <BusinessIdentityHeader
          business={{ name: businessName, branding: { ...value, logo_url: logoUrl } }}
        />
        <h3
          className="my-4 border-b-2 pb-2 font-semibold"
          style={{ borderColor: value.accent_color }}
        >
          {previewType}
        </h3>
        <p className="text-sm">Recipient: Sample business · Reference: SAMPLE-001</p>
        <div className="my-6 overflow-x-auto">
          <table className="w-full text-left text-sm [&_th]:pr-3 [&_td]:pr-3 [&_td]:align-top">
            <thead>
              <tr>
                <th>Product</th>
                <th>Quantity</th>
                {!["RFQ", "Delivery Note"].includes(previewType) && <th>Amount</th>}
              </tr>
            </thead>
            <tbody>
              <tr>
                <td className="py-3">Sample medicine · 10 mg · tablets</td>
                <td>10</td>
                {!["RFQ", "Delivery Note"].includes(previewType) && <td>GHS 250.00</td>}
              </tr>
            </tbody>
          </table>
        </div>
        <p className="break-words text-xs">{value.footer_note}</p>
        <p className="mt-3 text-xs">Issued by {businessName} via Drugxone.</p>
      </section>
      <p className="text-sm text-muted-foreground">
        Payment destinations and authorized signatures are managed separately. Saving branding does
        not sign a document.
      </p>
      <div className="flex flex-wrap gap-3">
        <Button disabled={saving || !dirty} onClick={() => void save()}>
          {saving ? "Saving…" : "Save document branding"}
        </Button>
        <Button
          variant="outline"
          disabled={saving || !dirty}
          onClick={() => {
            setValue(saved);
            setLogoUrl(
              saved.logo_path
                ? supabase.storage.from("business-document-logos").getPublicUrl(saved.logo_path)
                    .data.publicUrl
                : null,
            );
          }}
        >
          Discard changes
        </Button>
        <Button
          variant="outline"
          disabled={saving}
          onClick={() => {
            setValue({
              ...saved,
              ...blank,
              payment_instructions: saved.payment_instructions,
              signatory_name: saved.signatory_name,
              signatory_title: saved.signatory_title,
            });
            setLogoUrl(null);
          }}
        >
          Restore defaults
        </Button>
      </div>
      {dirty && (
        <p role="status" className="text-sm">
          Unsaved changes
        </p>
      )}
    </section>
  );
}
