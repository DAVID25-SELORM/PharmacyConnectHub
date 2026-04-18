import { Link, useNavigate } from "@tanstack/react-router";
import {
  Clock,
  LayoutDashboard,
  LogOut,
  Package,
  ShieldAlert,
  ShieldCheck,
  Users,
} from "lucide-react";
import logo from "@/assets/logo.jpg";
import { Button } from "@/components/ui/button";
import { supabase } from "@/integrations/supabase/client";
import { toast } from "sonner";
import type { Business } from "@/hooks/use-session";

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
