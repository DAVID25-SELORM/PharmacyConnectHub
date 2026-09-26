import { createFileRoute, useNavigate, useRouter } from "@tanstack/react-router";
import { useCallback, useEffect, useState } from "react";
import { CheckCheck, ChevronLeft, ChevronRight } from "lucide-react";
import { DashboardHeader } from "@/components/DashboardShell";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { useSession } from "@/hooks/use-session";
import { supabase } from "@/integrations/supabase/client";
import {
  NOTIFICATION_FILTERS,
  announceNotificationsChanged,
  openInternalLink,
  safeInternalLink,
  timeAgoShort,
  typesForGroup,
  type NotificationRow,
} from "@/lib/notifications";

export const Route = createFileRoute("/notifications")({
  head: () => ({ meta: [{ title: "Notifications - Drugxone" }] }),
  component: NotificationsPage,
});

const PAGE_SIZE = 25;

function NotificationsPage() {
  const navigate = useNavigate();
  const router = useRouter();
  const { loading: sessionLoading, user, roles } = useSession();
  const [filter, setFilter] = useState("");
  const [page, setPage] = useState(0);
  const [rows, setRows] = useState<NotificationRow[]>([]);
  const [total, setTotal] = useState(0);
  const [unread, setUnread] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);

  useEffect(() => {
    if (!sessionLoading && !user) navigate({ to: "/login" });
  }, [sessionLoading, user, navigate]);

  const load = useCallback(async () => {
    if (!user) return;
    setLoading(true);
    setError(false);

    let query = supabase
      .from("notifications")
      .select("id,type,title,body,read,link,created_at", { count: "exact" })
      .eq("user_id", user.id)
      .order("created_at", { ascending: false })
      .order("id", { ascending: false })
      .range(page * PAGE_SIZE, page * PAGE_SIZE + PAGE_SIZE - 1);
    if (filter === "unread") query = query.eq("read", false);
    const types = typesForGroup(filter);
    if (types) query = query.in("type", types);

    const [{ data, count, error: loadError }, { count: unreadCount }] = await Promise.all([
      query,
      supabase
        .from("notifications")
        .select("id", { count: "exact", head: true })
        .eq("user_id", user.id)
        .eq("read", false),
    ]);
    if (loadError) setError(true);
    else {
      setRows((data as unknown as NotificationRow[]) ?? []);
      setTotal(count ?? 0);
    }
    setUnread(unreadCount ?? 0);
    setLoading(false);
  }, [user, filter, page]);

  useEffect(() => {
    void load();
  }, [load]);

  const markRead = async (note: NotificationRow) => {
    if (note.read) return;
    setRows((current) => current.map((row) => (row.id === note.id ? { ...row, read: true } : row)));
    setUnread((count) => Math.max(0, count - 1));
    await supabase.from("notifications").update({ read: true }).eq("id", note.id);
    announceNotificationsChanged();
  };

  const open = async (note: NotificationRow) => {
    await markRead(note);
    openInternalLink(router, note.link);
  };

  const markAllRead = async () => {
    if (!user) return;
    await supabase
      .from("notifications")
      .update({ read: true })
      .eq("user_id", user.id)
      .eq("read", false);
    announceNotificationsChanged();
    void load();
  };

  const pageCount = Math.max(1, Math.ceil(total / PAGE_SIZE));

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="Notifications" showNav={true} isAdmin={roles.includes("admin")} />
      <main className="mx-auto max-w-3xl px-4 py-8 sm:px-6">
        <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
          <div>
            <h1 className="font-display text-2xl font-bold">Notifications</h1>
            <p className="text-sm text-muted-foreground">
              {unread > 0 ? `${unread} unread` : "You're all caught up."}
            </p>
          </div>
          <Button
            variant="outline"
            size="sm"
            onClick={() => void markAllRead()}
            disabled={unread === 0}
          >
            <CheckCheck className="mr-1 h-4 w-4" aria-hidden="true" />
            Mark all read
          </Button>
        </div>

        <div
          className="mb-4 flex gap-2 overflow-x-auto pb-1"
          role="group"
          aria-label="Notification filter"
        >
          {NOTIFICATION_FILTERS.map((item) => (
            <Button
              key={item.value}
              size="sm"
              variant={filter === item.value ? "secondary" : "ghost"}
              onClick={() => {
                setFilter(item.value);
                setPage(0);
              }}
            >
              {item.label}
            </Button>
          ))}
        </div>

        {loading ? (
          <div className="space-y-2" role="status" aria-label="Loading notifications">
            <Skeleton className="h-16 w-full" />
            <Skeleton className="h-16 w-full" />
            <Skeleton className="h-16 w-full" />
          </div>
        ) : error ? (
          <div
            role="alert"
            className="rounded-xl border border-dashed border-border p-8 text-center"
          >
            <p className="text-sm font-medium">We couldn&apos;t load your notifications.</p>
            <Button className="mt-3" variant="outline" size="sm" onClick={() => void load()}>
              Try again
            </Button>
          </div>
        ) : rows.length === 0 ? (
          <Card className="p-10 text-center text-muted-foreground">
            <p className="font-medium text-foreground">
              {filter ? "Nothing here." : "No notifications yet"}
            </p>
            <p className="mt-1 text-sm">
              {filter
                ? "Try a different filter."
                : "Order, payment, return and delivery updates will appear here."}
            </p>
          </Card>
        ) : (
          <Card className="divide-y divide-border overflow-hidden">
            {rows.map((note) => {
              const clickable = Boolean(safeInternalLink(note.link));
              return (
                <button
                  type="button"
                  key={note.id}
                  onClick={() => void (clickable ? open(note) : markRead(note))}
                  className={`block w-full px-4 py-3 text-left hover:bg-muted/50 ${note.read ? "opacity-70" : "bg-primary/5"}`}
                >
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <div className="flex items-center gap-2 text-sm font-medium">
                        {!note.read && (
                          <span
                            className="h-2 w-2 shrink-0 rounded-full bg-primary"
                            aria-label="Unread"
                          />
                        )}
                        {note.title}
                      </div>
                      <div className="mt-0.5 text-sm text-muted-foreground">{note.body}</div>
                    </div>
                    <span className="shrink-0 text-xs text-muted-foreground">
                      {timeAgoShort(note.created_at)}
                    </span>
                  </div>
                </button>
              );
            })}
          </Card>
        )}

        {!loading && !error && total > PAGE_SIZE && (
          <div className="mt-4 flex items-center justify-between text-sm text-muted-foreground">
            <span>
              Page {page + 1} of {pageCount} · {total} notifications
            </span>
            <div className="flex gap-2">
              <Button
                size="sm"
                variant="outline"
                disabled={page === 0}
                onClick={() => setPage((value) => value - 1)}
              >
                <ChevronLeft className="h-4 w-4" aria-hidden="true" />
                Previous
              </Button>
              <Button
                size="sm"
                variant="outline"
                disabled={page + 1 >= pageCount}
                onClick={() => setPage((value) => value + 1)}
              >
                Next
                <ChevronRight className="h-4 w-4" aria-hidden="true" />
              </Button>
            </div>
          </div>
        )}
      </main>
    </div>
  );
}
