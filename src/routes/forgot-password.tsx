import { createFileRoute, Link } from "@tanstack/react-router";
import { useState } from "react";
import { CheckCircle } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { toast } from "sonner";
import { supabase } from "@/integrations/supabase/client";
import { getAppUrl } from "@/lib/site-url";
import logo from "@/assets/logo.jpg";

export const Route = createFileRoute("/forgot-password")({
  component: ForgotPasswordPage,
});

function ForgotPasswordPage() {
  const [email, setEmail] = useState("");
  const [loading, setLoading] = useState(false);
  const [sent, setSent] = useState(false);

  const onSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    const { error } = await supabase.auth.resetPasswordForEmail(email.trim().toLowerCase(), {
      redirectTo: getAppUrl("/reset-password"),
    });
    setLoading(false);
    if (error) {
      toast.error(error.message);
      return;
    }
    setSent(true);
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
          {sent ? (
            <div className="text-center space-y-3">
              <CheckCircle className="mx-auto h-12 w-12 text-green-500" />
              <h1 className="font-display text-2xl font-bold">Check your email</h1>
              <p className="text-sm text-muted-foreground">
                We sent a password reset link to <strong>{email}</strong>. Check your inbox and spam
                folder.
              </p>
              <Link
                to="/login"
                className="text-sm text-primary hover:underline font-medium block pt-2"
              >
                Back to sign in
              </Link>
            </div>
          ) : (
            <>
              <h1 className="font-display text-2xl font-bold">Forgot password?</h1>
              <p className="mt-1 text-sm text-muted-foreground">
                Enter your email and we&apos;ll send you a reset link.
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
                <Button
                  type="submit"
                  variant="hero"
                  size="lg"
                  className="w-full"
                  disabled={loading}
                >
                  {loading ? "Sending…" : "Send reset link"}
                </Button>
              </form>

              <p className="mt-6 text-center text-sm text-muted-foreground">
                Remember your password?{" "}
                <Link to="/login" className="font-medium text-primary hover:underline">
                  Sign in
                </Link>
              </p>
            </>
          )}
        </Card>
      </div>
    </div>
  );
}
