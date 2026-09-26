import { Link, useNavigate, useRouter } from "@tanstack/react-router";
import {
  Bell,
  CheckCheck,
  Clock,
  HelpCircle,
  BarChart3,
  Home,
  LayoutDashboard,
  LogOut,
  Package,
  ShieldAlert,
  ShieldCheck,
  Users,
} from "lucide-react";
import { useEffect, useState } from "react";
import logo from "@/assets/logo.jpg";
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
import { toast } from "sonner";
import { useSession, type Business } from "@/hooks/use-session";
import {
  NOTIFICATIONS_CHANGED_EVENT,
  openInternalLink,
  timeAgoShort,
  type NotificationRow,
} from "@/lib/notifications";

function NotificationBell() {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [notes, setNotes] = useState<NotificationRow[]>([]);
  const [unreadTotal, setUnreadTotal] = useState(0);

  const load = async () => {
    const {
      data: { session },
    } = await supabase.auth.getSession();
    if (!session) return;
    const [{ data }, { count }] = await Promise.all([
      supabase
        .from("notifications")
        .select("id,type,title,body,read,link,created_at")
        .eq("user_id", session.user.id)
        .order("created_at", { ascending: false })
        .limit(15),
      supabase
        .from("notifications")
        .select("id", { count: "exact", head: true })
        .eq("user_id", session.user.id)
        .eq("read", false),
    ]);
    setNotes((data as unknown as NotificationRow[]) ?? []);
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
    // eslint-disable-next-line react-hooks/exhaustive-deps
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
    openInternalLink(router, note.link);
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
  const workspaceRoute = business?.type === "wholesaler" ? "/wholesaler" : "/pharmacy";
  const reportsRoute =
    business?.type === "wholesaler" ? "/wholesaler/reports" : "/pharmacy/reports";
  const workspaceLabel = business?.type === "wholesaler" ? "Workspace" : "Browse";
  // The switcher stays available without the full nav so a user stuck on a pending
  // workspace's onboarding page can still switch to an approved one.
  const canSwitchWorkspaces = businesses.length > 1 && business;

  const onSignOut = async () => {
    await supabase.auth.signOut();
    toast.success("Signed out");
    navigate({ to: "/" });
  };

  const onWorkspaceChange = (businessId: string) => {
    if (!business || businessId === business.id) {
      return;
    }

    setActiveBusiness(businessId);
    navigate({ to: "/dashboard" });
  };

  return (
    <header className="sticky top-0 z-40 border-b border-border bg-background/85 backdrop-blur-xl">
      <div className="mx-auto flex h-16 max-w-7xl items-center justify-between gap-2 px-4 sm:px-6 lg:px-8">
        <div className="flex min-w-0 items-center gap-3 lg:gap-6">
          <div className="flex min-w-0 items-center gap-2">
            <Button
              variant="ghost"
              size="icon"
              onClick={() => navigate({ to: "/dashboard" })}
              aria-label="Go to dashboard"
            >
              <Home className="h-4 w-4" />
            </Button>
            <Link to="/" className="flex min-w-0 items-center gap-2">
              <img src={logo} alt="Drugxone" className="h-9 w-9 rounded-xl object-contain" />
              <div className="hidden min-w-0 sm:block">
                <div className="truncate font-display text-base font-bold leading-none">
                  Drug<span className="text-primary">xone</span>
                </div>
                <div className="truncate text-[11px] text-muted-foreground">{subtitle}</div>
              </div>
            </Link>
          </div>

          {canSwitchWorkspaces && (
            <Select value={business.id} onValueChange={onWorkspaceChange}>
              <SelectTrigger className="w-[180px] sm:w-[240px]">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {businesses.map((workspace) => (
                  <SelectItem key={workspace.id} value={workspace.id}>
                    {workspace.name} · {workspace.type} · {workspace.staff_role}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}

          {showNav && (
            <nav className="hidden md:flex items-center gap-1">
              <Link
                to="/dashboard"
                className="px-3 py-2 text-sm font-medium text-muted-foreground hover:text-foreground transition-colors rounded-md hover:bg-accent"
              >
                <LayoutDashboard className="h-4 w-4 inline mr-2" />
                Dashboard
              </Link>
              <Link
                to={workspaceRoute}
                className="px-3 py-2 text-sm font-medium text-muted-foreground hover:text-foreground transition-colors rounded-md hover:bg-accent"
              >
                <Package className="h-4 w-4 inline mr-2" />
                {workspaceLabel}
              </Link>
              <Link
                to="/staff"
                className="px-3 py-2 text-sm font-medium text-muted-foreground hover:text-foreground transition-colors rounded-md hover:bg-accent"
              >
                <Users className="h-4 w-4 inline mr-2" />
                Team
              </Link>
              <Link
                to={reportsRoute}
                className="px-3 py-2 text-sm font-medium text-muted-foreground hover:text-foreground transition-colors rounded-md hover:bg-accent"
              >
                <BarChart3 className="h-4 w-4 inline mr-2" />
                Reports
              </Link>
              {isAdmin && (
                <Link
                  to="/admin"
                  className="px-3 py-2 text-sm font-medium text-muted-foreground hover:text-foreground transition-colors rounded-md hover:bg-accent"
                >
                  <ShieldCheck className="h-4 w-4 inline mr-2" />
                  Admin
                </Link>
              )}
            </nav>
          )}
        </div>

        <div className="flex shrink-0 items-center gap-1 sm:gap-2">
          {rightSlot}
          {business && (
            <Button variant="ghost" size="sm" asChild>
              <Link to="/add-business">Add business</Link>
            </Button>
          )}
          <Button variant="ghost" size="sm" asChild>
            <Link to="/help" aria-label="Help Centre">
              <HelpCircle className="h-4 w-4" aria-hidden="true" />
              <span className="hidden sm:inline">Help</span>
            </Link>
          </Button>
          <NotificationBell />
          <Button variant="ghost" size="sm" onClick={onSignOut} aria-label="Sign out">
            <LogOut className="h-4 w-4" />
            <span className="hidden sm:inline">Sign out</span>
          </Button>
        </div>
      </div>
    </header>
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
