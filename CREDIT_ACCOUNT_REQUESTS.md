# Ongoing credit account requests

Apply `supabase/migrations/20261017130000_credit_account_requests.sql` before enabling the feature. No pharmacy is enabled automatically.

1. Admin: open the approved pharmacy business card and choose **Enable credit requests**. Select West Point by its verified business record.
2. Pharmacy owners/managers: use **Request an ongoing credit account** in the checkout supplier section. Enter the requested total limit. This also supports limit increases. Requests do not place orders, reserve stock, or create invoices.
3. Wholesaler owners/managers: review requests in **Credit**. Set the approved total limit, payment days, and a reason shared with the pharmacy. Approval creates or updates the ongoing account; rejection leaves existing terms unchanged.
4. Pharmacy: after notification, refresh credit status at checkout, select Credit, and place the order. Checkout rechecks stock, prices, account status and available credit.

Requests expire after seven days. Duplicate pending submissions return the existing request. Disabling eligibility prevents new requests and pending approvals, but does not revoke existing accounts. Suspended/blocked accounts require separate reactivation. Account approval does not accept or submit an order; the cart remains separate until approval.

Validation: `tests/local-supabase/credit-account-requests.sql` runs with rollback in the isolated `credit_review_clean` fixture database. Never run fixture scripts against production.
