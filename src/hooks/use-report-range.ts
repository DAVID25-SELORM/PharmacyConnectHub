import { useState } from "react";
import { DEFAULT_RANGE, type ReportRangeState } from "@/lib/reports";

/**
 * Draft vs. applied date range for a Reports page. The draft updates as the person edits the
 * form; `applied` (what actually drives queries) only changes on Apply/Reset, so typing a custom
 * date doesn't fire a request per keystroke.
 */
export function useReportRange(initial: ReportRangeState = DEFAULT_RANGE) {
  const [draft, setDraft] = useState<ReportRangeState>(initial);
  const [applied, setApplied] = useState<ReportRangeState>(initial);

  return {
    draft,
    setDraft,
    applied,
    apply: () => setApplied(draft),
    reset: () => {
      setDraft(initial);
      setApplied(initial);
    },
  };
}
