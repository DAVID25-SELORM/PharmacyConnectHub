# Authentication/session investigation ? 9 October 2026

## Confirmed code defects; device cause not yet confirmed

The former `clearBrokenSession` in `src/hooks/use-session.ts` called the default (global) Supabase signOut after an authorization lookup was classified as unauthorized and refresh failed, or the second lookup was still unauthorized. Classification used broad message substrings including `jwt` and `401`. A network failure during forced refresh returned null, discarding authentication. Thrown requests had no hydration catch, leaving loading stuck. Sign-out events did not invalidate already-running hydration. A control test against the original committed store reproduced a signOut call and cleared user after PGRST301 followed by a network refresh failure. The patched store keeps the same scenario recoverable. These are confirmed code paths, not proof of the precise error on the reported Windows computer.

## Lifecycle and correction

Login calls signInWithPassword; a singleton lazy Supabase client persists its session and auto-refreshes. One module-level external store registers one auth listener. The password-recovery page separately registers and cleans up its listener. There is no additional auth provider. Dashboard initialization does not query the profiles table: it loads user_roles, active business_staff memberships and owned businesses, then selects an authorized workspace. Missing business membership goes to onboarding/chooser; pending/rejected approval goes to onboarding, never signOut. RLS remains authoritative.

The store now exposes separate authStatus and authorizationStatus values, handles thrown/returned failures, uses a 20-second recoverable timeout for restoration/lookup, and preserves known authentication on errors while denying workspace access until a successful retry. Query errors no longer force refresh or signOut. Retry refreshes an expiring token only. Auth events invalidate older hydration before queuing database work outside the SDK callback. Late lookup results cannot replace a newer session or resurrect a signed-out session.

Only two application signOut call sites remain: the user's header logout in DashboardShell and the user's error-screen logout in WorkspaceGate. Both log their path and use scope local so another device is not logged out. SDK SIGNED_OUT is honored independently and logged. No production records, RLS policies or approval rules changed.

## Sanitized diagnostics

Browser console prefix: [DrugXOne auth]. Events: client.configuration (project host only), login.password (hasSession), auth.event.*, session.restore, session.refresh, session.established, workspace.roles, workspace.memberships, workspace.owner_lookup, session.recoverable_error, guard.workspace, signout.intentional.*. Errors include only machine code and numeric HTTP status; no error message/details/hint, email, user ID, password, token or session object. A SDK event identifies SDK-driven session loss; signout.intentional.* identifies an explicit application logout. An established session is locally present, not a claim that its signature was independently validated; database requests still enforce RLS.

Example controlled 401 test sequence (not a device capture): session.restore hasSession=true; session.established hasSession=true; workspace.roles code=PGRST301 status=401; authorizationStatus=recoverable-error; signOut calls=0.

.env points to ywpntuioeqpreouauuir.supabase.co. .env.local points to the local validation server and overrides development builds. Neither proves the deployed Windows browser configuration: compare client.configuration host and exact DrugXOne site origin on working/failing browsers. Do not publish a locally built artifact targeting .env.local.

## Validation and remaining checks

Mocked SDK lifecycle regressions cover owner/manager/cashier/accountant, wholesale, healthy dashboard refresh, 401/403/network lookup failures, missing organization, slow and stalled requests, retry recovery, temporary token-refresh failure, sign-out/restore races, duplicate subscriptions, pending/rejected approval, blocked storage and log redaction. Existing workspace-guard regressions cover approval and chooser routing. These are simulated SDK/network tests, not an actual Chrome Incognito or multi-device acceptance run.

Before approval/deployment, review changed files and checks. After an approved deployment, collect the sanitized console sequence from both devices, verify the same project host/site origin, inspect numeric HTTP status/code for failed Supabase calls, and retry in normal/Incognito. The failing Windows machine is not connected here; its network/proxy/clock/storage conditions and production RLS errors remain unconfirmed. Never share raw network exports containing Authorization headers or cookies.

Deployment: user authorized the scoped authentication fix to be committed and pushed after final verification. No SQL migration or production data changes are included. Live deployment and affected-device acceptance must be verified separately.

## Affected files

- src/hooks/use-session.ts ? session/authorization separation, recovery, timeout and race handling.
- src/lib/auth-diagnostics.ts ? sanitized logging and bounded waits.
- src/integrations/supabase/client.ts ? project-host diagnostic only.
- src/routes/login.tsx ? password-auth result diagnostic.
- src/components/DashboardShell.tsx ? intentional local logout diagnostic/scope.
- src/components/WorkspaceGate.tsx ? guard decision and intentional local logout diagnostics.
- src/lib/workspace-access.ts ? recoverable restoration error before login redirect.
- src/routes/onboarding.tsx ? avoid login redirect/loading loop on restoration errors.
- src/hooks/use-session.test.ts and src/lib/workspace-access.test.ts ? regression coverage.
