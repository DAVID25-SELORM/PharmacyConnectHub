import { createFileRoute, Link } from "@tanstack/react-router";
import { Search, Mail, Phone, ArrowLeft } from "lucide-react";
import { useMemo, useState } from "react";
import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from "@/components/ui/accordion";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { SiteHeader } from "@/components/SiteHeader";
import { SiteFooter } from "@/components/SiteFooter";
import { helpCategories, helpFaqs, type HelpCategory, type HelpRole } from "@/lib/help-faq";
import { useSession } from "@/hooks/use-session";

export const Route = createFileRoute("/help")({ component: HelpCentre });

function HelpCentre() {
  const { business } = useSession();
  const role = business?.type === "pharmacy" || business?.type === "wholesaler" ? business.type : null;
  const requestedCategory = typeof window === "undefined" ? null : new URLSearchParams(window.location.search).get("category");
  const initialCategory = helpCategories.some((item) => item.id === requestedCategory) ? requestedCategory as HelpCategory : "all";
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState<HelpCategory | "all">(initialCategory);
  const filtered = useMemo(() => {
    const term = query.trim().toLowerCase();
    return helpFaqs.filter((faq) => {
      const roleMatch = !role || faq.roles.includes("all") || faq.roles.includes(role as HelpRole);
      const categoryMatch = category === "all" || faq.category === category;
      const text = `${faq.question} ${faq.answer} ${faq.keywords.join(" ")}`.toLowerCase();
      return roleMatch && categoryMatch && (!term || text.includes(term));
    });
  }, [category, query, role]);

  return (
    <div className="min-h-screen bg-background">
      <SiteHeader />
      <main className="mx-auto max-w-4xl px-4 py-12 sm:px-6 lg:px-8">
        <Link to="/" className="mb-6 inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground"><ArrowLeft className="h-4 w-4" /> Back to Drugxone</Link>
        <div className="text-center">
          <p className="text-sm font-semibold uppercase tracking-[0.18em] text-primary">Support</p>
          <h1 className="mt-2 font-display text-4xl font-bold">Help Centre</h1>
          <p className="mx-auto mt-3 max-w-2xl text-muted-foreground">Quick answers about ordering, payments, receipts, inventory and fulfilment.</p>
        </div>
        <div className="relative mx-auto mt-8 max-w-2xl">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input aria-label="Search for help" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search for help..." className="h-12 pl-10" />
        </div>
        <div className="mt-8 flex gap-2 overflow-x-auto pb-2" role="tablist" aria-label="Help categories">
          <Button size="sm" variant={category === "all" ? "secondary" : "ghost"} onClick={() => setCategory("all")}>All</Button>
          {helpCategories.map((item) => <Button key={item.id} size="sm" variant={category === item.id ? "secondary" : "ghost"} onClick={() => setCategory(item.id)}>{item.label}</Button>)}
        </div>
        <Card className="mt-4 px-5">
          {filtered.length ? <Accordion type="single" collapsible>{filtered.map((faq) => <AccordionItem value={faq.id} key={faq.id}><AccordionTrigger>{faq.question}</AccordionTrigger><AccordionContent className="text-muted-foreground">{faq.answer}</AccordionContent></AccordionItem>)}</Accordion> : <p className="py-10 text-center text-muted-foreground">No help articles match your search.</p>}
        </Card>
        <Card className="mt-8 flex flex-col items-start justify-between gap-4 p-6 sm:flex-row sm:items-center">
          <div><h2 className="font-display text-xl font-bold">Still need help?</h2><p className="mt-1 text-sm text-muted-foreground">Contact the Drugxone support team and include your order reference if relevant.</p></div>
          <div className="flex flex-wrap gap-2"><Button asChild variant="outline"><a href="mailto:hello@drugxone.com"><Mail className="mr-2 h-4 w-4" /> Email Support</a></Button><Button asChild variant="outline"><a href="tel:0247654381"><Phone className="mr-2 h-4 w-4" /> Call Support</a></Button></div>
        </Card>
      </main>
      <SiteFooter />
    </div>
  );
}
