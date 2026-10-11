import { useEffect, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { supabase } from "@/integrations/supabase/client";

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
  display_name: null, logo_path: null, accent_color: "#0f766e", show_license: true,
  show_secondary_contact: true, footer_note: null, signatory_name: null, signatory_title: null,
  payment_instructions: null,
};

/** Manager-only settings. The server RPC remains the authorization boundary. */
export function DocumentBrandingSettings({ businessId, businessName }: { businessId: string; businessName: string }) {
  // Remount on organization changes so drafts/uploads can never carry into a new tenant.
  return <BrandingEditor key={businessId} businessId={businessId} businessName={businessName} />;
}

function BrandingEditor({ businessId, businessName }: { businessId: string; businessName: string }) {
  const [value, setValue] = useState<BrandingRow>(blank);
  const [logoUrl, setLogoUrl] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  const load = async () => {
    setLoading(true);
    const { data, error } = await (supabase as any).from("business_document_branding").select("*").eq("business_id", businessId).maybeSingle();
    if (error) {
      setLoadError("Document branding could not be loaded. Check that its migration has been applied, then reopen this panel.");
      setLoading(false);
      return;
    }
    const next = (data as BrandingRow | null) ?? blank;
    setValue(next);
    setLogoUrl(next.logo_path ? supabase.storage.from("business-document-logos").getPublicUrl(next.logo_path).data.publicUrl : null);
    setLoading(false);
  };
  useEffect(() => { void load(); }, [businessId]);
  const patch = (key: keyof BrandingRow, next: BrandingRow[keyof BrandingRow]) => setValue((current) => ({ ...current, [key]: next }));
  const uploadLogo = async (file: File) => {
    if (!['image/png', 'image/jpeg', 'image/webp'].includes(file.type) || file.size > 2 * 1024 * 1024) {
      toast.error("Use a PNG, JPEG, or WebP logo up to 2 MB.");
      return;
    }
    setSaving(true);
    try {
      const bitmap = await createImageBitmap(file);
      const valid = bitmap.width >= 32 && bitmap.height >= 32 && bitmap.width <= 4096 && bitmap.height <= 4096;
      bitmap.close();
      if (!valid) throw new Error("Use a logo between 32 and 4096 pixels on each side.");
      const extension = file.type === "image/png" ? "png" : file.type === "image/webp" ? "webp" : "jpg";
      const path = `${businessId}/${crypto.randomUUID()}.${extension}`;
      const { error } = await supabase.storage.from("business-document-logos").upload(path, file, { contentType: file.type, upsert: false });
      if (error) throw error;
      patch("logo_path", path);
      setLogoUrl(supabase.storage.from("business-document-logos").getPublicUrl(path).data.publicUrl);
    } catch (error) { toast.error(error instanceof Error ? error.message : "Logo upload failed."); }
    finally { setSaving(false); }
  };
  const save = async () => {
    setSaving(true);
    try {
      const { error } = await (supabase as any).rpc("save_business_document_branding", {
        p_business_id: businessId, p_display_name: value.display_name, p_logo_path: value.logo_path,
        p_accent_color: value.accent_color, p_show_license: value.show_license,
        p_show_secondary_contact: value.show_secondary_contact, p_footer_note: value.footer_note,
        p_signatory_name: value.signatory_name, p_signatory_title: value.signatory_title,
        p_payment_instructions: value.payment_instructions,
      });
      if (error) throw error;
      toast.success("Document branding saved.");
    } catch (error) { toast.error(error instanceof Error ? error.message : "Could not save document branding."); }
    finally { setSaving(false); }
  };
  if (loading) return <p className="text-sm text-muted-foreground">Loading document branding…</p>;
  if (loadError) return <p role="alert">{loadError}</p>;
  return <section className="space-y-4 border-t pt-6">
    <div><h2 className="text-lg font-semibold">Business document branding</h2><p className="text-sm text-muted-foreground">Commercial documents retain {businessName} as the verified issuer. These controls change presentation only.</p></div>
    <div className="grid gap-3 sm:grid-cols-2">
      <label><Label>Document display name</Label><Input value={value.display_name ?? ""} maxLength={160} onChange={(e) => patch("display_name", e.target.value)} placeholder={businessName} /></label>
      <label><Label>Accent colour</Label><Input type="color" value={value.accent_color} onChange={(e) => patch("accent_color", e.target.value)} /></label>
      <label><Label>Business logo</Label><Input type="file" accept="image/png,image/jpeg,image/webp" disabled={saving} onChange={(e) => { const file = e.target.files?.[0]; if (file) void uploadLogo(file); e.target.value = ""; }} /></label>
      {logoUrl && <img src={logoUrl} alt="Current business logo" className="h-16 max-w-48 object-contain object-left" />}
      <label><Label>Authorized signatory</Label><Input value={value.signatory_name ?? ""} maxLength={160} onChange={(e) => patch("signatory_name", e.target.value)} /></label>
      <label><Label>Signatory title</Label><Input value={value.signatory_title ?? ""} maxLength={160} onChange={(e) => patch("signatory_title", e.target.value)} /></label>
      <label className="sm:col-span-2"><Label>Footer note</Label><Input value={value.footer_note ?? ""} maxLength={500} onChange={(e) => patch("footer_note", e.target.value)} /></label>
      <label className="sm:col-span-2"><Label>Payment instructions</Label><Input value={value.payment_instructions ?? ""} maxLength={1000} onChange={(e) => patch("payment_instructions", e.target.value)} /></label>
    </div>
    <div className="flex flex-wrap gap-5 text-sm"><label className="flex items-center gap-2"><input type="checkbox" checked={value.show_license} onChange={(e) => patch("show_license", e.target.checked)} />Show licence</label><label className="flex items-center gap-2"><input type="checkbox" checked={value.show_secondary_contact} onChange={(e) => patch("show_secondary_contact", e.target.checked)} />Show public email</label></div>
    <Button disabled={saving} onClick={() => void save()}>{saving ? "Saving…" : "Save document branding"}</Button>
  </section>;
}
