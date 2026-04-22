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
      { title: "Sign in - PharmaHub GH" },
      { name: "description", content: "Sign in to your PharmaHub GH account." },
    ],
  }),
  component: LoginPage,
});

function LoginPage() {
  const navigate = useNavigate();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);

  const onSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    const { error } = await supabase.auth.signInWithPassword({
      email: email.trim().toLowerCase(),
      password,
    });
    setLoading(false);
    if (error) {
      if (error.message.toLowerCase().includes("invalid login credentials")) {
        toast.error(
          "Invalid email or password. If you were added as staff, sign in with the email already registered on PharmaHub or use Forgot password to reset access.",
        );
      } else {
        toast.error(error.message);
      }
      return;
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
          <img src={logo} alt="PharmaHub GH" className="h-10 w-10 rounded-xl object-contain" />
          <span className="font-display text-xl font-bold">
            Pharma<span className="text-primary">Hub GH</span>
          </span>
        </Link>

        <Card className="p-8 shadow-elegant">
          <h1 className="font-display text-2xl font-bold">Welcome back</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Sign in to continue to your dashboard.
          </p>

          <form className="mt-6 space-y-4" onSubmit={onSubmit}>
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
                type="password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="********"
                required
                autoComplete="current-password"
              />
            </div>
            <Button type="submit" variant="hero" size="lg" className="w-full" disabled={loading}>
              {loading ? "Signing in..." : "Sign in"}
            </Button>
          </form>

          <div className="mt-6 rounded-xl border border-primary/15 bg-primary/5 px-4 py-3 text-center">
            <p className="text-sm text-muted-foreground">New to PharmaHub?</p>
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
