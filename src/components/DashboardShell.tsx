import { Link, useNavigate } from "@tanstack/react-router";
import {
  Bell,
  CheckCheck,
  Clock,
  LayoutDashboard,
  LogOut,
  Package,
  ShieldAlert,
  ShieldCheck,
  Users,
} from "lucide-react";
import { useEffect, useRef, useState } from "react";
import logo from "@/assets/logo.jpg";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { supabase } from "@/integrations/supabase/client";
import { toast } from "sonner";
import type { Business } from "@/hooks/use-session";
import type { RealtimeChannel } from "@supabase/supabase-js";

type NotificationRow = {
  id: string;
  type: string;
  title: string;
  body: string;
  read: boolean;
  created_at: string;
};

function timeAgoShort(iso: string) {
  const diff = Date.now() - new Date(iso).getTime();
  const m = Math.floor(diff / 60000);
  if (m < 1) return "just now";
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  return `${Math.floor(h / 24)}d ago`;
}

function NotificationBell() {
  const [open, setOpen] = useState(false);
  const [notes, setNotes] = useState<NotificationRow[]>([]);
  const channelRef = useRef<RealtimeChannel | null>(null);

  const load = async () => {
    const {
      data: { session },
    } = await supabase.auth.getSession();
    if (!session) return;
    const { data } = await supabase
      .from("notifications")
      .select("id,type,title,body,read,created_at")
      .eq("user_id", session.user.id)
      .order("created_at", { ascending: false })
      .limit(30);
    setNotes((data as NotificationRow[]) ?? []);
  };

  useEffect(() => {
    void load();

    supabase.auth.getSession().then(({ data: { session } }) => {
      if (!session) return;
      const channel = supabase
        .channel("notifications:" + session.user.id)
        .on(
          "postgres_changes",
          {
            event: "INSERT",
            schema: "public",
            table: "notifications",
            filter: `user_id=eq.${session.user.id}`,
          },
          () => void load(),
        )
        .subscribe();
      channelRef.current = channel;
    });

    return () => {
      if (channelRef.current) void supabase.removeChannel(channelRef.current);
    };
  }, []);

  const markAllRead = async () => {
    const unread = notes.filter((n) => !n.read).map((n) => n.id);
    if (unread.length === 0) return;
    await supabase.from("notifications").update({ read: true }).in("id", unread);
    setNotes((prev) => prev.map((n) => ({ ...n, read: true })));
  };

  const unreadCount = notes.filter((n) => !n.read).length;

  const handleOpen = (value: boolean) => {
    setOpen(value);
    if (value) void markAllRead();
  };

  return (
    <Popover open={open} onOpenChange={handleOpen}>
      <PopoverTrigger asChild>
        <Button variant="ghost" size="sm" className="relative">
          <Bell className="h-4 w-4" />
          {unreadCount > 0 && (
            <span className="absolute -right-1 -top-1 flex h-4 min-w-4 items-center justify-center rounded-full bg-destructive px-1 text-[10px] font-bold text-destructive-foreground ring-2 ring-background">
              {unreadCount > 9 ? "9+" : unreadCount}
            </span>
          )}
        </Button>
      </PopoverTrigger>
      <PopoverContent align="end" className="w-80 p-0">
        <div className="flex items-center justify-between border-b border-border px-4 py-3">
          <span className="text-sm font-semibold">Notifications</span>
          {notes.some((n) => !n.read) && (
            <button
              onClick={markAllRead}
              className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
            >
              <CheckCheck className="h-3.5 w-3.5" />
              Mark all read
            </button>
          )}
        </div>
        <div className="max-h-95 overflow-y-auto">
          {notes.length === 0 ? (
            <div className="px-4 py-8 text-center text-sm text-muted-foreground">
              No notifications yet.
            </div>
          ) : (
            notes.map((n) => (
              <div
                key={n.id}
                className={`border-b border-border px-4 py-3 last:border-0 ${n.read ? "opacity-60" : "bg-primary/5"}`}
              >
                {!n.read && (
                  <span className="mb-1 inline-block h-1.5 w-1.5 rounded-full bg-primary" />
                )}
                <div className="text-sm font-medium">{n.title}</div>
                <div className="mt-0.5 text-xs text-muted-foreground">{n.body}</div>
                <div className="mt-1 text-[11px] text-muted-foreground">
                  {timeAgoShort(n.created_at)}
                </div>
              </div>
            ))
          )}
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

  const onSignOut = async () => {
    await supabase.auth.signOut();
    toast.success("Signed out");
    navigate({ to: "/" });
  };

  return (
    <header className="sticky top-0 z-40 border-b border-border bg-background/85 backdrop-blur-xl">
      <div className="mx-auto flex h-16 max-w-7xl items-center justify-between px-4 sm:px-6 lg:px-8">
        <div className="flex items-center gap-6">
          <Link to="/" className="flex items-center gap-2">
            <img src={logo} alt="PharmaHub GH" className="h-9 w-9 rounded-xl object-contain" />
            <div>
              <div className="font-display text-base font-bold leading-none">
                Pharma<span className="text-primary">Hub GH</span>
              </div>
              <div className="text-[11px] text-muted-foreground">{subtitle}</div>
            </div>
          </Link>

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
                to="/pharmacy"
                className="px-3 py-2 text-sm font-medium text-muted-foreground hover:text-foreground transition-colors rounded-md hover:bg-accent"
              >
                <Package className="h-4 w-4 inline mr-2" />
                Browse
              </Link>
              <Link
                to="/staff"
                className="px-3 py-2 text-sm font-medium text-muted-foreground hover:text-foreground transition-colors rounded-md hover:bg-accent"
              >
                <Users className="h-4 w-4 inline mr-2" />
                Team
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

        <div className="flex items-center gap-2">
          {rightSlot}
          <NotificationBell />
          <Button variant="ghost" size="sm" onClick={onSignOut}>
            <LogOut className="h-4 w-4" /> Sign out
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
