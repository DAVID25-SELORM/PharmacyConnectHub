import { Link } from "@tanstack/react-router";
import { Pill } from "lucide-react";

export function SiteFooter() {
  return (
    <footer className="border-t border-border bg-surface-muted">
      <div className="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 py-12">
        <div className="grid gap-8 md:grid-cols-4">
          <div className="md:col-span-2">
            <Link to="/" className="flex items-center gap-2">
              <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-gradient-hero">
                <Pill className="h-4 w-4 text-primary-foreground" />
              </div>
              <span className="font-display font-bold">PharmaHub GH</span>
            </Link>
            <p className="mt-3 max-w-md text-sm text-muted-foreground">
              Ghana's trusted B2B pharmaceutical marketplace. Connecting retail pharmacies with
              verified wholesalers for faster, smarter procurement.
            </p>
          </div>
          <div>
            <h4 className="font-semibold text-sm">Platform</h4>
            <ul className="mt-3 space-y-2 text-sm text-muted-foreground">
              <li>
                <Link to="/pharmacy" className="hover:text-foreground">
                  For Pharmacies
                </Link>
              </li>
              <li>
                <Link to="/wholesaler" className="hover:text-foreground">
                  For Wholesalers
                </Link>
              </li>
              <li>
                <Link to="/signup" className="hover:text-foreground">
                  Get started
                </Link>
              </li>
            </ul>
          </div>
          <div>
            <h4 className="font-semibold text-sm">Company</h4>
            <ul className="mt-3 space-y-2 text-sm text-muted-foreground">
              <li>Accra, Ghana</li>
              <li>hello@pharmahub.gh</li>
              <li>+233 20 000 0000</li>
            </ul>
          </div>
        </div>
        <div className="mt-10 border-t border-border pt-6 text-xs text-muted-foreground">
          © {new Date().getFullYear()} PharmaHub GH. All rights reserved.
        </div>
      </div>
    </footer>
  );
}
