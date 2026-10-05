import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { toast } from "sonner";
import { supabase } from "@/integrations/supabase/client";
import logo from "@/assets/logo.jpg";

export const Route = createFileRoute("/login")({
  head: () => ({
    meta: [
      { title: "Sign in - Drugxone" },
      { name: "description", content: "Sign in to your Drugxone account." },
    ],
  }),
  component: LoginPage,
});

function LoginPage() {
  const navigate = useNavigate();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [loginError, setLoginError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const onSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (loading) return;
    setLoading(true);
    setLoginError(null);
    try {
      const { error } = await supabase.auth.signInWithPassword({
        email: email.trim().toLowerCase(),
        password,
      });
      if (error) {
        const message =
          error.code === "email_not_confirmed"
            ? "Confirm your email using the signup link before signing in. Business approval is separate from email confirmation."
            : error.code === "invalid_credentials" ||
                /invalid login credentials/i.test(error.message)
              ? "The email and password did not match. Use your registered owner or staff login email. If you have confirmed your email but still cannot sign in, reset your password using Forgot password below."
              : error.message;
        setLoginError(message);
        return;
      }
    } catch {
      setLoginError("Unable to connect. Check your internet connection and try again.");
      return;
    } finally {
      setLoading(false);
    }
    toast.success("Welcome back!");
    try {
      window.localStorage.removeItem("pharmahub.active_business_id");
    } catch {
      // Ignore storage failures and continue into the workspace flow.
    }
    navigate({ to: "/dashboard" });
  };

  return (
    <div className="min-h-screen bg-gradient-soft flex items-center justify-center p-4">
      <div className="w-full max-w-md">
        <Link to="/" className="flex items-center justify-center gap-2 mb-8">
          <img src={logo} alt="Drugxone" className="h-10 w-10 rounded-xl object-contain" />
          <span className="font-display text-xl font-bold">
            Drug<span className="text-primary">xone</span>
          </span>
        </Link>

        <Card className="p-8 shadow-elegant">
          <h1 className="font-display text-2xl font-bold">Welcome back</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Sign in to continue to your dashboard.
          </p>

          <form className="mt-6 space-y-4" onSubmit={onSubmit}>
            {loginError && (
              <div
                role="alert"
                className="rounded-lg border border-destructive/30 bg-destructive/5 p-3 text-sm"
              >
                <p>{loginError}</p>
                <Link
                  to="/forgot-password"
                  className="mt-2 inline-block font-medium text-primary underline"
                >
                  Forgot password / reset password
                </Link>
              </div>
            )}
            <div className="space-y-2">
              <Label htmlFor="email">Email</Label>
              <Input
                id="email"
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="you@pharmacy.gh"
                required
                autoComplete="email"
              />
            </div>
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <Label htmlFor="password">Password</Label>
                <Link
                  to="/forgot-password"
                  className="text-xs text-muted-foreground hover:text-primary transition-colors"
                >
                  Forgot password?
                </Link>
              </div>
              <Input
                id="password"
                type={showPassword ? "text" : "password"}
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="********"
                required
                autoComplete="current-password"
              />
            </div>
            <Button
              type="button"
              variant="ghost"
              size="sm"
              aria-pressed={showPassword}
              onClick={() => setShowPassword(!showPassword)}
            >
              {showPassword ? "Hide password" : "Show password"}
            </Button>
            <Button type="submit" variant="hero" size="lg" className="w-full" disabled={loading}>
              {loading ? "Signing in..." : "Sign in"}
            </Button>
          </form>

          <div className="mt-6 rounded-xl border border-primary/15 bg-primary/5 px-4 py-3 text-center">
            <p className="text-sm text-muted-foreground">New to Drugxone?</p>
            <Link
              to="/signup"
              className="mt-1 inline-block text-base font-semibold text-primary underline-offset-4 transition-colors hover:underline"
            >
              Create an account
            </Link>
          </div>
        </Card>
      </div>
    </div>
  );
}
