import { beforeEach, describe, expect, it, vi } from "vitest";
import { supabase } from "@/integrations/supabase/client";
import { reviewBusinessEvidence, type EvidenceDocument } from "./review-business-evidence";

vi.mock("@/integrations/supabase/client", () => ({ supabase: { rpc: vi.fn() } }));

const document: EvidenceDocument = {
  id: "document-id",
  version_id: "displayed-version",
  doc_type: "pharmacy_council",
  storage_path: "business/license.pdf",
  uploaded_at: "2026-09-30T00:00:00Z",
};

describe("reviewBusinessEvidence", () => {
  beforeEach(() => {
    vi.mocked(supabase.rpc).mockReset();
    vi.mocked(supabase.rpc).mockResolvedValue({ data: null, error: null } as never);
  });

  it("approves through the review RPC using the displayed evidence versions", async () => {
    await reviewBusinessEvidence("business-id", "approved", [document]);
    expect(supabase.rpc).toHaveBeenCalledWith("review_business_evidence", {
      _business_id: "business-id",
      _status: "approved",
      _versions: ["displayed-version"],
      _reason: null,
    });
  });

  it("records correction requests against the same evidence snapshot", async () => {
    await reviewBusinessEvidence("business-id", "rejected", [document], "Licence is unreadable");
    expect(supabase.rpc).toHaveBeenCalledWith("review_business_evidence", {
      _business_id: "business-id",
      _status: "rejected",
      _versions: ["displayed-version"],
      _reason: "Licence is unreadable",
    });
  });

  it("blocks unloaded documents and documents without version identifiers", async () => {
    expect((await reviewBusinessEvidence("id", "approved", null)).error).toBeTruthy();
    expect(
      (await reviewBusinessEvidence("id", "approved", [{ ...document, version_id: "" }])).error,
    ).toBeTruthy();
    expect(supabase.rpc).not.toHaveBeenCalled();
  });

  it("distinguishes a loaded empty snapshot from a failed document load", async () => {
    await reviewBusinessEvidence("id", "approved", []);
    expect(supabase.rpc).toHaveBeenCalledWith(
      "review_business_evidence",
      expect.objectContaining({ _versions: [] }),
    );
  });

  it("returns stale evidence errors without retrying or bypassing the review", async () => {
    const error = { message: "Evidence changed. Reload and review the current documents." };
    vi.mocked(supabase.rpc).mockResolvedValue({ data: null, error } as never);
    expect((await reviewBusinessEvidence("id", "approved", [document])).error).toEqual(error);
    expect(supabase.rpc).toHaveBeenCalledTimes(1);
  });
});
