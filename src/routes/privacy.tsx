import { createFileRoute, Link } from "@tanstack/react-router";
import { LegalLayout } from "@/components/legal/LegalLayout";

export const Route = createFileRoute("/privacy")({
  head: () => ({
    meta: [
      { title: "Privacy Notice - Drugxone" },
      {
        name: "description",
        content: "How Drugxone collects, uses, protects and deletes personal data.",
      },
    ],
  }),
  component: PrivacyNotice,
});

function PrivacyNotice() {
  return (
    <LegalLayout title="Privacy Notice">
      <section>
        <h2>Who we are</h2>
        <p>
          Drugxone is a business-to-business marketplace in Ghana where pharmacies, hospitals,
          clinics and wholesalers order from each other. This notice explains what personal data we
          hold, why, who sees it, how long we keep it and what you can do about it. It applies under
          the Data Protection Act, 2012 (Act 843).
        </p>
        <p>
          Contact us about your data at <strong>hello@drugxone.com</strong> or on 0247654381, Accra,
          Ghana.
        </p>
      </section>

      <section>
        <h2>What we collect</h2>
        <ul>
          <li>
            <strong>Your account:</strong> name, phone number, email address and your password
            (stored only as a one-way hash that nobody, including our staff, can read).
          </li>
          <li>
            <strong>Your business:</strong> business name, licence number, address and public
            contact details, and the details of the superintendent pharmacist where one is named.
          </li>
          <li>
            <strong>Documents you upload:</strong> licence and registration documents used to verify
            your business, and supporting documents on requests and orders.
          </li>
          <li>
            <strong>What you do on Drugxone:</strong> orders, requests for quotation, stock,
            customers and credit records you enter, payments, and the history of who changed what.
          </li>
          <li>
            <strong>Technical data:</strong> when you last signed in, the network address recorded
            with security-relevant actions, and, if you switch them on, the device used for push
            notifications.
          </li>
        </ul>
      </section>

      <section>
        <h2>Why we use it</h2>
        <table>
          <thead>
            <tr>
              <th>Purpose</th>
              <th>Basis</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>Running your account, orders, requests and payments</td>
              <td>To provide the service you asked for</td>
            </tr>
            <tr>
              <td>Verifying that a business is licensed before it can trade</td>
              <td>Legal and regulatory expectations; protecting patients and members</td>
            </tr>
            <tr>
              <td>Keeping the platform secure, preventing fraud, keeping an audit trail</td>
              <td>Our legitimate interest and legal obligations</td>
            </tr>
            <tr>
              <td>Sending notifications about your orders and account</td>
              <td>To provide the service; you can switch push alerts off</td>
            </tr>
            <tr>
              <td>Keeping financial records</td>
              <td>Legal obligation</td>
            </tr>
          </tbody>
        </table>
        <p>We do not sell your data and we do not use it for advertising.</p>
      </section>

      <section>
        <h2>Who sees it</h2>
        <ul>
          <li>
            <strong>Other businesses</strong> see your business name, location, public contact
            details and verification status, and the details of orders and requests you share with
            them. They do not see your personal phone, email or documents.
          </li>
          <li>
            <strong>Drugxone platform staff</strong> see what they need to verify businesses,
            support you and keep the platform safe. Their actions are recorded in an audit trail.
          </li>
          <li>
            <strong>Service providers</strong> that run the platform for us: Supabase (database,
            sign-in and file storage), Vercel (hosting), Paystack (online payments, where enabled)
            and your browser's push service (Google, Apple or Mozilla) for notifications.
          </li>
          <li>
            <strong>Authorities</strong> where the law requires us to share information.
          </li>
        </ul>
        <p>
          Some providers process data outside Ghana. We use providers that protect data to a
          standard comparable to Ghanaian law and limit what we send them to what they need.
        </p>
      </section>

      <section>
        <h2>How long we keep it</h2>
        <table>
          <thead>
            <tr>
              <th>Data</th>
              <th>Kept for</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>Account details</td>
              <td>While your account is open. After you ask us to delete it, within 30 days.</td>
            </tr>
            <tr>
              <td>Orders, invoices, payments and stock records</td>
              <td>
                As long as the law requires businesses to keep trading records (normally six years).
                After a deletion request they stay, with your name replaced by "Deleted user".
              </td>
            </tr>
            <tr>
              <td>Audit trail of actions</td>
              <td>Kept as the record of what happened; it cannot be edited.</td>
            </tr>
            <tr>
              <td>Push notification devices</td>
              <td>Removed after 90 days without use.</td>
            </tr>
            <tr>
              <td>Notifications in your inbox</td>
              <td>Read ones after about six months; all after a year.</td>
            </tr>
            <tr>
              <td>Your acceptance of this notice and our terms</td>
              <td>Kept as proof of what you agreed to and when.</td>
            </tr>
          </tbody>
        </table>
      </section>

      <section>
        <h2>How we protect it</h2>
        <ul>
          <li>
            Data is encrypted while it travels and while it is stored by our hosting providers.
          </li>
          <li>
            Each business can only see its own records. Licence documents are private to you and the
            platform staff who verify them.
          </li>
          <li>
            You can turn on two-step verification with an authenticator app. Platform staff accounts
            can be required to use it.
          </li>
          <li>Inactive sessions sign out automatically.</li>
        </ul>
      </section>

      <section>
        <h2>Your rights</h2>
        <p>You can ask us to:</p>
        <ul>
          <li>
            <strong>Show you your data.</strong> Download it yourself from{" "}
            <Link to="/security" className="text-primary underline">
              Account security
            </Link>
            .
          </li>
          <li>
            <strong>Correct it.</strong> Most details can be edited in your settings; for the rest
            send a request from the same page.
          </li>
          <li>
            <strong>Delete it.</strong> Send a request from Account security. We reply within 30
            days. We cannot delete records the law requires us to keep, and we cannot remove a
            business owner while the business is still open.
          </li>
          <li>
            <strong>Stop or limit how we use it,</strong> or withdraw consent you gave.
          </li>
        </ul>
        <p>
          If you are unhappy with our answer you can complain to the Data Protection Commission of
          Ghana.
        </p>
      </section>

      <section>
        <h2>Children</h2>
        <p>
          Drugxone is for licensed businesses and their staff. It is not meant for anyone under 18.
        </p>
      </section>

      <section>
        <h2>Changes</h2>
        <p>
          When we change this notice in a way that matters we update the version above and ask you
          to review it the next time you sign in.
        </p>
      </section>
    </LegalLayout>
  );
}
