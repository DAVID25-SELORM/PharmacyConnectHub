import { createFileRoute, Link } from "@tanstack/react-router";
import { LegalLayout } from "@/components/legal/LegalLayout";

export const Route = createFileRoute("/terms")({
  head: () => ({
    meta: [
      { title: "Terms of Use - Drugxone" },
      { name: "description", content: "The terms for using the Drugxone marketplace." },
    ],
  }),
  component: Terms,
});

function Terms() {
  return (
    <LegalLayout title="Terms of Use">
      <section>
        <h2>Using Drugxone</h2>
        <p>
          By creating an account or using Drugxone you agree to these terms and to our{" "}
          <Link to="/privacy" className="text-primary underline">
            Privacy Notice
          </Link>
          . If you use Drugxone for a business, you confirm you are allowed to act for it.
        </p>
      </section>

      <section>
        <h2>Who can use it</h2>
        <ul>
          <li>
            Pharmacies, hospitals, clinics and wholesalers that hold the licences or registrations
            Ghanaian law requires for what they do.
          </li>
          <li>
            A business can trade only after we have verified its documents. Verification confirms
            the documents look valid on the day we check. It is not a guarantee of the business or
            its products.
          </li>
        </ul>
      </section>

      <section>
        <h2>Your account</h2>
        <ul>
          <li>Give accurate details and keep them up to date.</li>
          <li>
            Keep your password and authenticator app private. Do not share logins; invite staff
            instead.
          </li>
          <li>You are responsible for what happens under your account and by your staff.</li>
          <li>Tell us straight away if you think someone else has used your account.</li>
        </ul>
      </section>

      <section>
        <h2>What Drugxone does and does not do</h2>
        <p>
          Drugxone is a marketplace and set of business tools. Orders, prices, credit terms and
          deliveries are agreed between the buying and selling businesses. We are not a pharmacy or
          wholesaler and we do not sell, store or deliver medicines ourselves.
        </p>
      </section>

      <section>
        <h2>Rules</h2>
        <ul>
          <li>Do not upload false, altered or someone else's licences or documents.</li>
          <li>Do not list or order counterfeit, expired, unregistered or banned products.</li>
          <li>
            Do not misuse the platform, scrape it, or try to get into other businesses' records.
          </li>
          <li>Follow the laws and professional rules that apply to you.</li>
        </ul>
        <p>
          We may suspend or close accounts that break these rules or put others at risk, and we may
          report them to the authorities.
        </p>
      </section>

      <section>
        <h2>Payments and fees</h2>
        <p>
          Where online payment or subscription fees apply, the amounts and terms are shown before
          you confirm. Payments are processed by our payment provider.
        </p>
      </section>

      <section>
        <h2>Your data</h2>
        <p>
          Your business records stay yours. You allow us to store and process them to run the
          service. You can export your own personal data and ask us to delete it as described in the
          Privacy Notice.
        </p>
      </section>

      <section>
        <h2>Availability and responsibility</h2>
        <p>
          We work to keep Drugxone available and accurate, but we cannot promise it will never be
          interrupted or free of errors. To the extent the law allows, we are not responsible for
          losses that come from trades between businesses, from your use of information on the
          platform, or from events outside our reasonable control.
        </p>
      </section>

      <section>
        <h2>Changes and law</h2>
        <p>
          We may update these terms; when we do in a way that matters we will ask you to review them
          when you next sign in. These terms are governed by the laws of Ghana.
        </p>
        <p>
          Questions: <strong>hello@drugxone.com</strong>.
        </p>
      </section>
    </LegalLayout>
  );
}
