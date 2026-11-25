import { authDiagnostic } from "@/lib/auth-diagnostics";
import { Link, useNavigate, useRouter } from "@tanstack/react-router";
import {
  Bell,
  CheckCheck,
  Clock,
  HelpCircle,
  Home,
  Hospital,
  LayoutDashboard,
  LogOut,
  Pill,
  ShieldAlert,
  ShieldCheck,
  Warehouse,
} from "lucide-react";
import { useEffect, useRef, useState } from "react";
import logo from "@/assets/logo.jpg";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { supabase } from "@/integrations/supabase/client";
import { enableWebPush } from "@/lib/web-push";
import { toast } from "sonner";
import { useSession, type Business } from "@/hooks/use-session";
import { businessKindLabel, isHospitalOrClinic } from "@/lib/business-kind";
import { AppNavigation, useActiveNavLabel, useHasAppNavigation } from "@/components/AppNavigation";
import {
  NOTIFICATIONS_CHANGED_EVENT,
  notificationLink,
  openInternalLink,
  timeAgoShort,
  type NotificationRow,
} from "@/lib/notifications";

function NotificationBell() {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [notes, setNotes] = useState<NotificationRow[]>([]);
  const [unreadTotal, setUnreadTotal] = useState(0);
  const knownIds = useRef<Set<string>>(new Set());
  const [alertsEnabled, setAlertsEnabled] = useState(false);

  const enableAlerts = async () => {
    if (typeof Notification === "undefined") return;
    const permission = await Notification.requestPermission();
    if (permission !== "granted") return;
    setAlertsEnabled(true);
    const vapid = import.meta.env.VITE_VAPID_PUBLIC_KEY as string | undefined;
    if (!vapid) return;
    const {
      data: { session },
    } = await supabase.auth.getSession();
    if (!session) return;
    try {
      await enableWebPush(vapid, session.user.id);
    } catch {
      // Closed-tab alerts are optional; in-page alerts already work.
    }
  };

  const alertFor = (note: NotificationRow) => {
    if (typeof window === "undefined") return;
    try {
      const AudioContextCtor =
        window.AudioContext ||
        (window as typeof window & { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
      if (AudioContextCtor) {
        const ctx = new AudioContextCtor();
        const oscillator = ctx.createOscillator();
        const gain = ctx.createGain();
        oscillator.frequency.value = 880;
        gain.gain.setValueAtTime(0.18, ctx.currentTime);
        gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.7);
        oscillator.connect(gain).connect(ctx.destination);
        oscillator.start();
        oscillator.stop(ctx.currentTime + 0.7);
      }
    } catch {
      // Audio is best effort; browser notification remains available.
    }
    if (typeof Notification !== "undefined" && Notification.permission === "granted") {
      new Notification(note.title, { body: note.body, tag: note.id });
    }
  };

  const load = async () => {
    const {
      data: { session },
    } = await supabase.auth.getSession();
    if (!session) return;
    const [{ data }, { count }] = await Promise.all([
      supabase
        .from("notifications")
        .select("id,type,title,body,read,link,metadata,created_at")
        .eq("user_id", session.user.id)
        .order("created_at", { ascending: false })
        .limit(15),
      supabase
        .from("notifications")
        .select("id", { count: "exact", head: true })
        .eq("user_id", session.user.id)
        .eq("read", false),
    ]);
    const nextNotes = (data as unknown as NotificationRow[]) ?? [];
    setNotes(nextNotes);
    nextNotes
      .filter((note) => !note.read && !knownIds.current.has(note.id))
      .slice(0, 3)
      .forEach(alertFor);
    knownIds.current = new Set(nextNotes.map((note) => note.id));
    setUnreadTotal(count ?? 0);
  };

  useEffect(() => {
    void load();

    // Realtime WebSocket handshakes are blocked by some browsers and networks,
    // which left the notification bell reconnecting indefinitely. Polling keeps
    // notifications available without depending on that connection.
    const pollInterval = window.setInterval(() => void load(), 60_000);

    const onChanged = () => void load();
    window.addEventListener(NOTIFICATIONS_CHANGED_EVENT, onChanged);

    return () => {
      window.clearInterval(pollInterval);
      window.removeEventListener(NOTIFICATIONS_CHANGED_EVENT, onChanged);
    };
  }, []);

  const markAllRead = async () => {
    const {
      data: { session },
    } = await supabase.auth.getSession();
    if (!session) return;
    await supabase
      .from("notifications")
      .update({ read: true })
      .eq("user_id", session.user.id)
      .eq("read", false);
    setNotes((prev) => prev.map((n) => ({ ...n, read: true })));
    setUnreadTotal(0);
  };

  const openNote = async (note: NotificationRow) => {
    setOpen(false);
    if (!note.read) {
      setNotes((prev) => prev.map((n) => (n.id === note.id ? { ...n, read: true } : n)));
      setUnreadTotal((count) => Math.max(0, count - 1));
      await supabase.from("notifications").update({ read: true }).eq("id", note.id);
    }
    openInternalLink(router, notificationLink(note));
  };

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button
          variant="ghost"
          size="sm"
          className="relative"
          aria-label={unreadTotal > 0 ? `Notifications, ${unreadTotal} unread` : "Notifications"}
        >
          <Bell className="h-4 w-4" />
          {unreadTotal > 0 && (
            <span className="absolute -right-1 -top-1 flex h-4 min-w-4 items-center justify-center rounded-full bg-destructive px-1 text-[10px] font-bold text-destructive-foreground ring-2 ring-background">
              {unreadTotal > 9 ? "9+" : unreadTotal}
            </span>
          )}
        </Button>
      </PopoverTrigger>
      <PopoverContent align="end" className="w-80 p-0">
        <div className="flex items-center justify-between border-b border-border px-4 py-3">
          <span className="text-sm font-semibold">Notifications</span>
          {typeof Notification !== "undefined" && Notification.permission !== "granted" && (
            <button
              onClick={() => void enableAlerts()}
              className="text-xs text-primary hover:underline"
            >
              Enable sound
            </button>
          )}
          {unreadTotal > 0 && (
            <button
              onClick={markAllRead}
              className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
            >
              <CheckCheck className="h-3.5 w-3.5" />
              Mark all read
            </button>
          )}
        </div>
        <div className="max-h-96 overflow-y-auto">
          {notes.length === 0 ? (
            <div className="px-4 py-8 text-center text-sm text-muted-foreground">
              No notifications yet.
            </div>
          ) : (
            notes.map((n) => (
              <button
                type="button"
                key={n.id}
                onClick={() => void openNote(n)}
                className={`block w-full border-b border-border px-4 py-3 text-left last:border-0 hover:bg-muted/50 ${n.read ? "opacity-60" : "bg-primary/5"}`}
              >
                {!n.read && (
                  <span className="mb-1 inline-block h-1.5 w-1.5 rounded-full bg-primary" />
                )}
                <div className="text-sm font-medium">{n.title}</div>
                <div className="mt-0.5 text-xs text-muted-foreground">{n.body}</div>
                <div className="mt-1 text-[11px] text-muted-foreground">
                  {timeAgoShort(n.created_at)}
                </div>
              </button>
            ))
          )}
        </div>
        <div className="border-t border-border px-4 py-2 text-center">
          <Link
            to="/notifications"
            onClick={() => setOpen(false)}
            className="text-xs font-medium text-primary hover:underline"
          >
            View all notifications
          </Link>
        </div>
      </PopoverContent>
    </Popover>
  );
}

export function DashboardHeader({
  subtitle,
  rightSlot,
  showNav = false,
  isAdmin = false,
}: {
  subtitle: string;
  rightSlot?: React.ReactNode;
  showNav?: boolean;
  isAdmin?: boolean;
}) {
  const navigate = useNavigate();
  const { business, businesses, setActiveBusiness } = useSession();
  // The side rail, bottom bar and More sheet (AppNavigation) now carry the screens, Help, Add
  // business and Sign out. When it shows, this top bar keeps only what is about the page itself.
  const hasAppNav = useHasAppNavigation(showNav);
  const activeLabel = useActiveNavLabel(isAdmin);
  // A small, always-visible (including on phones) signal for which kind of account this is - a
  // real user was once confused after being given a wholesaler account when expecting a pharmacy
  // one. The existing `subtitle` text can't carry this on its own: it's reused for unrelated page
  // titles ("Reports", "Activity log", a business's own name, ...) on most routes, and the wordmark
  // block it lives in is hidden entirely below the sm breakpoint.
  const accountBadge = business
    ? business.type === "wholesaler"
      ? {
          label: "Wholesaler",
          Icon: Warehouse,
          className: "border-violet-200 bg-violet-100 text-violet-800",
        }
      : isHospitalOrClinic(business)
        ? {
            label: businessKindLabel(business),
            Icon: Hospital,
            className: "border-emerald-200 bg-emerald-100 text-emerald-800",
          }
        : { label: "Pharmacy", Icon: Pill, className: "border-blue-200 bg-blue-100 text-blue-800" }
    : null;
  // The switcher stays available without the full nav so a user stuck on a pending
  // workspace's onboarding page can still switch to an approved one.
  const canSwitchWorkspaces = businesses.length > 1 && business;

  const onSignOut = async () => {
    authDiagnostic("signout.intentional.DashboardShell");
    await supabase.auth.signOut({ scope: "local" });
    toast.success("Signed out");
    navigate({ to: "/" });
  };

  const onWorkspaceChange = (businessId: string) => {
    if (!business || businessId === business.id) {
      return;
    }

    if (!window.dispatchEvent(new Event("drugxone:before-workspace-change", { cancelable: true })))
      return;
    setActiveBusiness(businessId);
    navigate({ to: "/dashboard" });
  };

  return (
    <>
      <header className="sticky top-0 z-40 border-b border-border bg-background/85 backdrop-blur-xl">
        <div className="mx-auto flex min-h-16 max-w-7xl flex-wrap items-center justify-between gap-2 py-2 px-4 sm:px-6 lg:px-8">
          <div className="flex min-w-0 items-center gap-3 lg:gap-6">
            <div className="flex min-w-0 items-center gap-2">
              <Button
                variant="ghost"
                size="icon"
                onClick={() => navigate({ to: "/dashboard" })}
                aria-label="Go to dashboard"
                className={hasAppNav ? "md:hidden" : undefined}
              >
                <Home className="h-4 w-4" />
              </Button>
              <Link
                to="/"
                className={`flex min-w-0 items-center gap-2 ${hasAppNav ? "md:hidden" : ""}`}
              >
                <img src={logo} alt="Drugxone" className="h-9 w-9 rounded-xl object-contain" />
                <div className="hidden min-w-0 sm:block">
                  <div className="truncate font-display text-base font-bold leading-none">
                    Drug<span className="text-primary">xone</span>
                  </div>
                  <div className="truncate text-[11px] text-muted-foreground">{subtitle}</div>
                </div>
              </Link>
              {hasAppNav && (
                <div className="hidden min-w-0 md:block" data-testid="header-crumb">
                  <div className="truncate text-[11px] text-muted-foreground">
                    {business?.name ?? "Platform admin"}
                  </div>
                  <div className="truncate font-display text-base font-bold leading-tight">
                    {activeLabel ?? subtitle}
                  </div>
                </div>
              )}
              {accountBadge && (
                <Badge
                  variant="outline"
                  className={`shrink-0 gap-1 whitespace-nowrap ${accountBadge.className}`}
                >
                  <accountBadge.Icon className="h-3 w-3" aria-hidden="true" />
                  {accountBadge.label}
                </Badge>
              )}
            </div>

            {canSwitchWorkspaces && (
              <Select value={business.id} onValueChange={onWorkspaceChange}>
                <SelectTrigger className="w-[180px] sm:w-[240px]">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {businesses.map((workspace) => (
                    <SelectItem key={workspace.id} value={workspace.id}>
                      {workspace.name} · {businessKindLabel(workspace)} · {workspace.staff_role}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          </div>

          <div className="flex flex-wrap items-center gap-1 sm:gap-2">
            {rightSlot}
            {business && !hasAppNav && (
              <Button variant="ghost" size="sm" asChild>
                <Link to="/add-business">Add business</Link>
              </Button>
            )}
            {!hasAppNav && (
              <Button variant="ghost" size="sm" asChild>
                <Link to="/security" aria-label="Account security">
                  <ShieldCheck className="h-4 w-4" aria-hidden="true" />
                  <span className="hidden sm:inline">Security</span>
                </Link>
              </Button>
            )}
            {!hasAppNav && (
              <Button variant="ghost" size="sm" asChild>
                <Link to="/help" aria-label="Help Centre">
                  <HelpCircle className="h-4 w-4" aria-hidden="true" />
                  <span className="hidden sm:inline">Help</span>
                </Link>
              </Button>
            )}
            <NotificationBell />
            {!hasAppNav && (
              <Button variant="ghost" size="sm" onClick={onSignOut} aria-label="Sign out">
                <LogOut className="h-4 w-4" />
                <span className="hidden sm:inline">Sign out</span>
              </Button>
            )}
          </div>
        </div>
        {showNav && !hasAppNav && (
          <div className="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8">
            {/* Only reached with no business to build the workspace navigation from. */}
            <nav className="flex items-center gap-1 overflow-x-auto whitespace-nowrap py-1 [&>a]:shrink-0">
              <Link
                to="/dashboard"
                className="rounded-md px-3 py-2 text-sm font-medium text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
              >
                <LayoutDashboard className="mr-2 inline h-4 w-4" />
                Dashboard
              </Link>
              {isAdmin && (
                <Link
                  to="/admin"
                  className="rounded-md px-3 py-2 text-sm font-medium text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
                >
                  <ShieldCheck className="mr-2 inline h-4 w-4" />
                  Admin
                </Link>
              )}
            </nav>
          </div>
        )}
      </header>
      {/* Outside the header: its blur would otherwise become the frame for the fixed rail and bar. */}
      {hasAppNav && <AppNavigation isPlatformAdmin={isAdmin} onSignOut={onSignOut} />}
    </>
  );
}

export function VerificationBanner({ business }: { business: Business }) {
  if (business.verification_status === "approved") return null;
  const isRejected = business.verification_status === "rejected";

  return (
    <div
      className={`mb-6 flex items-start gap-3 rounded-xl border p-4 ${
        isRejected
          ? "border-destructive/30 bg-destructive/10 text-destructive"
          : "border-warning/40 bg-warning/10 text-warning-foreground"
      }`}
    >
      {isRejected ? (
        <ShieldAlert className="mt-0.5 h-5 w-5 shrink-0" />
      ) : (
        <Clock className="mt-0.5 h-5 w-5 shrink-0" />
      )}
      <div className="text-sm">
        <div className="font-semibold">
          {isRejected ? "Application rejected" : "Verification pending"}
        </div>
        <div className="mt-0.5 opacity-90">
          {isRejected
            ? business.rejection_reason || "Please contact support and resubmit your documents."
            : business.type === "pharmacy"
              ? "Upload your Pharmacy Council license to start ordering."
              : "Upload your wholesale license to start receiving orders."}
        </div>
        {!isRejected && (
          <Link
            to="/onboarding"
            className="mt-2 inline-block font-medium underline underline-offset-2"
          >
            Upload documents →
          </Link>
        )}
      </div>
    </div>
  );
}
