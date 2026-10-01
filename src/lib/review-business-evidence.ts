import { supabase } from "@/integrations/supabase/client";

export type EvidenceDocument = {
  id: string;
  doc_type: string;
  storage_path: string;
  uploaded_at: string;
  version_id: string;
};

/** Submit the versions displayed to the reviewer, never a freshly fetched snapshot. */
export async function reviewBusinessEvidence(
  businessId: string,
  status: "approved" | "rejected",
  documents: EvidenceDocument[] | null,
  reason: string | null = null,
) {
  if (!documents || documents.some((document) => !document.version_id)) {
    return { error: { message: "Reload the documents before making a review decision." } };
  }

  return supabase.rpc("review_business_evidence", {
    _business_id: businessId,
    _status: status,
    _versions: documents.map((document) => document.version_id),
    _reason: reason,
  });
}
