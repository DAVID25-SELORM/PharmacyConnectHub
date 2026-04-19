# Smoke Test Playbook

Use this checklist after applying the current migrations to a live Supabase project.
It verifies the flows that matter most for production readiness:

- signup bootstraps a business automatically
- onboarding document upload works
- admin approval updates verification state
- pharmacy users can see and choose approved wholesalers
- orders can be placed and fulfilled
- notifications are created and shown in the app

## Preconditions

- Apply the migrations listed in [SETUP.md](./SETUP.md).
- Set `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY`.
- Have one working admin account.
- Prepare two fresh test email addresses:
  - one wholesaler account
  - one pharmacy account
- Prepare small test files for onboarding uploads:
  - PDF, JPG, or PNG
  - under 10 MB each

## Useful SQL Checks

Run these in the Supabase SQL editor during the test.

```sql
select id, owner_id, type, name, verification_status, created_at
from public.businesses
order by created_at desc
limit 20;
```

```sql
select id, order_number, pharmacy_id, wholesaler_id, status, total_ghs, created_at
from public.orders
order by created_at desc
limit 20;
```

```sql
select id, user_id, type, title, body, read, metadata, created_at
from public.notifications
order by created_at desc
limit 30;
```

```sql
select user_id, role
from public.user_roles
where role = 'admin';
```

## 1. Wholesaler Signup Bootstrap

1. Open `/signup`.
2. Choose `Wholesaler`.
3. Submit the form with a unique business name and email.
4. If email confirmation is enabled, confirm the email and then sign in.
5. Open `/dashboard`.

Expected result:

- signup succeeds without a client-side insert into `public.businesses`
- the user lands in a valid workspace after sign-in
- `/dashboard` shows the wholesaler workspace or redirects to onboarding cleanly

SQL verification:

```sql
select id, owner_id, type, name, verification_status
from public.businesses
where name = '<WHOLESALER_BUSINESS_NAME>';
```

Pass if:

- exactly one `public.businesses` row exists
- `type = 'wholesaler'`
- `verification_status = 'pending'`

## 2. Wholesaler Onboarding Upload

1. While signed in as the wholesaler, open `/onboarding`.
2. Upload all required documents:
   - `Wholesale Pharmacy License`
   - `FDA Certificate`
   - `Business Registration`
3. Click `Continue to dashboard`.

Expected result:

- the page shows `Verify your business`
- each upload shows `Document uploaded`
- uploaded rows appear in the required-documents list
- status remains `pending` until admin review

## 3. Admin Approval For Wholesaler

1. Sign in as an admin user.
2. Open `/admin`.
3. Find the pending wholesaler business.
4. Approve it.

Expected result:

- admin sees the business move out of the pending state
- the wholesaler business becomes `approved`
- a notification row is created for the wholesaler owner

SQL verification:

```sql
select type, title, body, user_id, created_at
from public.notifications
where type = 'business_approved'
order by created_at desc
limit 10;
```

Pass if the newest row has:

- `type = 'business_approved'`
- `title = 'Application approved'`
- the correct wholesaler owner's `user_id`

## 4. Wholesaler Product Setup

1. Sign back in as the approved wholesaler.
2. Open `/dashboard`.
3. Go to `My products`.
4. Click `Add product`.
5. Create at least one active product with stock and a price.

Suggested sample:

- Name: `Amoxicillin 500mg`
- Category: `Antibiotics`
- Form: `Capsule`
- Pack size: `100s`
- Price: `12.50`
- Stock: `250`

Expected result:

- the product appears in the products table
- `My products` count increases
- the wholesaler can now appear in the pharmacy marketplace

## 5. Pharmacy Signup Bootstrap

1. Open `/signup`.
2. Choose `Pharmacy`.
3. Submit the form with a unique business name and email.
4. If email confirmation is enabled, confirm the email and sign in.
5. Open `/dashboard`.

Expected result:

- exactly one pharmacy business is created automatically
- the pharmacy can open onboarding without any missing-business error

SQL verification:

```sql
select id, owner_id, type, name, verification_status
from public.businesses
where name = '<PHARMACY_BUSINESS_NAME>';
```

Pass if:

- exactly one `public.businesses` row exists
- `type = 'pharmacy'`
- `verification_status = 'pending'`

## 6. Pharmacy Onboarding And Approval

1. While signed in as the pharmacy, open `/onboarding`.
2. Upload:
   - `Pharmacy Council License`
   - `Business Registration`
3. Sign in as admin and approve the pharmacy in `/admin`.

Expected result:

- pharmacy status changes from `pending` to `approved`
- the pharmacy owner receives a `business_approved` notification

## 7. Pharmacy Catalog And Wholesaler Selection

1. Sign in as the approved pharmacy.
2. Open `/dashboard`.
3. Stay on the `Catalog` tab.
4. Confirm the supplier directory is visible.
5. Click `View products` on the approved wholesaler card.
6. Use `Show all wholesalers` to clear the filter.
7. Use the wholesaler dropdown and verify the catalog filters correctly.

Expected result:

- the header shows the approved wholesaler count
- the `Catalog` tab label includes the wholesaler count
- the page shows `Choose a wholesaler`
- supplier cards show location, product count, category count, stock, and starting price
- filtering reduces the catalog to the chosen wholesaler
- clearing the filter restores the full approved marketplace

If there is exactly one approved wholesaler with active products, the page should behave like:

- `1 approved wholesaler is available for comparison right now.`
- `Showing <N> products from 1 wholesaler.`

## 8. Place An Order

1. While signed in as the pharmacy, add at least one item to cart.
2. Open the cart.
3. Verify the cart groups items by wholesaler.
4. Verify the payment line shows `Cash on delivery`.
5. Click `Place order`.

Expected result:

- checkout succeeds
- one order is created per wholesaler group in the cart
- the wholesaler owner receives a new order notification

SQL verification:

```sql
select order_number, status, pharmacy_id, wholesaler_id, total_ghs, created_at
from public.orders
order by created_at desc
limit 10;
```

```sql
select type, title, body, metadata, created_at
from public.notifications
where type = 'new_order'
order by created_at desc
limit 10;
```

Pass if:

- a new order row exists with `status = 'pending'`
- the wholesaler notification has `type = 'new_order'`
- the notification title is `New order received`

## 9. Wholesaler Fulfilment And Pharmacy Notifications

1. Sign in as the wholesaler.
2. Open `/dashboard`.
3. In `Incoming orders`, open the newest order.
4. Click the order actions in sequence:
   - `Accept order`
   - `Mark packed`
   - `Mark dispatched`
   - `Mark delivered`
5. After each update, sign in as the pharmacy and check `My orders`.

Expected result:

- the wholesaler can move the order through the workflow
- the pharmacy sees the status timeline update
- each status change creates an `order_status` notification for the pharmacy owner

SQL verification:

```sql
select type, title, body, metadata, created_at
from public.notifications
where type = 'order_status'
order by created_at desc
limit 20;
```

Pass if the notification body tracks the workflow correctly:

- accepted
- packed and ready
- out for delivery
- delivered

## 10. Notification Bell And Read State

1. While signed in as a user who has unread notifications, open the bell menu in the dashboard header.
2. Confirm the unread badge is visible before opening it.
3. Open `Notifications`.
4. Confirm the newest notification appears at the top.
5. Confirm unread rows highlight before opening.
6. Reopen the bell and verify read state has been cleared.

Expected result:

- realtime inserts appear in the bell menu
- opening the panel marks unread items as read
- the unread count disappears when all notifications are read

SQL verification:

```sql
select id, type, title, read, created_at
from public.notifications
where user_id = '<TEST_USER_ID>'
order by created_at desc
limit 20;
```

Pass if newly opened notifications now show `read = true`.

## 11. Final Pass Criteria

The release smoke test passes if all of the following are true:

- wholesaler signup creates a business row automatically
- pharmacy signup creates a business row automatically
- onboarding uploads work for both business types
- admin approval updates the business and creates approval notifications
- approved wholesalers with active products appear in the pharmacy catalog
- the pharmacy can choose a wholesaler and place an order
- the wholesaler receives `new_order` notifications
- the pharmacy receives `order_status` notifications
- the notification bell shows and marks notifications read

If any step fails, capture:

- the exact actor used: admin, wholesaler, or pharmacy
- the route being tested
- the failing SQL query or UI action
- the timestamp of the failed run
