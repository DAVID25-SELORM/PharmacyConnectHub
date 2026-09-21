import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { ActivityTable } from "./ActivityTable";
import type { ActivityRow } from "@/lib/activity-log";

const row = (n: number, overrides: Partial<ActivityRow> = {}): ActivityRow => ({
  id: `00000000-0000-0000-0000-${String(n).padStart(12, "0")}`,
  created_at: new Date(Date.UTC(2026, 8, 21, 10, 0, 0) - n * 60_000).toISOString(),
  activity: "Business approved",
  organization: `Org ${n}`,
  performed_by_email: n % 2 ? "admin@example.com" : null,
  record_type: "business",
  record_id: null,
  record_label: `LIC-${n}`,
  details: { status: "approved", access_token: "SECRET-TOKEN" },
  ...overrides,
});

const base = {
  rows: [] as ActivityRow[],
  loading: false,
  error: false,
  onRetry: vi.fn(),
  onOpen: vi.fn(),
  emptyState: <p>No activity yet</p>,
  filteredEmptyState: <p>No activity matches your filters</p>,
};

const render = (props: Partial<Parameters<typeof ActivityTable>[0]> = {}) =>
  renderToStaticMarkup(<ActivityTable {...base} {...props} />);

describe("ActivityTable", () => {
  it("renders rows with readable event, organization and actor text", () => {
    const html = render({ rows: [row(1), row(2)] });
    expect(html).toContain("Business approved");
    expect(html).toContain("Verification"); // category label: badge text, not colour alone
    expect(html).toContain("Org 1");
    expect(html).toContain("admin@example.com");
    expect(html).toContain("System"); // events with no actor
    expect(html).toContain("View details: Business approved, Org 1");
  });

  it("never renders sensitive metadata", () => {
    const html = render({ rows: [row(1)] });
    expect(html).not.toContain("SECRET-TOKEN");
    expect(html).toContain("[redacted]");
    expect(html).not.toContain("[object Object]");
  });

  it("only renders the rows it is given (bounded DOM)", () => {
    const html = render({ rows: Array.from({ length: 15 }, (_, i) => row(i + 1)) });
    expect(html.match(/<tr[ >]/g)?.length).toBe(16); // header + 15 rows
    expect(html.match(/<li>/g)?.length).toBe(15); // mobile cards
    expect(html).not.toContain("Org 16");
  });

  it("shows the empty state when there is no activity", () => {
    expect(render()).toContain("No activity yet");
  });

  it("shows the filtered empty state when a filter is active", () => {
    const html = render({ filtered: true });
    expect(html).toContain("No activity matches your filters");
    expect(html).not.toContain("No activity yet");
  });

  it("shows a loading skeleton, not a blank area", () => {
    const html = render({ loading: true });
    expect(html).toContain('aria-label="Loading activity"');
  });

  it("shows a friendly error with a retry action and no raw errors", () => {
    const html = render({ error: true });
    expect(html).toContain("We couldn&#x27;t load recent activity.");
    expect(html).toContain("Try again");
    expect(html).toContain('role="alert"');
  });

  it("gives every table header a scope and the action column an accessible name", () => {
    const html = render({ rows: [row(1)] });
    expect(html).toContain('scope="col"');
    expect(html).toContain("Open details");
  });

  it("provides a mobile card layout with time, event, organization and actor", () => {
    const html = render({ rows: [row(1)] });
    expect(html).toContain("md:hidden"); // mobile list
    expect(html).toContain("hidden overflow-hidden rounded-xl border border-border md:block"); // desktop table
  });
});
