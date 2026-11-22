# Drugxone: data protection and privacy

How personal data is handled in the Drugxone marketplace (this repository, Supabase project
`ywpntuioeqpreouauuir`). The NHIS pharmacy system (HealthFlow) is a separate product with its own
document, `docs/data-protection-and-privacy.md` in that repository.

Written for the owner and a legal adviser. Items marked **Decision** need the owner (and, where noted,
a legal adviser) before they can be treated as final.

## 1. What personal data is held

| Data | Where | Who can read it |
| --- | --- | --- |
| Email, password hash, sign-in times, authenticator app | Supabase Auth (`auth.users`, `auth.mfa_factors`) | The person; nobody can read the password. Platform admins see the email. |
| Name, phone | `profiles` | The person; platform admins through admin screens |
| Business identity, licence number, address, public contacts | `businesses` | The business's staff; other approved businesses see the public fields |
| Owner and superintendent name, phone, email | `business_private_contacts` | The owner; platform admins |
| Licence and registration documents | Storage bucket `licenses` (private) | The owner and platform admins, by 5-minute signed link |
| RFQ evidence, procurement documents | Buckets `rfq-evidence`, `external-procurement` (private) | The parties to the request |
| Staff membership, role | `business_staff`, `user_roles`, `platform_staff` | The business owner and managers; platform admins |
| Push notification device | `push_subscriptions` | The person (their own); the server sends to it |
| Notifications | `notifications` | The person |
| Who did what, when, from which network address | `audit_logs` (immutable) | Platform admins |
| Acceptance of Privacy Notice and Terms | `consent_records` | The person; recorded by the server only |
| Privacy requests | `data_requests` | The person; platform admins |

Business records (orders, invoices, stock, credit) belong to the business, not to one person.

## 2. Controls in place

**Passwords.** Stored only by Supabase Auth as a one-way hash. New passwords must be 10-72 characters,
not a common password, not built from the person's email or name, and not a keyboard or number sequence
(`src/lib/password-policy.ts`). Signing in never applies the rule, so older accounts keep working until
their owner changes the password.

**Two-step verification (authenticator app).** Anyone can turn it on at **Security**. Once on, the
code is asked after the password and again before any private page if the session has not entered it.
For **platform admins** the database can enforce it: a platform setting (off by default) makes
`has_role(..., 'admin')` false for any session below assurance level `aal2`, and the server-side API
handlers for payments (refund, payout, re-verify), platform staff and admin staff edits check the same
rule. An admin can only switch it on once every admin has an authenticator app.

*Limit:* for ordinary business users two-step verification is enforced by the screens, not by the
database. Someone holding a stolen password could bypass the screen by calling the data API directly,
so it protects against casual and credential-reuse attacks, not a determined attacker with the password.
Enforcing it in the database for business data would mean adding a restrictive rule to every table and
is a separate piece of work. **Decision:** whether to do it for the most sensitive tables.

**Sessions.** Automatic sign-out after 1 hour of no activity (15 minutes for platform admins) with a
2-minute warning. People can end other sessions or all sessions at **Security**.
*Limit:* the sign-in token is kept in the browser's `localStorage` (Supabase's standard for a single-page
app). The page's Content-Security-Policy blocks inline and third-party scripts, which is the main
defence. Moving the token to an HttpOnly cookie needs a server-side session layer and is not done.

**Access to data.** Row Level Security on every table; each business sees only its own rows. Admin
actions go through audited functions. The service-role key is only used in server code (`api/`).

**Uploads.** Only PDF, JPEG, PNG and WebP up to 10 MB. The app checks the file's real first bytes (not its
name or the type the browser claims), refuses names that look like programs or web pages, refuses PDFs that
contain scripts, launch actions or embedded files, and re-draws unusual or oversized photos as JPEG. The
storage buckets repeat the type and size limits. *Limit:* this is **not an antivirus**. A PDF can hide active
content inside compressed data, and there is no malware engine scanning files. **Decision:** whether to
add a scanning service (see section 5).

**Audit trail.** Immutable. Records who did what and from which network address. Secret-looking keys
(`password`, `token`, `secret`, `api_key`, ...) are redacted before the log leaves the database.

## 3. Retention

| Data | Kept for | How it is removed |
| --- | --- | --- |
| Account and profile | While the account is open | Privacy request, then "Remove this person" (within 30 days) |
| Orders, invoices, payments, stock records | As long as the law requires trading records to be kept (normally 6 years). **Decision:** confirm the period with a legal adviser | Not removed on a deletion request; the person's name becomes "Deleted user" |
| Audit trail | Kept as the legal record; cannot be edited. **Decision:** set an overall period | Not removed |
| Licence documents | While the business is registered | By an admin when a business is closed. **Decision:** how long to keep them after closure |
| Push devices | 90 days without use | Nightly clean-up (`run_data_retention`) |
| Notifications | Read: 180 days. All: 1 year | Nightly clean-up |
| Consent records | Kept as proof of acceptance | Not removed |
| Privacy requests | Kept as proof of the reply | Contact address blanked once the person is removed |

The nightly clean-up must be scheduled once (`docs/security-to-apply/schedule-data-retention.sql`).

## 4. Requests from people

People use **Security > Your data**:

- **Download my data** is instant: a JSON file with their account, profile, businesses they own, staff
  memberships, consent history and privacy requests.
- **Delete my data** creates a request with a 30-day deadline and notifies the platform admins.

Admins work the queue at **Admin > Privacy**:

1. *Start handling* (optional).
2. **Remove this person** deletes their sign-in, sessions, authenticator apps and linked identities; clears
   name and phone; switches off their staff access; removes devices and notifications; and closes the
   request. Orders, invoices and the audit trail stay under "Deleted user".
   It refuses while the person **owns a business** (hand it over or close it first), or is **platform staff**.
3. **Decline with reason** if the law requires the data to be kept; the reason is shown to the person.

*Limit:* audit log rows keep the email and network address recorded at the time, because the log is
immutable. This is a deliberate legal-record exception and should be stated in the privacy notice
(it is, in general terms).

## 5. Decisions for the owner

1. **Legal entity and registration.** The Privacy Notice and Terms were written from how the system works
   and need review by a legal adviser. Confirm the entity that is the data controller, whether it must be
   registered with the Data Protection Commission under Act 843, and the contact details shown.
2. **Retention periods** in section 3.
3. **Antivirus scanning of uploads.** Options: (a) a scanning API called when a document is uploaded
   (VirusTotal, Cloudmersive or similar: needs a key and sends the file to a third party, which the
   privacy notice would have to name); (b) a self-hosted ClamAV service (needs a small server);
   (c) accept the current checks. Documents are only opened by admins and the owner today.
4. **Database enforcement of two-step verification** for business users (section 2).
5. **Processing agreements** with Supabase, Vercel and Paystack, and where their data is hosted.

## 6. If personal data may have been exposed

1. Contain it: revoke exposed keys (Supabase service-role key, API keys), sign users out
   (Supabase: Authentication > Users, or rotate the JWT secret).
2. Find what was reached using the audit trail and Supabase logs.
3. Notify the Data Protection Commission and the affected people as the law requires, as soon as the scope is known.
4. Record what happened and what was changed.
