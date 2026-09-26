export type QueueRow = {
  business_id: string;
  business_name: string;
  business_type: "pharmacy" | "wholesaler";
  city: string | null;
  region: string | null;
  license_number: string | null;
  status: "pending" | "rejected";
  is_resubmitted: boolean;
  submitted_at: string;
  first_submitted_at: string;
  waiting_days: number | null;
  docs_uploaded: number;
  docs_required: number;
  rejection_reason: string | null;
  summary_pending: number;
  summary_new: number;
  summary_resubmitted: number;
  summary_rejected: number;
  summary_longest_wait_days: number;
  total_count: number;
};

export const QUEUE_STATUS_FILTERS: Array<{ value: string; label: string }> = [
  { value: "pending", label: "All pending" },
  { value: "new", label: "New" },
  { value: "resubmitted", label: "Resubmitted" },
  { value: "rejected", label: "Correction requested" },
  { value: "all", label: "Everything open" },
];

export const QUEUE_SORTS: Array<{ value: string; label: string }> = [
  { value: "oldest", label: "Oldest first" },
  { value: "newest", label: "Newest first" },
  { value: "name", label: "Name A-Z" },
];

export function waitingLabel(days: number | null) {
  if (days === null || days === undefined) return "—";
  if (days <= 0) return "Today";
  return days === 1 ? "1 day" : `${days} days`;
}

/** Waits of a week or more stand out so the oldest reviews get done first. */
export function waitingTone(days: number | null): "normal" | "warning" | "urgent" {
  if (days === null || days === undefined) return "normal";
  if (days >= 7) return "urgent";
  if (days >= 3) return "warning";
  return "normal";
}

export function documentsComplete(row: Pick<QueueRow, "docs_uploaded" | "docs_required">) {
  return row.docs_uploaded >= row.docs_required;
}
