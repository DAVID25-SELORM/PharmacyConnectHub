import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { Building2, CheckCircle, Store } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { toast } from "sonner";
import { z } from "zod";
import logo from "@/assets/logo.jpg";
import { supabase } from "@/integrations/supabase/client";
import { GH_REGIONS } from "@/lib/format";
import { formatGhanaPhone, isValidGhanaPhone, normalizeGhanaPhone } from "@/lib/ghana-phone";
import { buildSignupPayload } from "@/lib/signup-payload";
import { getAppUrl } from "@/lib/site-url";

export const Route = createFileRoute("/signup")({
  head: () => ({
    meta: [
      { title: "Create account - PharmaHub GH" },
      { name: "description", content: "Join Ghana's B2B pharmaceutical marketplace." },
    ],
  }),
  component: SignupPage,
});

const schema = z.object({
  ownerFullName: z.string().trim().min(2, "Owner name is required").max(100),
  ownerPhone: z
    .string()
    .trim()
    .min(7, "Owner phone is required")
    .max(20)
    .refine(isValidGhanaPhone, "Enter a valid Ghana phone number"),
  businessName: z.string().trim().min(2, "Business name is required").max(150),
  licenseNumber: z.string().trim().min(3, "License # is required").max(50),
  businessPhone: z
    .string()
    .trim()
    .min(7, "Business phone is required")
    .max(20)
    .refine(isValidGhanaPhone, "Enter a valid Ghana phone number"),
  businessEmail: z.string().trim().email("Enter a valid public business email").max(255),
  city: z.string().trim().min(2, "City is required").max(60),
  region: z.string().min(2, "Region is required"),
  gpsAddress: z.string().trim().max(160),
  locationDescription: z.string().trim().max(240),
  workingHours: z.string().trim().max(120),
  ownerEmail: z.string().trim().email("Enter a valid owner email").max(255),
  password: z.string().min(8, "At least 8 characters").max(100),
  ownerIsSuperintendent: z.boolean(),
  superintendentName: z.string().trim().max(100),
  superintendentPhone: z.string().trim().max(20),
  superintendentEmail: z.string().trim().max(255),
});

const emailSchema = z.string().trim().email("Enter a valid email address");

type SignupForm = z.infer<typeof schema>;
type TextField = keyof SignupForm;

function SignupPage() {
  const navigate = useNavigate();
  const [role, setRole] = useState<"pharmacy" | "wholesaler">("pharmacy");
  const [form, setForm] = useState<SignupForm>({
    ownerFullName: "",
    ownerPhone: "",
    businessName: "",
    licenseNumber: "",
    businessPhone: "",
    businessEmail: "",
    city: "",
    region: "Greater Accra",
    gpsAddress: "",
    locationDescription: "",
    workingHours: "",
    ownerEmail: "",
    password: "",
    ownerIsSuperintendent: true,
    superintendentName: "",
    superintendentPhone: "",
    superintendentEmail: "",
  });
  const [loading, setLoading] = useState(false);
  const [emailSent, setEmailSent] = useState(false);

  const update = (field: TextField, value: SignupForm[TextField]) => {
    setForm((current) => ({ ...current, [field]: value }));
  };

  const formatPhoneField = (field: "ownerPhone" | "businessPhone" | "superintendentPhone") => {
    setForm((current) => {
      const value = current[field].trim();
      if (!value) {
        return current;
      }

      try {
        return { ...current, [field]: formatGhanaPhone(value) };
      } catch {
        return current;
      }
    });
  };

  const superintendentDetails = {
    name: form.ownerIsSuperintendent ? form.ownerFullName : form.superintendentName,
    phone: form.ownerIsSuperintendent ? form.ownerPhone : form.superintendentPhone,
    email: form.ownerIsSuperintendent ? form.ownerEmail : form.superintendentEmail,
  };

  const onSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const parsed = schema.safeParse(form);
    if (!parsed.success) {
      toast.error(parsed.error.issues[0]?.message ?? "Check the form");
      return;
    }

    if (role === "pharmacy" && superintendentDetails.name.trim().length < 2) {
      toast.error("Superintendent pharmacist name is required");
      return;
    }

    if (role === "pharmacy" && !isValidGhanaPhone(superintendentDetails.phone)) {
      toast.error("Enter a valid superintendent pharmacist phone number");
      return;
    }

    if (role === "pharmacy" && !emailSchema.safeParse(superintendentDetails.email).success) {
      toast.error("Enter a valid superintendent pharmacist email address");
      return;
    }

    setLoading(true);

    try {
      const redirectUrl = getAppUrl("/dashboard");
      const signupPayload = buildSignupPayload(form, role);

      const { data, error } = await supabase.auth.signUp({
        email: signupPayload.email,
        password: form.password,
        options: {
          emailRedirectTo: redirectUrl,
          data: signupPayload.metadata,
        },
      });

      if (error) {
        toast.error(error.message);
        return;
      }

      if (!data.user) {
        toast.error("Signup failed");
        return;
      }

      // The business row is created by the auth trigger so both auto-confirmed
      // and email-confirmed signups land in the same workspace shape.
      // If session exists Supabase skipped email confirmation - go straight to dashboard
      if (data.session) {
        toast.success("Account created! Upload your license to get verified.");
        navigate({ to: "/dashboard" });
      } else {
        // Email confirmation is enabled - prompt the user to check inbox
        setEmailSent(true);
      }
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen bg-gradient-soft flex items-center justify-center p-4 py-10">
      <div className="w-full max-w-3xl">
        <Link to="/" className="flex items-center justify-center gap-2 mb-8">
          <img src={logo} alt="PharmaHub GH" className="h-10 w-10 rounded-xl object-contain" />
          <span className="font-display text-xl font-bold">
            Pharma<span className="text-primary">Hub GH</span>
          </span>
        </Link>

        {emailSent ? (
          <Card className="p-8 shadow-elegant text-center space-y-4">
            <CheckCircle className="mx-auto h-12 w-12 text-green-500" />
            <h1 className="font-display text-2xl font-bold">Confirm your email</h1>
            <p className="text-sm text-muted-foreground">
              We sent a confirmation link to <strong>{form.ownerEmail}</strong>. Click it to
              activate your account, then come back to sign in.
            </p>
            <Link to="/login" className="text-sm text-primary hover:underline font-medium block">
              Go to sign in
            </Link>
          </Card>
        ) : (
          <Card className="p-8 shadow-elegant">
            <h1 className="font-display text-2xl font-bold">Create your account</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              We verify every business before they can transact. Business-facing details stay
              public, while owner and superintendent contacts stay internal.
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

            <form className="mt-6 space-y-6" onSubmit={onSubmit}>
              <section className="space-y-4 rounded-2xl border border-border/70 bg-muted/20 p-5">
                <div>
                  <h2 className="font-display text-lg font-semibold">
                    {role === "pharmacy" ? "Pharmacy Information" : "Business Information"}
                  </h2>
                  <p className="mt-1 text-sm text-muted-foreground">
                    These are the details we use to present and verify your workspace.
                  </p>
                </div>

                <div className="grid gap-4 sm:grid-cols-2">
                  <div className="space-y-2">
                    <Label htmlFor="businessName">
                      {role === "pharmacy" ? "Pharmacy name" : "Wholesale company name"}
                    </Label>
                    <Input
                      id="businessName"
                      value={form.businessName}
                      onChange={(e) => update("businessName", e.target.value)}
                      placeholder={
                        role === "pharmacy" ? "e.g. Goodlife Pharmacy" : "e.g. PharmaHub Wholesale"
                      }
                      required
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="businessPhone">
                      {role === "pharmacy" ? "Pharmacy phone (public)" : "Business phone (public)"}
                    </Label>
                    <Input
                      id="businessPhone"
                      type="tel"
                      value={form.businessPhone}
                      onChange={(e) => update("businessPhone", e.target.value)}
                      onBlur={() => formatPhoneField("businessPhone")}
                      placeholder="+233 24 000 0000 or 024 000 0000"
                      required
                      autoComplete="tel"
                    />
                  </div>
                </div>

                <div className="grid gap-4 sm:grid-cols-2">
                  <div className="space-y-2">
                    <Label htmlFor="businessEmail">
                      {role === "pharmacy" ? "Pharmacy email (public)" : "Business email (public)"}
                    </Label>
                    <Input
                      id="businessEmail"
                      type="email"
                      value={form.businessEmail}
                      onChange={(e) => update("businessEmail", e.target.value)}
                      placeholder="hello@business.gh"
                      required
                      autoComplete="email"
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="license">
                      {role === "pharmacy"
                        ? "Pharmacy Council license #"
                        : "Business license / registration #"}
                    </Label>
                    <Input
                      id="license"
                      value={form.licenseNumber}
                      onChange={(e) => update("licenseNumber", e.target.value)}
                      placeholder={role === "pharmacy" ? "PCG-12345" : "REG-12345"}
                      required
                    />
                  </div>
                </div>

                <div className="grid gap-4 sm:grid-cols-2">
                  <div className="space-y-2">
                    <Label htmlFor="city">City</Label>
                    <Input
                      id="city"
                      value={form.city}
                      onChange={(e) => update("city", e.target.value)}
                      placeholder="Accra"
                      required
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="region">Region</Label>
                    <Select value={form.region} onValueChange={(value) => update("region", value)}>
                      <SelectTrigger id="region">
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        {GH_REGIONS.map((region) => (
                          <SelectItem key={region} value={region}>
                            {region}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  </div>
                </div>

                <div className="grid gap-4 sm:grid-cols-2">
                  <div className="space-y-2">
                    <Label htmlFor="gpsAddress">GPS address</Label>
                    <Input
                      id="gpsAddress"
                      value={form.gpsAddress}
                      onChange={(e) => update("gpsAddress", e.target.value)}
                      placeholder="GA-123-4567"
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="workingHours">Working hours</Label>
                    <Input
                      id="workingHours"
                      value={form.workingHours}
                      onChange={(e) => update("workingHours", e.target.value)}
                      placeholder="Mon-Sat 8am-9pm"
                    />
                  </div>
                </div>

                <div className="space-y-2">
                  <Label htmlFor="locationDescription">Exact location description</Label>
                  <Textarea
                    id="locationDescription"
                    value={form.locationDescription}
                    onChange={(e) => update("locationDescription", e.target.value)}
                    placeholder="Add a landmark, building name, or floor so deliveries arrive quickly."
                    className="min-h-[110px]"
                  />
                </div>
              </section>

              {role === "pharmacy" && (
                <section className="space-y-4 rounded-2xl border border-border/70 bg-muted/20 p-5">
                  <div>
                    <h2 className="font-display text-lg font-semibold">
                      Superintendent Pharmacist
                    </h2>
                    <p className="mt-1 text-sm text-muted-foreground">
                      These details remain internal for review and compliance checks.
                    </p>
                  </div>

                  <div className="flex items-start gap-3 rounded-xl border border-border bg-background/80 p-4">
                    <Checkbox
                      id="owner-is-superintendent"
                      checked={form.ownerIsSuperintendent}
                      onCheckedChange={(checked) =>
                        setForm((current) => ({
                          ...current,
                          ownerIsSuperintendent: checked === true,
                        }))
                      }
                    />
                    <div className="space-y-1">
                      <Label
                        htmlFor="owner-is-superintendent"
                        className="cursor-pointer text-sm font-medium"
                      >
                        Owner is also the Superintendent Pharmacist
                      </Label>
                      <p className="text-xs text-muted-foreground">
                        When this is on, we auto-fill the superintendent details from the owner
                        section below.
                      </p>
                    </div>
                  </div>

                  <div className="grid gap-4 sm:grid-cols-2">
                    <div className="space-y-2">
                      <Label htmlFor="superintendentName">Full name</Label>
                      <Input
                        id="superintendentName"
                        value={superintendentDetails.name}
                        onChange={(e) => update("superintendentName", e.target.value)}
                        placeholder="Enter the superintendent pharmacist's name"
                        disabled={form.ownerIsSuperintendent}
                        required={!form.ownerIsSuperintendent}
                      />
                    </div>
                    <div className="space-y-2">
                      <Label htmlFor="superintendentPhone">Phone number</Label>
                      <Input
                        id="superintendentPhone"
                        type="tel"
                        value={superintendentDetails.phone}
                        onChange={(e) => update("superintendentPhone", e.target.value)}
                        onBlur={() =>
                          !form.ownerIsSuperintendent && formatPhoneField("superintendentPhone")
                        }
                        placeholder="+233 24 000 0000 or 024 000 0000"
                        disabled={form.ownerIsSuperintendent}
                        required={!form.ownerIsSuperintendent}
                        autoComplete="tel"
                      />
                    </div>
                  </div>

                  <div className="space-y-2">
                    <Label htmlFor="superintendentEmail">Email address</Label>
                    <Input
                      id="superintendentEmail"
                      type="email"
                      value={superintendentDetails.email}
                      onChange={(e) => update("superintendentEmail", e.target.value)}
                      placeholder="superintendent@business.gh"
                      disabled={form.ownerIsSuperintendent}
                      required={!form.ownerIsSuperintendent}
                      autoComplete="email"
                    />
                  </div>
                </section>
              )}

              <section className="space-y-4 rounded-2xl border border-border/70 bg-muted/20 p-5">
                <div>
                  <h2 className="font-display text-lg font-semibold">Owner Details</h2>
                  <p className="mt-1 text-sm text-muted-foreground">
                    This is the account that signs in and manages the workspace.
                  </p>
                </div>

                <div className="grid gap-4 sm:grid-cols-2">
                  <div className="space-y-2">
                    <Label htmlFor="ownerFullName">Owner's full name</Label>
                    <Input
                      id="ownerFullName"
                      value={form.ownerFullName}
                      onChange={(e) => update("ownerFullName", e.target.value)}
                      placeholder="Enter owner's full name"
                      required
                      autoComplete="name"
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="ownerPhone">Owner phone number</Label>
                    <Input
                      id="ownerPhone"
                      type="tel"
                      value={form.ownerPhone}
                      onChange={(e) => update("ownerPhone", e.target.value)}
                      onBlur={() => formatPhoneField("ownerPhone")}
                      placeholder="+233 24 000 0000 or 024 000 0000"
                      required
                      autoComplete="tel"
                    />
                  </div>
                </div>

                <div className="grid gap-4 sm:grid-cols-2">
                  <div className="space-y-2">
                    <Label htmlFor="ownerEmail">Owner email address</Label>
                    <Input
                      id="ownerEmail"
                      type="email"
                      value={form.ownerEmail}
                      onChange={(e) => update("ownerEmail", e.target.value)}
                      placeholder="owner@business.gh"
                      required
                      autoComplete="email"
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="password">Password</Label>
                    <Input
                      id="password"
                      type="password"
                      value={form.password}
                      onChange={(e) => update("password", e.target.value)}
                      placeholder="At least 8 characters"
                      required
                      autoComplete="new-password"
                    />
                  </div>
                </div>
              </section>

              <Button type="submit" variant="hero" size="lg" className="w-full" disabled={loading}>
                {loading ? "Creating account..." : "Create account"}
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
        )}
      </div>
    </div>
  );
}
