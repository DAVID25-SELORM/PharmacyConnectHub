import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { Pill, Building2, Store } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { toast } from "sonner";
import { z } from "zod";
import { supabase } from "@/integrations/supabase/client";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { GH_REGIONS } from "@/lib/format";

export const Route = createFileRoute("/signup")({
  head: () => ({
    meta: [
      { title: "Create account — PharmaHub GH" },
      { name: "description", content: "Join Ghana's B2B pharmaceutical marketplace." },
    ],
  }),
  component: SignupPage,
});

const schema = z.object({
  fullName: z.string().trim().min(2, "Your name is required").max(100),
  businessName: z.string().trim().min(2, "Business name is required").max(150),
  licenseNumber: z.string().trim().min(3, "License # is required").max(50),
  city: z.string().trim().min(2, "City is required").max(60),
  region: z.string().min(2, "Region is required"),
  phone: z.string().trim().min(7, "Phone is required").max(20),
  email: z.string().trim().email("Invalid email").max(255),
  password: z.string().min(8, "At least 8 characters").max(100),
});

function SignupPage() {
  const navigate = useNavigate();
  const [role, setRole] = useState<"pharmacy" | "wholesaler">("pharmacy");
  const [form, setForm] = useState({
    fullName: "",
    businessName: "",
    licenseNumber: "",
    city: "",
    region: "Greater Accra",
    phone: "",
    email: "",
    password: "",
  });
  const [loading, setLoading] = useState(false);

  const update = (k: keyof typeof form, v: string) => setForm((s) => ({ ...s, [k]: v }));

  const onSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    const parsed = schema.safeParse(form);
    if (!parsed.success) {
      toast.error(parsed.error.issues[0]?.message ?? "Check the form");
      return;
    }
    setLoading(true);
    const redirectUrl = `${window.location.origin}/dashboard`;
    const { data, error } = await supabase.auth.signUp({
      email: form.email,
      password: form.password,
      options: {
        emailRedirectTo: redirectUrl,
        data: { full_name: form.fullName, phone: form.phone, role },
      },
    });

    if (error) {
      setLoading(false);
      toast.error(error.message);
      return;
    }
    if (!data.user) {
      setLoading(false);
      toast.error("Signup failed");
      return;
    }

    // create business record
    const { error: bizError } = await supabase.from("businesses").insert({
      owner_id: data.user.id,
      type: role,
      name: form.businessName,
      license_number: form.licenseNumber,
      city: form.city,
      region: form.region,
      phone: form.phone,
    });

    setLoading(false);
    if (bizError) {
      toast.error("Account created but business setup failed: " + bizError.message);
      return;
    }
    toast.success("Account created! Upload your license to get verified.");
    navigate({ to: "/dashboard" });
  };

  return (
    <div className="min-h-screen bg-gradient-soft flex items-center justify-center p-4 py-10">
      <div className="w-full max-w-lg">
        <Link to="/" className="flex items-center justify-center gap-2 mb-8">
          <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-gradient-hero shadow-glow">
            <Pill className="h-5 w-5 text-primary-foreground" />
          </div>
          <span className="font-display text-xl font-bold">
            PharmaHub <span className="text-primary">GH</span>
          </span>
        </Link>

        <Card className="p-8 shadow-elegant">
          <h1 className="font-display text-2xl font-bold">Create your account</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            We verify every business before they can transact.
          </p>

          <div className="mt-6 grid grid-cols-2 gap-2 rounded-xl bg-muted p-1">
            <button
              type="button"
              onClick={() => setRole("pharmacy")}
              className={`flex items-center justify-center gap-2 rounded-lg px-3 py-2 text-sm font-medium transition-all ${
                role === "pharmacy"
                  ? "bg-surface text-foreground shadow-soft"
                  : "text-muted-foreground hover:text-foreground"
              }`}
            >
              <Store className="h-4 w-4" /> Pharmacy
            </button>
            <button
              type="button"
              onClick={() => setRole("wholesaler")}
              className={`flex items-center justify-center gap-2 rounded-lg px-3 py-2 text-sm font-medium transition-all ${
                role === "wholesaler"
                  ? "bg-surface text-foreground shadow-soft"
                  : "text-muted-foreground hover:text-foreground"
              }`}
            >
              <Building2 className="h-4 w-4" /> Wholesaler
            </button>
          </div>

          <form className="mt-6 space-y-4" onSubmit={onSubmit}>
            <div className="grid gap-4 sm:grid-cols-2">
              <div className="space-y-2">
                <Label htmlFor="fullName">Your full name</Label>
                <Input id="fullName" value={form.fullName} onChange={(e) => update("fullName", e.target.value)} required />
              </div>
              <div className="space-y-2">
                <Label htmlFor="phone">Phone</Label>
                <Input id="phone" value={form.phone} onChange={(e) => update("phone", e.target.value)} placeholder="+233 24 000 0000" required />
              </div>
            </div>
            <div className="space-y-2">
              <Label htmlFor="business">{role === "pharmacy" ? "Pharmacy name" : "Wholesale company name"}</Label>
              <Input id="business" value={form.businessName} onChange={(e) => update("businessName", e.target.value)} placeholder="e.g. Goodlife Pharmacy" required />
            </div>
            <div className="space-y-2">
              <Label htmlFor="license">Pharmacy Council license #</Label>
              <Input id="license" value={form.licenseNumber} onChange={(e) => update("licenseNumber", e.target.value)} placeholder="PCG-12345" required />
            </div>
            <div className="grid gap-4 sm:grid-cols-2">
              <div className="space-y-2">
                <Label htmlFor="city">City</Label>
                <Input id="city" value={form.city} onChange={(e) => update("city", e.target.value)} placeholder="Accra" required />
              </div>
              <div className="space-y-2">
                <Label htmlFor="region">Region</Label>
                <Select value={form.region} onValueChange={(v) => update("region", v)}>
                  <SelectTrigger><SelectValue /></SelectTrigger>
                  <SelectContent>
                    {GH_REGIONS.map((r) => <SelectItem key={r} value={r}>{r}</SelectItem>)}
                  </SelectContent>
                </Select>
              </div>
            </div>
            <div className="space-y-2">
              <Label htmlFor="email">Email</Label>
              <Input id="email" type="email" value={form.email} onChange={(e) => update("email", e.target.value)} placeholder="you@business.gh" required autoComplete="email" />
            </div>
            <div className="space-y-2">
              <Label htmlFor="password">Password</Label>
              <Input id="password" type="password" value={form.password} onChange={(e) => update("password", e.target.value)} placeholder="At least 8 characters" required autoComplete="new-password" />
            </div>
            <Button type="submit" variant="hero" size="lg" className="w-full" disabled={loading}>
              {loading ? "Creating account…" : "Create account"}
            </Button>
            <p className="text-xs text-muted-foreground text-center">
              By signing up you agree to our terms and privacy policy.
            </p>
          </form>

          <p className="mt-6 text-center text-sm text-muted-foreground">
            Already have an account?{" "}
            <Link to="/login" className="font-medium text-primary hover:underline">
              Sign in
            </Link>
          </p>
        </Card>
      </div>
    </div>
  );
}
