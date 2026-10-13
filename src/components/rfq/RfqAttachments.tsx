import { useCallback, useEffect, useState, type ReactNode } from "react";
import { FileText, Upload } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { rfqCall, rfqDb } from "@/lib/enterprise-rfq";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

type Row = { id: string; filename: string; storage_path: string };

/** Downloads for the request, and the private documents suppliers attach to it. */
export function RfqAttachments({
  rfqId,
  businessId,
  canUpload,
  exports,
}: {
  rfqId: string;
  businessId: string;
  canUpload: boolean;
  /** Buttons that download the request itself (PDF, Excel). */
  exports?: ReactNode;
}) {
  const [rows, setRows] = useState<Row[]>([]);
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
    <Card>
      <CardHeader className="gap-3 sm:flex-row sm:items-start sm:justify-between sm:space-y-0">
        <div className="space-y-1.5">
          <CardTitle className="text-lg">Documents</CardTitle>
          <CardDescription>
            Only the supplier and the requesting pharmacy can read each supplier document. Uploaded
            files cannot be overwritten.
          </CardDescription>
        </div>
        {exports && <div className="flex flex-wrap gap-2">{exports}</div>}
      </CardHeader>
      <CardContent className="space-y-3">
        {rows.length === 0 ? (
          <p className="text-sm text-muted-foreground">No supplier documents attached.</p>
        ) : (
          <ul className="divide-y rounded-lg border">
            {rows.map((row) => (
              <li key={row.id} className="flex items-center gap-3 px-3 py-2 text-sm">
                <FileText className="h-4 w-4 shrink-0 text-muted-foreground" />
                <span className="min-w-0 flex-1 truncate">{row.filename}</span>
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  onClick={async () => {
                    const { data, error } = await supabase.storage
                      .from("rfq-evidence")
                      .createSignedUrl(row.storage_path, 60);
                    if (error) setError(error.message);
                    else window.open(data.signedUrl, "_blank", "noopener,noreferrer");
                  }}
                >
                  Open
                </Button>
              </li>
            ))}
          </ul>
        )}
        {canUpload && (
          <label className="inline-flex cursor-pointer items-center gap-2 rounded-md border border-dashed px-3 py-2 text-sm hover:bg-muted/40">
            <Upload className="h-4 w-4" />
            {busy ? "Uploading…" : "Attach a document (PDF, JPEG or PNG, up to 10 MB)"}
            <input
              disabled={busy}
              type="file"
              className="sr-only"
              accept="application/pdf,image/png,image/jpeg"
              onChange={(e) => {
                if (e.target.files?.[0]) void upload(e.target.files[0]);
                e.target.value = "";
              }}
            />
          </label>
        )}
        {error && (
          <p role="alert" className="text-sm text-destructive">
            {error}
          </p>
        )}
      </CardContent>
    </Card>
  );
}
