import { createFileRoute, Link } from "@tanstack/react-router";
import { motion } from "framer-motion";
import {
  ArrowRight,
  ShieldCheck,
  Truck,
  Search,
  Wallet,
  Building2,
  Pill,
  Sparkles,
  CheckCircle2,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { SiteHeader } from "@/components/SiteHeader";
import { SiteFooter } from "@/components/SiteFooter";
import heroImage from "@/assets/hero-pharma.jpg";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "PharmaHub GH — B2B Pharmaceutical Marketplace for Ghana" },
      {
        name: "description",
        content:
          "Connect retail pharmacies with verified pharmaceutical wholesalers across Ghana. Browse, compare, and order medicines in one place.",
      },
      { property: "og:title", content: "PharmaHub GH — B2B Pharmaceutical Marketplace" },
      {
        property: "og:description",
        content: "Ghana's trusted multi-wholesaler pharma marketplace.",
      },
    ],
  }),
  component: LandingPage,
});

function LandingPage() {
  return (
    <div className="min-h-screen bg-background">
      <SiteHeader />
      <main>
        <Hero />
        <TrustBar />
        <Features />
        <HowItWorks />
        <DualCTA />
      </main>
      <SiteFooter />
    </div>
  );
}

function Hero() {
  return (
    <section className="relative overflow-hidden bg-gradient-soft">
      <div className="absolute inset-0 -z-10">
        <div className="absolute right-0 top-20 h-72 w-72 rounded-full bg-primary/10 blur-3xl" />
        <div className="absolute left-10 bottom-10 h-72 w-72 rounded-full bg-accent/15 blur-3xl" />
      </div>
      <div className="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 pt-16 pb-20 lg:pt-24 lg:pb-32">
        <div className="grid items-center gap-12 lg:grid-cols-2">
          <motion.div
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6 }}
          >
            <div className="inline-flex items-center gap-2 rounded-full border border-border bg-surface px-3 py-1 text-xs font-medium text-muted-foreground shadow-soft">
              <Sparkles className="h-3.5 w-3.5 text-accent" />
              Built for Ghana's pharma supply chain
            </div>
            <h1 className="mt-6 font-display text-4xl font-bold leading-[1.05] tracking-tight sm:text-5xl lg:text-6xl">
              The marketplace where{" "}
              <span className="text-gradient-hero">pharmacies meet wholesalers</span>.
            </h1>
            <p className="mt-6 max-w-xl text-lg text-muted-foreground">
              Browse thousands of medicines from verified wholesalers across Ghana, compare prices
              instantly, and place orders in minutes — not phone calls.
            </p>
            <div className="mt-8 flex flex-wrap items-center gap-3">
              <Button asChild variant="hero" size="xl">
                <Link to="/pharmacy">
                  I'm a pharmacy <ArrowRight className="h-4 w-4" />
                </Link>
              </Button>
              <Button asChild variant="outline" size="xl">
                <Link to="/wholesaler">
                  I'm a wholesaler
                </Link>
              </Button>
            </div>
            <div className="mt-8 flex flex-wrap items-center gap-x-6 gap-y-2 text-sm text-muted-foreground">
              <div className="flex items-center gap-2">
                <CheckCircle2 className="h-4 w-4 text-success" /> FDA-verified suppliers
              </div>
              <div className="flex items-center gap-2">
                <CheckCircle2 className="h-4 w-4 text-success" /> Same-day dispatch in Accra
              </div>
            </div>
          </motion.div>

          <motion.div
            initial={{ opacity: 0, scale: 0.95 }}
            animate={{ opacity: 1, scale: 1 }}
            transition={{ duration: 0.7, delay: 0.1 }}
            className="relative"
          >
            <div className="relative overflow-hidden rounded-3xl shadow-elegant ring-1 ring-border">
              <img
                src={heroImage}
                alt="Pharmaceutical products on display"
                width={1536}
                height={1024}
                className="h-full w-full object-cover"
              />
            </div>
            <FloatingCard
              className="absolute -left-4 top-8 sm:-left-8"
              icon={<ShieldCheck className="h-5 w-5 text-success" />}
              title="Verified"
              subtitle="240+ wholesalers"
              delay={0.4}
            />
            <FloatingCard
              className="absolute -right-4 bottom-8 sm:-right-6"
              icon={<Truck className="h-5 w-5 text-accent" />}
              title="Fast delivery"
              subtitle="Avg. 6 hours"
              delay={0.6}
            />
          </motion.div>
        </div>
      </div>
    </section>
  );
}

function FloatingCard({
  className,
  icon,
  title,
  subtitle,
  delay,
}: {
  className?: string;
  icon: React.ReactNode;
  title: string;
  subtitle: string;
  delay: number;
}) {
  return (
    <motion.div
      initial={{ opacity: 0, y: 10 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.5, delay }}
      className={`flex items-center gap-3 rounded-2xl bg-surface px-4 py-3 shadow-elegant ring-1 ring-border ${className ?? ""}`}
    >
      <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-muted">{icon}</div>
      <div>
        <div className="text-sm font-semibold">{title}</div>
        <div className="text-xs text-muted-foreground">{subtitle}</div>
      </div>
    </motion.div>
  );
}

function TrustBar() {
  const items = [
    { value: "240+", label: "Verified wholesalers" },
    { value: "12k+", label: "SKUs available" },
    { value: "98%", label: "On-time delivery" },
    { value: "16 regions", label: "Nationwide coverage" },
  ];
  return (
    <section className="border-y border-border bg-surface">
      <div className="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 py-10">
        <div className="grid grid-cols-2 gap-6 md:grid-cols-4">
          {items.map((it) => (
            <div key={it.label} className="text-center">
              <div className="font-display text-3xl font-bold text-primary">{it.value}</div>
              <div className="mt-1 text-xs uppercase tracking-wider text-muted-foreground">
                {it.label}
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

function Features() {
  const features = [
    {
      icon: Search,
      title: "Compare across wholesalers",
      desc: "See prices, stock and ratings from multiple verified suppliers in one search.",
    },
    {
      icon: ShieldCheck,
      title: "Verified & authentic",
      desc: "Every wholesaler is FDA-registered. Avoid counterfeits, protect your patients.",
    },
    {
      icon: Wallet,
      title: "Smart procurement",
      desc: "Pick the best price, save your reorder lists, and track every spend.",
    },
    {
      icon: Truck,
      title: "Fast, tracked delivery",
      desc: "Same-day dispatch in major cities, with full status tracking end-to-end.",
    },
  ];
  return (
    <section className="py-20 lg:py-28">
      <div className="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8">
        <div className="mx-auto max-w-2xl text-center">
          <h2 className="font-display text-3xl font-bold sm:text-4xl">
            Built for the way pharmacies actually buy
          </h2>
          <p className="mt-4 text-muted-foreground">
            Stop juggling WhatsApp orders and scattered price lists. PharmaHub brings the
            wholesale catalog into one clean workspace.
          </p>
        </div>
        <div className="mt-14 grid gap-6 sm:grid-cols-2 lg:grid-cols-4">
          {features.map((f, i) => (
            <motion.div
              key={f.title}
              initial={{ opacity: 0, y: 16 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true }}
              transition={{ duration: 0.4, delay: i * 0.08 }}
            >
              <Card className="h-full border-border p-6 transition-all hover:shadow-elegant hover:-translate-y-1">
                <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-primary/10 text-primary">
                  <f.icon className="h-5 w-5" />
                </div>
                <h3 className="mt-5 font-display text-lg font-semibold">{f.title}</h3>
                <p className="mt-2 text-sm text-muted-foreground">{f.desc}</p>
              </Card>
            </motion.div>
          ))}
        </div>
      </div>
    </section>
  );
}

function HowItWorks() {
  const steps = [
    {
      num: "01",
      title: "Sign up & verify",
      desc: "Create your pharmacy or wholesaler account. We verify your license once.",
    },
    {
      num: "02",
      title: "Browse or list",
      desc: "Pharmacies search the unified catalog. Wholesalers list products and stock.",
    },
    {
      num: "03",
      title: "Order & fulfil",
      desc: "Pharmacies place orders. Wholesalers receive, process and dispatch.",
    },
  ];
  return (
    <section className="bg-gradient-soft py-20 lg:py-28">
      <div className="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8">
        <div className="mx-auto max-w-2xl text-center">
          <h2 className="font-display text-3xl font-bold sm:text-4xl">How it works</h2>
          <p className="mt-4 text-muted-foreground">
            From signup to dispatch in three simple steps.
          </p>
        </div>
        <div className="mt-14 grid gap-6 md:grid-cols-3">
          {steps.map((s) => (
            <Card key={s.num} className="relative overflow-hidden border-border p-7">
              <div className="font-display text-5xl font-bold text-primary/15">{s.num}</div>
              <h3 className="mt-3 font-display text-xl font-semibold">{s.title}</h3>
              <p className="mt-2 text-sm text-muted-foreground">{s.desc}</p>
            </Card>
          ))}
        </div>
      </div>
    </section>
  );
}

function DualCTA() {
  return (
    <section className="py-20 lg:py-28">
      <div className="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8">
        <div className="grid gap-6 md:grid-cols-2">
          <Card className="relative overflow-hidden bg-gradient-hero p-10 text-primary-foreground">
            <Pill className="absolute -right-6 -top-6 h-32 w-32 opacity-15" />
            <div className="relative">
              <div className="inline-flex items-center gap-2 rounded-full bg-white/15 px-3 py-1 text-xs font-medium">
                For Pharmacies
              </div>
              <h3 className="mt-5 font-display text-2xl font-bold sm:text-3xl">
                Order smarter. Stock better.
              </h3>
              <p className="mt-3 max-w-md text-primary-foreground/80">
                Compare prices across all our wholesalers and place orders in minutes.
              </p>
              <Button asChild variant="warm" size="lg" className="mt-6">
                <Link to="/pharmacy">
                  Open pharmacy demo <ArrowRight className="h-4 w-4" />
                </Link>
              </Button>
            </div>
          </Card>
          <Card className="relative overflow-hidden bg-surface-muted p-10">
            <Building2 className="absolute -right-6 -top-6 h-32 w-32 opacity-10 text-primary" />
            <div className="relative">
              <div className="inline-flex items-center gap-2 rounded-full bg-primary/10 px-3 py-1 text-xs font-medium text-primary">
                For Wholesalers
              </div>
              <h3 className="mt-5 font-display text-2xl font-bold sm:text-3xl">
                Reach 1,000s of pharmacies.
              </h3>
              <p className="mt-3 max-w-md text-muted-foreground">
                List your inventory, receive digital orders, and manage fulfilment in one place.
              </p>
              <Button asChild variant="hero" size="lg" className="mt-6">
                <Link to="/wholesaler">
                  Open wholesaler demo <ArrowRight className="h-4 w-4" />
                </Link>
              </Button>
            </div>
          </Card>
        </div>
      </div>
    </section>
  );
}
