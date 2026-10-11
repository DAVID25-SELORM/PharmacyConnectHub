import { supabase } from "@/integrations/supabase/client";
import { rfqCall } from "./enterprise-rfq";
import type { DocumentBusiness } from "./document-branding";

export async function loadDocumentIdentity(businessId: string): Promise<DocumentBusiness> {
  const identity = await rfqCall<DocumentBusiness>("get_business_document_identity", {
    p_business_id: businessId,
  });
  const path = identity.branding?.logo_path;
  return {
    ...identity,
    branding: {
      ...identity.branding,
      logo_url: path
        ? supabase.storage.from("business-document-logos").getPublicUrl(path).data.publicUrl
        : null,
    },
  };
}
