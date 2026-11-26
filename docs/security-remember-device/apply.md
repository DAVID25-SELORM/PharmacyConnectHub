# Ask for the two-step code on a new device, and again after 7 days

## What people will notice

- On the code screen there is a ticked box: **Remember this device for 7 days**.
- For the next 7 days, signing in on that browser needs only the password, including after an automatic sign-out.
- A new device, another browser, a private window or cleared browser data asks for the code.
- After 7 days (counted from when the code was entered, never extended) the code is asked for again.
- Automatic sign-out is unchanged: 15 minutes for platform admins, 1 hour for everyone else.

A remembered device stops being remembered when the password or the authenticator app changes, when the person presses **Forget remembered devices**, or when they use **Sign out other devices** or **Sign out everywhere**.

Two things still need a real code, because the sign-in service insists: changing the password or two-step settings (a box appears under Security), and resetting a forgotten password. The admin switch **Require for all admins** also still needs a real code to be switched on.

## The trade-off

Before, a stolen password was useless without the authenticator. Now, for up to 7 days, **someone who has the password and also uses a remembered browser gets in without a code**. The password alone, from any other device, still does not. The device's key is kept in the browser, so anything able to read that browser's storage could copy it; it is useless without the password. People should untick the box on shared or public computers. This matters most for platform admins, who can see every business.

## Applying it

Apply the database change **before** merging the app. If the app goes out first, nothing breaks: the code is asked for as before, and the box has no effect until the database update is applied.

In the Supabase SQL editor of **PharmacyConnectHub** (project `ywpntuioeqpreouauuir`; check the name first):

1. Run `preflight.sql` (read-only). All 4 rows must say `true`.
2. Run `supabase/migrations/20261217100000_remembered_devices.sql`.
3. Run `verify.sql` (read-only). All 8 rows must say `true`.

## If something is wrong

Make everyone enter a code again at once:

```sql
UPDATE public.remembered_devices SET revoked_at = now() WHERE revoked_at IS NULL;
```

To stop the feature altogether, also run `REVOKE EXECUTE ON FUNCTION public.remember_this_device(TEXT) FROM authenticated;`.

## Tests

`tests/local-supabase/remembered-devices.sql` (38 database checks; run after `setup.sql`), `src/lib/remembered-device.test.tsx` and `api/_assurance.test.ts`.
