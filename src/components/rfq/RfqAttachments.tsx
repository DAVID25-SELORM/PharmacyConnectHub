import { useCallback, useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { rfqCall, rfqDb } from "@/lib/enterprise-rfq";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
export function RfqAttachments({
  rfqId,
  businessId,
  canUpload,
}: {
  rfqId: string;
  businessId: string;
  canUpload: boolean;
}) {
  const [rows, setRows] = useState<{ id: string; filename: string; storage_path: string }[]>([]);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const load = useCallback(async () => {
    const { data, error } = await rfqDb
      .from("rfq_attachments")
      .select("id,filename,storage_path")
      .eq("rfq_id", rfqId)
      .order("created_at", { ascending: false })
      .limit(100);
    if (error) setError(error.message);
    else setRows(data ?? []);
  }, [rfqId]);
  useEffect(() => {
    void load();
  }, [load]);
  const upload = async (file: File) => {
    setBusy(true);
    setError("");
    try {
      if (
        file.size > 10 * 1024 * 1024 ||
        !["application/pdf", "image/jpeg", "image/png"].includes(file.type)
      )
        throw new Error("Use PDF, JPEG or PNG up to 10 MB.");
      const path = `${rfqId}/${businessId}/${crypto.randomUUID()}`;
      const { error } = await supabase.storage
        .from("rfq-evidence")
        .upload(path, file, { contentType: file.type, upsert: false });
      if (error) throw error;
      await rfqCall("register_rfq_attachment", {
        p_rfq_id: rfqId,
        p_wholesaler_id: businessId,
        p_path: path,
        p_filename: file.name,
      });
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  return (
    <details className="rounded border p-3">
      <summary>Private supplier documents</summary>
      <p className="text-xs">
        Only the supplier and requesting pharmacy can read each document. Uploaded files cannot be
        overwritten.
      </p>
      {canUpload && (
        <Input
          disabled={busy}
          type="file"
          accept="application/pdf,image/png,image/jpeg"
          onChange={(e) => {
            if (e.target.files?.[0]) void upload(e.target.files[0]);
            e.target.value = "";
          }}
        />
      )}
      {rows.map((row) => (
        <Button
          key={row.id}
          variant="link"
          onClick={async () => {
            const { data, error } = await supabase.storage
              .from("rfq-evidence")
              .createSignedUrl(row.storage_path, 60);
            if (error) setError(error.message);
            else window.open(data.signedUrl, "_blank", "noopener,noreferrer");
          }}
        >
          {row.filename}
        </Button>
      ))}
      {error && <p role="alert">{error}</p>}
    </details>
  );
}
