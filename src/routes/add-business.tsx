import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { Building2, Store } from "lucide-react";
import { toast } from "sonner";
import { z } from "zod";
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
import { DashboardHeader } from "@/components/DashboardShell";
import { useSession } from "@/hooks/use-session";
import { supabase } from "@/integrations/supabase/client";
import { GH_REGIONS } from "@/lib/format";
import { formatGhanaPhone, isValidGhanaPhone, normalizeGhanaPhone } from "@/lib/ghana-phone";

export const Route = createFileRoute("/add-business")({
  head: () => ({
    meta: [
      { title: "Add a business - Drugxone" },
      { name: "description", content: "Register another pharmacy or wholesaler on your account." },
    ],
  }),
  component: AddBusinessPage,
});

const emailSchema = z.string().trim().email();

type Form = {
  name: string;
  license: string;
  phone: string;
  email: string;
  city: string;
  region: string;
  gps: string;
  hours: string;
  description: string;
  ownerIsSuperintendent: boolean;
  superName: string;
  superPhone: string;
  superEmail: string;
};

const emptyForm: Form = {
  name: "",
  license: "",
  phone: "",
  email: "",
  city: "",
  region: "Greater Accra",
  gps: "",
  hours: "",
  description: "",
  ownerIsSuperintendent: true,
  superName: "",
  superPhone: "",
  superEmail: "",
};

function AddBusinessPage() {
  const navigate = useNavigate();
  const { loading, user, business, businesses, refresh, setActiveBusiness } = useSession();
  const [type, setType] = useState<"pharmacy" | "wholesaler">("pharmacy");
  const [form, setForm] = useState<Form>(emptyForm);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!loading && !user) navigate({ to: "/login" });
  }, [loading, user, navigate]);

  const set = <K extends keyof Form>(key: K, value: Form[K]) =>
    setForm((current) => ({ ...current, [key]: value }));

  const formatPhone = (key: "phone" | "superPhone") => {
    const value = form[key].trim();
    if (value) set(key, formatGhanaPhone(value));
  };

  const onSubmit = async (event: React.FormEvent) => {
    event.preventDefault();

    if (form.name.trim().length < 2) return toast.error("Business name is required");
    if (form.license.trim().length < 3) return toast.error("License number is required");
    if (!isValidGhanaPhone(form.phone)) return toast.error("Enter a valid Ghana phone number");
    if (!emailSchema.safeParse(form.email).success)
      return toast.error("Enter a valid public business email");
    if (form.city.trim().length < 2) return toast.error("City is required");

    const needsSuperintendent = type === "pharmacy" && !form.ownerIsSuperintendent;
    if (needsSuperintendent) {
      if (form.superName.trim().length < 2)
        return toast.error("Superintendent pharmacist name is required");
      if (!isValidGhanaPhone(form.superPhone))
        return toast.error("Enter a valid superintendent pharmacist phone number");
      if (!emailSchema.safeParse(form.superEmail).success)
        return toast.error("Enter a valid superintendent pharmacist email address");
    }

    setSaving(true);
    try {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase as any).rpc("create_additional_business", {
        _type: type,
        _name: form.name.trim(),
        _license_number: form.license.trim(),
        _city: form.city.trim(),
        _region: form.region,
        _phone: normalizeGhanaPhone(form.phone),
        _public_email: form.email.trim().toLowerCase(),
        _address: form.gps.trim() || null,
        _working_hours: form.hours.trim() || null,
        _location_description: form.description.trim() || null,
        _owner_is_superintendent: type === "pharmacy" ? form.ownerIsSuperintendent : true,
        _superintendent_name: needsSuperintendent ? form.superName.trim() : null,
        _superintendent_phone: needsSuperintendent ? normalizeGhanaPhone(form.superPhone) : null,
        _superintendent_email: needsSuperintendent ? form.superEmail.trim().toLowerCase() : null,
      });

      if (error) {
        // Rule messages raised by the function (SQLSTATE P0001) are written for users.
        toast.error(
          error.code === "P0001" && error.message
            ? error.message
            : "We could not add this business right now. Please try again.",
        );
        return;
      }

      await refresh();
      if (typeof data === "string") setActiveBusiness(data);
      toast.success("Business added. Upload its documents to start verification.");
      navigate({ to: "/onboarding" });
    } finally {
      setSaving(false);
    }
  };

  const isPharmacy = type === "pharmacy";

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="Add a business" />
      <main className="mx-auto max-w-3xl px-4 py-8 sm:px-6 lg:px-8">
        <h1 className="font-display text-3xl font-bold">Add another business</h1>
        <p className="mt-2 text-muted-foreground">
          Register a second pharmacy or wholesaler under this login. Each business is verified
          separately, and you can switch between them from the workspace menu.
        </p>

        <Card className="mt-6 p-6">
          <div className="grid grid-cols-2 gap-2 rounded-xl bg-muted p-1">
            {(["pharmacy", "wholesaler"] as const).map((option) => (
              <button
                key={option}
                type="button"
                onClick={() => setType(option)}
                className={`flex items-center justify-center gap-2 rounded-lg px-3 py-2 text-sm font-medium capitalize transition-all ${
                  type === option
                    ? "bg-surface text-foreground shadow-soft"
                    : "text-muted-foreground hover:text-foreground"
                }`}
              >
                {option === "pharmacy" ? (
                  <Store className="h-4 w-4" />
                ) : (
                  <Building2 className="h-4 w-4" />
                )}
                {option}
              </button>
            ))}
          </div>

          <form className="mt-6 space-y-4" onSubmit={onSubmit}>
            <div className="grid gap-4 sm:grid-cols-2">
              <div className="space-y-2">
                <Label htmlFor="ab-name">
                  {isPharmacy ? "Pharmacy name" : "Wholesale company name"}
                </Label>
                <Input
                  id="ab-name"
                  value={form.name}
                  onChange={(e) => set("name", e.target.value)}
                  required
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="ab-license">
                  {isPharmacy ? "Pharmacy Council license #" : "Business license / registration #"}
                </Label>
                <Input
                  id="ab-license"
                  value={form.license}
                  onChange={(e) => set("license", e.target.value)}
                  required
                />
              </div>
            </div>

            <div className="grid gap-4 sm:grid-cols-2">
              <div className="space-y-2">
                <Label htmlFor="ab-phone">Business phone (public)</Label>
                <Input
                  id="ab-phone"
                  type="tel"
                  value={form.phone}
                  onChange={(e) => set("phone", e.target.value)}
                  onBlur={() => formatPhone("phone")}
                  placeholder="+233 24 000 0000 or 024 000 0000"
                  required
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="ab-email">Business email (public)</Label>
                <Input
                  id="ab-email"
                  type="email"
                  value={form.email}
                  onChange={(e) => set("email", e.target.value)}
                  required
                />
              </div>
            </div>

            <div className="grid gap-4 sm:grid-cols-2">
              <div className="space-y-2">
                <Label htmlFor="ab-city">City</Label>
                <Input
                  id="ab-city"
                  value={form.city}
                  onChange={(e) => set("city", e.target.value)}
                  required
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="ab-region">Region</Label>
                <Select value={form.region} onValueChange={(value) => set("region", value)}>
                  <SelectTrigger id="ab-region">
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
                <Label htmlFor="ab-gps">GPS address</Label>
                <Input id="ab-gps" value={form.gps} onChange={(e) => set("gps", e.target.value)} />
              </div>
              <div className="space-y-2">
                <Label htmlFor="ab-hours">Working hours</Label>
                <Input
                  id="ab-hours"
                  value={form.hours}
                  onChange={(e) => set("hours", e.target.value)}
                />
              </div>
            </div>

            <div className="space-y-2">
              <Label htmlFor="ab-desc">Exact location description</Label>
              <Textarea
                id="ab-desc"
                value={form.description}
                onChange={(e) => set("description", e.target.value)}
              />
            </div>

            {isPharmacy && (
              <div className="space-y-4 rounded-xl border border-border/70 bg-muted/20 p-4">
                <div className="flex items-start gap-3">
                  <Checkbox
                    id="ab-owner-super"
                    checked={form.ownerIsSuperintendent}
                    onCheckedChange={(checked) => set("ownerIsSuperintendent", checked === true)}
                  />
                  <Label htmlFor="ab-owner-super" className="cursor-pointer text-sm font-medium">
                    I am also the Superintendent Pharmacist
                  </Label>
                </div>
                {!form.ownerIsSuperintendent && (
                  <div className="grid gap-4 sm:grid-cols-2">
                    <div className="space-y-2">
                      <Label htmlFor="ab-super-name">Superintendent full name</Label>
                      <Input
                        id="ab-super-name"
                        value={form.superName}
                        onChange={(e) => set("superName", e.target.value)}
                      />
                    </div>
                    <div className="space-y-2">
                      <Label htmlFor="ab-super-phone">Superintendent phone</Label>
                      <Input
                        id="ab-super-phone"
                        type="tel"
                        value={form.superPhone}
                        onChange={(e) => set("superPhone", e.target.value)}
                        onBlur={() => formatPhone("superPhone")}
                      />
                    </div>
                    <div className="space-y-2 sm:col-span-2">
                      <Label htmlFor="ab-super-email">Superintendent email</Label>
                      <Input
                        id="ab-super-email"
                        type="email"
                        value={form.superEmail}
                        onChange={(e) => set("superEmail", e.target.value)}
                      />
                    </div>
                  </div>
                )}
              </div>
            )}

            <div className="flex items-center justify-between pt-2">
              <Link
                to={business || businesses.length > 0 ? "/dashboard" : "/onboarding"}
                className="text-sm text-muted-foreground hover:text-foreground"
              >
                Cancel
              </Link>
              <Button type="submit" variant="hero" disabled={saving}>
                {saving ? "Adding..." : "Add business"}
              </Button>
            </div>
          </form>
        </Card>
      </main>
    </div>
  );
}
