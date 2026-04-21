import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { toast } from "sonner";
import { supabase } from "@/integrations/supabase/client";
import logo from "@/assets/logo.jpg";

export const Route = createFileRoute("/reset-password")({
  component: ResetPasswordPage,
});

type ResetLinkStatus = "verifying" | "ready" | "error";
type PasswordLinkType = "invite" | "recovery";

const DEFAULT_RESET_LINK_ERROR =
  "This password reset link is invalid or has expired. Request a new link and try again.";

function isPasswordLinkType(value: string | null): value is PasswordLinkType {
  return value === "invite" || value === "recovery";
}

function getRecoveryParams() {
  const searchParams = new URLSearchParams(window.location.search);
  const hashParams = new URLSearchParams(window.location.hash.replace(/^#/, ""));

  return {
    code: searchParams.get("code"),
    tokenHash: searchParams.get("token_hash") ?? hashParams.get("token_hash"),
    type: searchParams.get("type") ?? hashParams.get("type"),
    accessToken: hashParams.get("access_token") ?? searchParams.get("access_token"),
    refreshToken: hashParams.get("refresh_token") ?? searchParams.get("refresh_token"),
    errorDescription: searchParams.get("error_description") ?? hashParams.get("error_description"),
  };
}

function clearRecoveryParams() {
  const nextUrl = new URL(window.location.href);

  nextUrl.searchParams.delete("code");
  nextUrl.searchParams.delete("token_hash");
  nextUrl.searchParams.delete("type");
  nextUrl.searchParams.delete("error");
  nextUrl.searchParams.delete("error_code");
  nextUrl.searchParams.delete("error_description");
  nextUrl.hash = "";

  window.history.replaceState(window.history.state, "", nextUrl.toString());
}

function ResetPasswordPage() {
  const navigate = useNavigate();
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [loading, setLoading] = useState(false);
  const [status, setStatus] = useState<ResetLinkStatus>("verifying");
  const [linkError, setLinkError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;

    const markReady = () => {
      if (!active) return;
      setLinkError(null);
      setStatus("ready");
    };

    const markError = (message: string) => {
      if (!active) return;
      setLinkError(message);
      setStatus("error");
    };

    void (async () => {
      const { code, tokenHash, type, accessToken, refreshToken, errorDescription } =
        getRecoveryParams();
      const passwordLinkType = isPasswordLinkType(type) ? type : null;

      if (errorDescription) {
        clearRecoveryParams();
        markError(errorDescription);
        return;
      }

      if (code) {
        const { error } = await supabase.auth.exchangeCodeForSession(code);
        if (error) {
          clearRecoveryParams();
          markError(error.message);
          return;
        }
      } else if (tokenHash && passwordLinkType) {
        const { error } = await supabase.auth.verifyOtp({
          token_hash: tokenHash,
          type: passwordLinkType,
        });
        if (error) {
          clearRecoveryParams();
          markError(error.message);
          return;
        }
      } else if (accessToken && refreshToken) {
        const { error } = await supabase.auth.setSession({
          access_token: accessToken,
          refresh_token: refreshToken,
        });
        if (error) {
          clearRecoveryParams();
          markError(error.message);
          return;
        }
      } else {
        const {
          data: { session },
          error: sessionError,
        } = await supabase.auth.getSession();

        if (!active) {
          return;
        }

        if (sessionError) {
          markError(sessionError.message);
          return;
        }

        if (session) {
          markReady();
          return;
        }

        markError(DEFAULT_RESET_LINK_ERROR);
        return;
      }

      clearRecoveryParams();

      const {
        data: { session: recoverySession },
      } = await supabase.auth.getSession();

      if (recoverySession) {
        markReady();
        return;
      }

      markError(DEFAULT_RESET_LINK_ERROR);
    })();

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((event, session) => {
      if ((event === "PASSWORD_RECOVERY" || event === "SIGNED_IN") && session) {
        clearRecoveryParams();
        markReady();
      }
    });

    return () => {
      active = false;
      subscription.unsubscribe();
    };
  }, []);

  const onSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (password !== confirm) {
      toast.error("Passwords don't match");
      return;
    }
    if (password.length < 8) {
      toast.error("Password must be at least 8 characters");
      return;
    }
    setLoading(true);
    const { error } = await supabase.auth.updateUser({ password });
    setLoading(false);
    if (error) {
      toast.error(error.message);
      return;
    }
    toast.success("Password updated. Opening your workspace.");
    navigate({ to: "/dashboard", replace: true });
  };

  if (status === "verifying") {
    return (
      <div className="min-h-screen bg-gradient-soft flex items-center justify-center p-4">
        <div className="w-full max-w-md text-center space-y-3">
          <p className="text-muted-foreground">Verifying reset link...</p>
          <p className="text-sm text-muted-foreground">
            If nothing happens,{" "}
            <Link to="/forgot-password" className="text-primary hover:underline font-medium">
              request a new link
            </Link>
            .
          </p>
        </div>
      </div>
    );
  }

  if (status === "error") {
    return (
      <div className="min-h-screen bg-gradient-soft flex items-center justify-center p-4">
        <div className="w-full max-w-md">
          <Link to="/" className="flex items-center justify-center gap-2 mb-8">
            <img src={logo} alt="PharmaHub GH" className="h-10 w-10 rounded-xl object-contain" />
            <span className="font-display text-xl font-bold">
              Pharma<span className="text-primary">Hub GH</span>
            </span>
          </Link>

          <Card className="p-8 shadow-elegant text-center space-y-3">
            <h1 className="font-display text-2xl font-bold">Reset link unavailable</h1>
            <p className="text-sm text-muted-foreground">{linkError ?? DEFAULT_RESET_LINK_ERROR}</p>
            <div className="pt-2 space-y-2">
              <Button asChild variant="hero" size="lg" className="w-full">
                <Link to="/forgot-password">Request a new reset link</Link>
              </Button>
              <Link
                to="/login"
                className="inline-block text-sm font-medium text-primary hover:underline"
              >
                Back to sign in
              </Link>
            </div>
          </Card>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gradient-soft flex items-center justify-center p-4">
      <div className="w-full max-w-md">
        <Link to="/" className="flex items-center justify-center gap-2 mb-8">
          <img src={logo} alt="PharmaHub GH" className="h-10 w-10 rounded-xl object-contain" />
          <span className="font-display text-xl font-bold">
            Pharma<span className="text-primary">Hub GH</span>
          </span>
        </Link>

        <Card className="p-8 shadow-elegant">
          <h1 className="font-display text-2xl font-bold">Set new password</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Choose a strong password to finish account access.
          </p>

          <form className="mt-6 space-y-4" onSubmit={onSubmit}>
            <div className="space-y-2">
              <Label htmlFor="password">New password</Label>
              <Input
                id="password"
                type="password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="........"
                required
                autoComplete="new-password"
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="confirm">Confirm password</Label>
              <Input
                id="confirm"
                type="password"
                value={confirm}
                onChange={(e) => setConfirm(e.target.value)}
                placeholder="........"
                required
                autoComplete="new-password"
              />
            </div>
            <Button type="submit" variant="hero" size="lg" className="w-full" disabled={loading}>
              {loading ? "Updating..." : "Update password"}
            </Button>
          </form>
        </Card>
      </div>
    </div>
  );
}
