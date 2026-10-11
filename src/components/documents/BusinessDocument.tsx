import { useEffect, useState, type CSSProperties, type ReactNode } from "react";
import { resolveDocumentBranding, type DocumentBusiness } from "@/lib/document-branding";
import { supabase } from "@/integrations/supabase/client";

function useStoredBranding(business: DocumentBusiness | null | undefined) {
  const [loaded, setLoaded] = useState<{ id: string; branding: DocumentBusiness["branding"] } | null>(null);
  useEffect(() => {
    setLoaded(null);
    if (!business?.id || business.branding) return;
    let live = true;
    void (supabase as any)
      .from("business_document_branding")
      .select("display_name,logo_path,accent_color,show_license,show_secondary_contact,footer_note,signatory_name,signatory_title,payment_instructions")
      .eq("business_id", business.id)
      .maybeSingle()
      .then(({ data }: { data: Record<string, unknown> | null }) => {
        if (!live || !data) return;
        const logoPath = typeof data.logo_path === "string" ? data.logo_path : null;
        setLoaded({ id: business.id!, branding: { ...data, logo_url: logoPath ? supabase.storage.from("business-document-logos").getPublicUrl(logoPath).data.publicUrl : null } });
      }, () => { if (live) setLoaded(null); });
    return () => { live = false; };
  }, [business?.id, business?.branding]);
  const branding = business?.branding ?? (loaded?.id === business?.id ? loaded?.branding : null);
  return branding?.logo_path && !branding.logo_url ? { ...branding, logo_url: supabase.storage.from("business-document-logos").getPublicUrl(branding.logo_path).data.publicUrl } : branding;
}

export function BusinessIdentityHeader({ business }: { business: DocumentBusiness | null | undefined }) {
  const [failedLogo, setFailedLogo] = useState<string | null>(null);
  const stored = useStoredBranding(business);
  const identity = resolveDocumentBranding(business ? { ...business, branding: stored } : business);
  return (
    <div className="flex min-w-0 items-start gap-3">
      {identity.logo_url && failedLogo !== identity.logo_url ? (
        <img src={identity.logo_url} onError={() => setFailedLogo(identity.logo_url ?? null)} alt="" className="h-14 w-14 shrink-0 object-contain" />
      ) : (
        <div className="flex h-14 w-14 shrink-0 items-center justify-center rounded border text-lg font-bold" style={{ borderColor: identity.accentColor, color: identity.accentColor }}>
          {identity.name.slice(0, 1).toUpperCase()}
        </div>
      )}
      <div className="min-w-0">
        <div className="break-words text-xl font-bold leading-tight">{identity.name}</div>
        {identity.display_name?.trim() && identity.display_name.trim() !== identity.name && (
          <div className="break-words text-sm">{identity.display_name}</div>
        )}
        {identity.contactLines.map((line) => <div className="text-xs text-neutral-700" key={line}>{line}</div>)}
      </div>
    </div>
  );
}

export function BusinessDocument({ issuer, type, reference, status, metadata, children, footerNote }: {
  issuer: DocumentBusiness | null | undefined;
  type: string;
  reference: string;
  status?: string | null;
  metadata: Array<{ label: string; value: ReactNode | null | undefined }>;
  children: ReactNode;
  footerNote?: string | null;
}) {
  const branding = resolveDocumentBranding(issuer);
  return (
    <article className="print-document business-document hidden print:block" style={{ "--document-accent": branding.accentColor } as CSSProperties}>
      <header className="business-document__header">
        <BusinessIdentityHeader business={issuer} />
        <div className="shrink-0 text-right">
          <h1 className="text-xl font-bold uppercase tracking-wide">{type}</h1>
          <div className="mt-1 text-sm font-semibold">{reference}</div>
          {status && <div className="mt-1 text-xs font-semibold uppercase">{status}</div>}
        </div>
      </header>
      <dl className="business-document__metadata">
        {metadata.filter((entry) => entry.value !== null && entry.value !== undefined && entry.value !== "").map((entry) => (
          <div key={entry.label}><dt>{entry.label}</dt><dd>{entry.value}</dd></div>
        ))}
      </dl>
      {children}
      <footer className="business-document__footer">
        {footerNote && <div>{footerNote}</div>}
        <div>Powered by DrugXOne · Developed by Daventra Technologies</div>
      </footer>
    </article>
  );
}
