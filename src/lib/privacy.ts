import { supabase } from "@/integrations/supabase/client";

/**
 * Version of the Privacy Notice and Terms people accept. Change it when either page changes in
 * a way people should see again; everyone is then asked to review the new version.
 */
export const PRIVACY_VERSION = "2026-11-22";

export type DataRequestKind = "deletion" | "correction" | "other";
export type DataRequestStatus = "open" | "in_progress" | "completed" | "declined";

export interface MyDataRequest {
  id: string;
  kind: DataRequestKind;
  status: DataRequestStatus;
  reason: string | null;
  resolution_note: string | null;
  created_at: string;
  due_at: string;
}

export interface AdminDataRequest extends MyDataRequest {
  user_id: string | null;
  email: string | null;
  handled_at: string | null;
  owned_businesses: string[];
  is_admin: boolean;
  already_anonymised: boolean;
}

// The functions are newer than the generated Supabase types.
const rpc = (name: string, args: Record<string, unknown> = {}) =>
  (
    supabase as unknown as {
      rpc: (
        n: string,
        a: Record<string, unknown>,
      ) => PromiseLike<{ data: unknown; error: { message: string } | null }>;
    }
  ).rpc(name, args);

const table = (name: string) =>
  (
    supabase as unknown as {
      from: (n: string) => {
        select: (c: string) => {
          order: (
            col: string,
            o: { ascending: boolean },
          ) => PromiseLike<{ data: unknown; error: { message: string } | null }>;
          eq: (
            col: string,
            v: string,
          ) => PromiseLike<{ data: unknown; error: { message: string } | null }>;
        };
      };
    }
  ).from(name);

/** Extra sign-up metadata recording which version was accepted on the form. */
export function consentMetadata(version: string = PRIVACY_VERSION): Record<string, string> {
  return { consent_version: version };
}

/** True when the signed-in person's sign-up already carries consent to this exact version. */
export function signedUpWithConsent(
  metadata: Record<string, unknown> | undefined,
  version: string = PRIVACY_VERSION,
): boolean {
  return metadata?.consent_version === version;
}

/** True when the rows (the person's own consent records) cover both documents at this version. */
export function acceptedBoth(
  rows: { document: string; version: string }[],
  version: string = PRIVACY_VERSION,
): boolean {
  const documents = new Set(
    rows.filter((row) => row.version === version).map((row) => row.document),
  );
  return documents.has("privacy_notice") && documents.has("terms");
}

export async function hasAcceptedCurrentVersion(
  userId: string,
  version: string = PRIVACY_VERSION,
): Promise<boolean> {
  const { data, error } = await table("consent_records")
    .select("document,version")
    .eq("user_id", userId);
  // A read failure must not nag or block anyone.
  if (error || !Array.isArray(data)) return true;
  return acceptedBoth(data as { document: string; version: string }[], version);
}

export async function recordConsent(
  source: "signup" | "app",
  version: string = PRIVACY_VERSION,
): Promise<string | null> {
  const { error } = await rpc("record_consent", { p_version: version, p_source: source });
  return error ? error.message : null;
}

export async function exportMyData(): Promise<
  { ok: true; json: string } | { ok: false; message: string }
> {
  const { data, error } = await rpc("export_my_data");
  if (error || !data)
    return { ok: false, message: error?.message ?? "Could not prepare your data." };
  return { ok: true, json: JSON.stringify(data, null, 2) };
}

/** Starts a browser download of a text file. */
export function downloadTextFile(filename: string, text: string, mime = "application/json") {
  const url = URL.createObjectURL(new Blob([text], { type: mime }));
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function exportFilename(date: Date = new Date()): string {
  return `drugxone-my-data-${date.toISOString().slice(0, 10)}.json`;
}

export async function requestDataAction(
  kind: DataRequestKind,
  reason: string,
): Promise<string | null> {
  const { error } = await rpc("request_data_action", {
    p_kind: kind,
    p_reason: reason.trim() || null,
  });
  return error ? error.message : null;
}

export async function listMyDataRequests(): Promise<MyDataRequest[]> {
  const { data, error } = await table("data_requests")
    .select("id,kind,status,reason,resolution_note,created_at,due_at")
    .order("created_at", { ascending: false });
  if (error || !Array.isArray(data)) return [];
  return data as MyDataRequest[];
}

export async function adminListDataRequests(
  status?: DataRequestStatus,
): Promise<AdminDataRequest[]> {
  const { data, error } = await rpc("admin_list_data_requests", { p_status: status ?? null });
  if (error || !Array.isArray(data)) return [];
  return data as AdminDataRequest[];
}

export async function adminResolveDataRequest(
  id: string,
  status: "in_progress" | "completed" | "declined",
  note: string,
): Promise<string | null> {
  const { error } = await rpc("admin_resolve_data_request", {
    p_id: id,
    p_status: status,
    p_note: note.trim() || null,
  });
  return error ? error.message : null;
}

export async function adminAnonymiseUser(
  userId: string,
  requestId: string | null,
  note: string,
): Promise<string | null> {
  const { error } = await rpc("admin_anonymise_user", {
    p_user_id: userId,
    p_request_id: requestId,
    p_note: note.trim() || null,
  });
  return error ? error.message : null;
}

export const REQUEST_KIND_LABEL: Record<DataRequestKind, string> = {
  deletion: "Delete my data",
  correction: "Correct my data",
  other: "Other privacy request",
};

export const REQUEST_STATUS_LABEL: Record<DataRequestStatus, string> = {
  open: "Received",
  in_progress: "Being handled",
  completed: "Completed",
  declined: "Declined",
};

/** Days left before the reply is due; negative when late. */
export function daysUntilDue(dueAt: string, now: Date = new Date()): number {
  return Math.ceil((new Date(dueAt).getTime() - now.getTime()) / 86_400_000);
}
