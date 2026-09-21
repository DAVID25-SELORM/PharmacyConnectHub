// Run after: npm install --prefix .tmp/import-db --no-save @electric-sql/pglite
// Isolated PostgreSQL WASM database; never connects to a deployed Supabase project.
// Loads the real 20260921* migrations against minimal stand-ins for the tables they touch.
import { PGlite } from "../.tmp/import-db/node_modules/@electric-sql/pglite/dist/index.js";
import { readFile } from "node:fs/promises";
import assert from "node:assert/strict";

const db = new PGlite();
const id = (n) => `00000000-0000-0000-0000-${String(n).padStart(12, "0")}`;
const U = {
  approvedOwner: id(1),
  pendingOwner: id(2),
  rejectedOwner: id(3),
  otherOwner: id(4),
  admin: id(5),
  staffee: id(6),
  pharmacyOwner: id(7),
  multiOwner: id(8),
};
const B = {
  approvedW: id(101),
  pendingW: id(102),
  rejectedW: id(103),
  otherW: id(104),
  pharmacy: id(105),
  rejectedP: id(106),
  multiApproved: id(107),
  multiPending: id(108),
};

await db.exec(`
  CREATE ROLE authenticated;
  CREATE SCHEMA auth;
  CREATE TABLE auth.users(id UUID PRIMARY KEY, email TEXT);
  CREATE FUNCTION auth.uid() RETURNS UUID LANGUAGE SQL STABLE AS $$ SELECT nullif(current_setting('test.user', true), '')::UUID $$;

  CREATE TYPE public.verification_status AS ENUM ('pending','approved','rejected');
  CREATE TYPE public.staff_role AS ENUM ('owner','manager','cashier','assistant');
  CREATE TYPE public.business_type AS ENUM ('pharmacy','wholesaler');

  CREATE TABLE public.user_roles(user_id UUID, role TEXT);
  CREATE FUNCTION public.has_role(_uid UUID, _role TEXT) RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER AS $$
    SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _uid AND role = _role) $$;

  CREATE TABLE public.businesses(
    id UUID PRIMARY KEY, owner_id UUID NOT NULL, type public.business_type NOT NULL, name TEXT NOT NULL,
    license_number TEXT, verification_status public.verification_status NOT NULL DEFAULT 'pending',
    rejection_reason TEXT, verified_at TIMESTAMPTZ, updated_at TIMESTAMPTZ NOT NULL DEFAULT now());
  CREATE FUNCTION public.touch_updated_at() RETURNS TRIGGER LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at = now(); RETURN NEW; END $$;
  CREATE TRIGGER trg_businesses_updated BEFORE UPDATE ON public.businesses FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

  CREATE TABLE public.business_staff(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(), business_id UUID NOT NULL, user_id UUID NOT NULL,
    role public.staff_role NOT NULL, status TEXT NOT NULL DEFAULT 'active', invited_by UUID,
    joined_at TIMESTAMPTZ, updated_at TIMESTAMPTZ DEFAULT now(), UNIQUE (business_id, user_id));
  CREATE FUNCTION public.get_staff_role(_uid UUID, _bid UUID) RETURNS public.staff_role LANGUAGE SQL STABLE SECURITY DEFINER AS $$
    SELECT role FROM public.business_staff WHERE user_id = _uid AND business_id = _bid AND status = 'active' $$;
  CREATE FUNCTION public.is_business_staff(_uid UUID, _bid UUID) RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER AS $$
    SELECT EXISTS (SELECT 1 FROM public.business_staff WHERE user_id = _uid AND business_id = _bid AND status = 'active') $$;

  CREATE TABLE public.license_documents(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(), business_id UUID NOT NULL, doc_type TEXT NOT NULL,
    storage_path TEXT, uploaded_at TIMESTAMPTZ DEFAULT now(), UNIQUE (business_id, doc_type));

  CREATE TABLE public.audit_logs(activity TEXT, record_type TEXT DEFAULT 'business', record_id UUID, details JSONB, created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp());
  CREATE FUNCTION public.write_audit_log(_a TEXT, _o TEXT, _rt TEXT, _rid UUID, _rl TEXT, _d JSONB DEFAULT '{}')
    RETURNS VOID LANGUAGE SQL AS $$ INSERT INTO public.audit_logs(activity, record_type, record_id, details) VALUES (_a, _rt, _rid, _d) $$;

  -- audit trigger equivalent for status changes (real one: 20260505090000_add_audit_logs.sql)
  CREATE FUNCTION public.audit_status() RETURNS TRIGGER LANGUAGE plpgsql AS $$
  BEGIN
    IF NEW.verification_status IS DISTINCT FROM OLD.verification_status THEN
      INSERT INTO public.audit_logs(activity, record_type, record_id, details) VALUES (
        CASE WHEN NEW.verification_status = 'rejected' THEN 'Business rejected' ELSE 'status ' || OLD.verification_status || '->' || NEW.verification_status END,
        'business', NEW.id, jsonb_build_object('rejection_reason', NEW.rejection_reason));
    END IF; RETURN NEW; END $$;

  CREATE TABLE public.customer_discounts(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(), wholesaler_id UUID NOT NULL, pharmacy_id UUID NOT NULL,
    discount_type TEXT NOT NULL DEFAULT 'percentage', discount_percent NUMERIC(5,2), discount_amount NUMERIC(10,2),
    minimum_order_value NUMERIC(10,2) NOT NULL DEFAULT 0, starts_at TIMESTAMPTZ NOT NULL DEFAULT now(), ends_at TIMESTAMPTZ,
    active BOOLEAN NOT NULL DEFAULT TRUE, internal_note TEXT, created_by UUID, updated_by UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now());
  ALTER TABLE public.customer_discounts ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.business_staff ENABLE ROW LEVEL SECURITY;
  CREATE POLICY "Owners see staff" ON public.business_staff FOR SELECT USING (true);

  INSERT INTO auth.users VALUES ('${U.staffee}', 'staff@example.com'), ('${U.admin}', 'admin@example.com');
  INSERT INTO public.user_roles VALUES ('${U.admin}', 'admin');
  INSERT INTO public.businesses(id, owner_id, type, name, license_number, verification_status, rejection_reason) VALUES
    ('${B.approvedW}', '${U.approvedOwner}', 'wholesaler', 'Approved W', 'L1', 'approved', NULL),
    ('${B.pendingW}', '${U.pendingOwner}', 'wholesaler', 'Pending W', 'L2', 'pending', NULL),
    ('${B.rejectedW}', '${U.rejectedOwner}', 'wholesaler', 'Rejected W', 'L3', 'rejected', 'Licence unreadable'),
    ('${B.otherW}', '${U.otherOwner}', 'wholesaler', 'Other W', 'L4', 'approved', NULL),
    ('${B.pharmacy}', '${U.pharmacyOwner}', 'pharmacy', 'Pharm', 'P1', 'approved', NULL),
    ('${B.rejectedP}', '${U.pharmacyOwner}', 'pharmacy', 'Rejected Pharm', 'P2', 'rejected', 'Council licence expired'),
    ('${B.multiApproved}', '${U.multiOwner}', 'wholesaler', 'Multi A', 'M1', 'approved', NULL),
    ('${B.multiPending}', '${U.multiOwner}', 'wholesaler', 'Multi B', 'M2', 'pending', NULL);
  INSERT INTO public.customer_discounts(wholesaler_id, pharmacy_id, discount_percent, discount_type)
    SELECT wholesaler_id, '${B.pharmacy}', 5, 'percentage' FROM (VALUES
      ('${B.approvedW}'::UUID), ('${B.pendingW}'::UUID), ('${B.otherW}'::UUID)) v(wholesaler_id);

  GRANT USAGE ON SCHEMA public, auth TO authenticated;
  GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
  GRANT SELECT ON auth.users TO authenticated;
  GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;
  GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated;
`);

for (const file of [
  "20260921100000_enforce_verification_on_protected_rpcs.sql",
  "20260921101000_add_business_verification_resubmission.sql",
]) {
  await db.exec(await readFile(new URL(`../supabase/migrations/${file}`, import.meta.url), "utf8"));
}
// Triggers are created by earlier migrations in production; recreate them here.
await db.exec(`
  CREATE TRIGGER trg_enforce_business_verification_controls BEFORE UPDATE ON public.businesses
    FOR EACH ROW EXECUTE FUNCTION public.enforce_business_verification_controls();
  CREATE TRIGGER trg_audit_status AFTER UPDATE ON public.businesses
    FOR EACH ROW EXECUTE FUNCTION public.audit_status();
`);

let passed = 0;
async function as(user, fn) {
  await db.exec(`SELECT set_config('test.user', '${user}', false); SET ROLE authenticated;`);
  try {
    return await fn();
  } finally {
    await db.exec("RESET ROLE;");
  }
}
async function ok(name, user, sql, params) {
  await as(user, () => db.query(sql, params));
  passed += 1;
  console.log(`ok   ${name}`);
}
async function denied(name, user, sql, params, pattern) {
  let error = null;
  await as(user, async () => {
    try {
      await db.query(sql, params);
    } catch (e) {
      error = e;
    }
  });
  assert.ok(error, `${name}: expected an error`);
  if (pattern) assert.match(error.message, pattern, name);
  passed += 1;
  console.log(`ok   ${name} (denied: ${error.message})`);
}
const discountFor = (w) => [w, B.pharmacy, "percentage", 10];
const UPSERT = "SELECT public.upsert_customer_discount($1::uuid, $2::uuid, $3, $4::numeric)";
const VERIFY = /must be verified/;

// 1-3 discount create
await ok(
  "approved wholesaler can create customer discount",
  U.approvedOwner,
  UPSERT,
  discountFor(B.approvedW),
);
await denied(
  "pending wholesaler cannot create customer discount",
  U.pendingOwner,
  UPSERT,
  discountFor(B.pendingW),
  VERIFY,
);
await denied(
  "rejected wholesaler cannot create customer discount",
  U.rejectedOwner,
  UPSERT,
  discountFor(B.rejectedW),
  VERIFY,
);

// 4-5 deactivate
const own = async (w) =>
  (
    await db.query(
      "SELECT id FROM public.customer_discounts WHERE wholesaler_id = $1 AND active LIMIT 1",
      [w],
    )
  ).rows[0].id;
const approvedDiscount = await own(B.approvedW);
const pendingDiscount = await own(B.pendingW);
const otherDiscount = await own(B.otherW);
await ok(
  "approved wholesaler can deactivate discount",
  U.approvedOwner,
  "SELECT public.deactivate_customer_discount($1::uuid)",
  [approvedDiscount],
);
await denied(
  "pending wholesaler cannot deactivate discount",
  U.pendingOwner,
  "SELECT public.deactivate_customer_discount($1::uuid)",
  [pendingDiscount],
  VERIFY,
);

// 6 list
await denied(
  "pending wholesaler cannot list customer discounts",
  U.pendingOwner,
  "SELECT public.list_wholesaler_customer_discounts($1::uuid)",
  [B.pendingW],
  VERIFY,
);
const listed = await as(U.approvedOwner, () =>
  db.query("SELECT public.list_wholesaler_customer_discounts($1::uuid) AS r", [B.approvedW]),
);
assert.ok(listed.rows[0].r.length >= 1 && !("internal_note" in listed.rows[0].r[0]));
passed += 1;
console.log("ok   approved wholesaler can list discounts without internal notes");

// 7 isolation
await denied(
  "wholesaler cannot upsert for another wholesaler",
  U.approvedOwner,
  UPSERT,
  discountFor(B.otherW),
  /Only wholesaler owners/,
);
const foreign = await as(U.approvedOwner, () =>
  db.query("SELECT public.deactivate_customer_discount($1::uuid) AS r", [otherDiscount]),
);
assert.equal(foreign.rows[0].r, false);
const foreignList = await as(U.approvedOwner, () =>
  db.query("SELECT public.list_wholesaler_customer_discounts($1::uuid) AS r", [B.otherW]),
);
assert.deepEqual(foreignList.rows[0].r, []);
passed += 1;
console.log("ok   wholesaler cannot deactivate or list another wholesaler's discounts");

// RLS: direct table access is also blocked for pending wholesalers
const pendingRows = await as(U.pendingOwner, () =>
  db.query("SELECT * FROM public.customer_discounts"),
); // no policy grant for owner? policy is approved-only
assert.equal(pendingRows.rows.length, 0);
await denied(
  "pending wholesaler cannot insert customer_discounts directly (RLS)",
  U.pendingOwner,
  "INSERT INTO public.customer_discounts(wholesaler_id, pharmacy_id, discount_percent) VALUES ($1, $2, 5)",
  [B.pendingW, B.pharmacy],
);
const approvedRows = await as(U.approvedOwner, () =>
  db.query("SELECT wholesaler_id FROM public.customer_discounts"),
);
assert.ok(
  approvedRows.rows.length > 0 && approvedRows.rows.every((r) => r.wholesaler_id === B.approvedW),
);
passed += 1;
console.log("ok   RLS: pending sees no discounts, approved sees only its own");

// 8 platform admin: discount RPCs never permitted admin; behaviour unchanged
await denied(
  "platform admin still cannot manage another business's discounts",
  U.admin,
  UPSERT,
  discountFor(B.approvedW),
  /Only wholesaler owners/,
);

// 9-10 staff invite
const INVITE = "SELECT public.add_business_staff_by_email($1::uuid, $2, $3::public.staff_role)";
await denied(
  "pending business cannot invite staff",
  U.pendingOwner,
  INVITE,
  [B.pendingW, "staff@example.com", "manager"],
  /must be verified/,
);
await denied(
  "rejected business cannot invite staff",
  U.rejectedOwner,
  INVITE,
  [B.rejectedW, "staff@example.com", "manager"],
  /must be verified/,
);
await ok("approved business can invite staff", U.approvedOwner, INVITE, [
  B.approvedW,
  "staff@example.com",
  "manager",
]);
await ok("platform admin can still add staff to any business", U.admin, INVITE, [
  B.pendingW,
  "staff@example.com",
  "cashier",
]);
await denied(
  "pending owner cannot insert business_staff directly (RLS)",
  U.pendingOwner,
  "INSERT INTO public.business_staff(business_id, user_id, role) VALUES ($1, $2, 'assistant')",
  [B.pendingW, U.staffee],
);

// 11-12 resubmission
const RESUBMIT = "SELECT public.resubmit_business_verification($1::uuid) AS s";
const docs = async (b, types) => {
  for (const t of types)
    await db.query(
      "INSERT INTO public.license_documents(business_id, doc_type, storage_path) VALUES ($1, $2, 'x') ON CONFLICT (business_id, doc_type) DO NOTHING",
      [b, t],
    );
};
await denied(
  "non-owner cannot resubmit",
  U.otherOwner,
  RESUBMIT,
  [B.rejectedW],
  /Only the business owner/,
);
await denied(
  "resubmission requires all documents",
  U.rejectedOwner,
  RESUBMIT,
  [B.rejectedW],
  /Upload all required documents/,
);
await denied(
  "owner cannot self-approve via direct update",
  U.rejectedOwner,
  "UPDATE public.businesses SET verification_status = 'approved' WHERE id = $1",
  [B.rejectedW],
  /Only admins/,
);
await denied(
  "owner cannot set pending via direct update",
  U.rejectedOwner,
  "UPDATE public.businesses SET verification_status = 'pending' WHERE id = $1",
  [B.rejectedW],
  /Only admins/,
);
await docs(B.rejectedW, ["wholesale_license", "fda_certificate", "business_registration"]);
const resubmitted = await as(U.rejectedOwner, () => db.query(RESUBMIT, [B.rejectedW]));
assert.equal(resubmitted.rows[0].s, "pending");
const row = (
  await db.query(
    "SELECT verification_status, rejection_reason FROM public.businesses WHERE id = $1",
    [B.rejectedW],
  )
).rows[0];
assert.equal(row.verification_status, "pending");
assert.equal(row.rejection_reason, null, "stale rejection banner cleared");
const trail = (
  await db.query(
    "SELECT activity, details FROM public.audit_logs WHERE record_id = $1 ORDER BY ctid",
    [B.rejectedW],
  )
).rows;
const resubmitAudit = trail.find((r) => r.activity === "Verification resubmitted");
assert.equal(
  resubmitAudit.details.previous_rejection_reason,
  "Licence unreadable",
  "prior feedback preserved in audit history",
);
passed += 1;
console.log("ok   rejected -> pending after resubmission; feedback preserved in audit_logs");

await denied(
  "approved business cannot resubmit",
  U.approvedOwner,
  RESUBMIT,
  [B.approvedW],
  /Only a rejected business/,
);
const again = await as(U.rejectedOwner, () => db.query(RESUBMIT, [B.rejectedW]));
assert.equal(again.rows[0].s, "pending");
passed += 1;
console.log("ok   resubmitting while pending is idempotent");

// change-since-rejection: admin rejects (audit event), owner must change something first
await ok(
  "admin rejects the resubmitted business (creates the rejection audit event)",
  U.admin,
  "UPDATE public.businesses SET verification_status = 'rejected', rejection_reason = 'Stamp missing' WHERE id = $1",
  [B.rejectedW],
);
await denied(
  "unchanged rejected submission cannot be resubmitted",
  U.rejectedOwner,
  RESUBMIT,
  [B.rejectedW],
  /Update at least one required document/,
);
await db.query(
  "UPDATE public.license_documents SET storage_path = 'replaced-' || gen_random_uuid()::text WHERE business_id = $1 AND doc_type = 'fda_certificate'",
  [B.rejectedW],
);
const changed = await as(U.rejectedOwner, () => db.query(RESUBMIT, [B.rejectedW]));
assert.equal(changed.rows[0].s, "pending");
passed += 1;
console.log("ok   replacing a required document after rejection allows resubmission");
const audit2 = (
  await db.query(
    "SELECT details FROM public.audit_logs WHERE record_id = $1 AND activity = 'Verification resubmitted' ORDER BY created_at DESC LIMIT 1",
    [B.rejectedW],
  )
).rows[0];
assert.equal(audit2.details.previous_rejection_reason, "Stamp missing");
passed += 1;

// business-detail edit after rejection also counts as a change
await ok(
  "admin rejects again",
  U.admin,
  "UPDATE public.businesses SET verification_status = 'rejected', rejection_reason = 'Address' WHERE id = $1",
  [B.rejectedW],
);
await denied(
  "second rejection: unchanged again cannot resubmit",
  U.rejectedOwner,
  RESUBMIT,
  [B.rejectedW],
  /Update at least one/,
);
await ok(
  "owner edits business details",
  U.rejectedOwner,
  "UPDATE public.businesses SET name = 'Rejected W (renamed)' WHERE id = $1",
  [B.rejectedW],
);
const viaDetails = await as(U.rejectedOwner, () => db.query(RESUBMIT, [B.rejectedW]));
assert.equal(viaDetails.rows[0].s, "pending");
passed += 1;
console.log("ok   editing business details after rejection allows resubmission");

// admin can still approve/reject
await ok(
  "admin can still approve",
  U.admin,
  "UPDATE public.businesses SET verification_status = 'approved' WHERE id = $1",
  [B.rejectedW],
);
await ok(
  "admin can still reject with a reason",
  U.admin,
  "UPDATE public.businesses SET verification_status = 'rejected', rejection_reason = 'Blurry' WHERE id = $1",
  [B.rejectedW],
);
const rej = (
  await db.query("SELECT rejection_reason FROM public.businesses WHERE id = $1", [B.rejectedW])
).rows[0];
assert.equal(rej.rejection_reason, "Blurry");
passed += 1;

// 13 (data side): status is per business, not per user
const multi = (
  await db.query(
    "SELECT id, verification_status FROM public.businesses WHERE owner_id = $1 ORDER BY name",
    [U.multiOwner],
  )
).rows;
assert.deepEqual(
  multi.map((r) => r.verification_status),
  ["approved", "pending"],
);
await ok(
  "multi-business owner can use the approved workspace",
  U.multiOwner,
  UPSERT,
  discountFor(B.multiApproved),
);
await denied(
  "...but not the pending one",
  U.multiOwner,
  UPSERT,
  discountFor(B.multiPending),
  VERIFY,
);

// unrelated signed-in user hits the former NULL-role bypass (no membership at all)
await denied(
  "unrelated user cannot create discount (former NULL bypass)",
  U.pharmacyOwner,
  UPSERT,
  discountFor(B.approvedW),
  /Only wholesaler owners/,
);
await denied(
  "unrelated user cannot create discount for a pending wholesaler",
  U.pharmacyOwner,
  UPSERT,
  discountFor(B.pendingW),
  /Only wholesaler owners/,
);
// direct table UPDATE by a pending wholesaler affects nothing (RLS)
const upd = await as(U.pendingOwner, () =>
  db.query("UPDATE public.customer_discounts SET discount_percent = 99 WHERE wholesaler_id = $1", [
    B.pendingW,
  ]),
);
assert.equal(upd.affectedRows, 0);
const untouched = (
  await db.query(
    "SELECT discount_percent FROM public.customer_discounts WHERE wholesaler_id = $1",
    [B.pendingW],
  )
).rows;
assert.ok(untouched.every((r) => Number(r.discount_percent) !== 99));
passed += 1;
console.log("ok   pending wholesaler direct UPDATE is blocked by RLS");

// managers: approved wholesaler manager may manage discounts; pending one may not
await db.query(
  "INSERT INTO public.business_staff(business_id, user_id, role) VALUES ($1, $2, 'manager'), ($3, $2, 'manager') ON CONFLICT (business_id, user_id) DO UPDATE SET role = 'manager'",
  [B.approvedW, U.staffee, B.pendingW],
);
await ok(
  "approved wholesaler manager can create discount",
  U.staffee,
  UPSERT,
  discountFor(B.approvedW),
);
await denied(
  "pending wholesaler manager cannot create discount",
  U.staffee,
  UPSERT,
  discountFor(B.pendingW),
  VERIFY,
);

// get_my_customer_discount: approved pharmacy only, own discounts only
const LOOKUP = "SELECT * FROM public.get_my_customer_discount($1::uuid)";
await db.query(
  "INSERT INTO public.customer_discounts(wholesaler_id, pharmacy_id, discount_percent, discount_type) VALUES ($1, $2, 7, 'percentage')",
  [B.otherW, B.rejectedP],
);
const approvedLookup = await as(U.pharmacyOwner, () => db.query(LOOKUP, [B.otherW]));
assert.ok(
  approvedLookup.rows.length >= 1 && approvedLookup.rows.every((r) => r.pharmacy_id === B.pharmacy),
);
passed += 1;
console.log("ok   approved pharmacy retrieves its own discount only");
await ok(
  "admin sets the pharmacy back to pending",
  U.admin,
  "UPDATE public.businesses SET verification_status = 'pending' WHERE id = $1",
  [B.pharmacy],
);
const pendingLookup = await as(U.pharmacyOwner, () => db.query(LOOKUP, [B.otherW]));
assert.equal(pendingLookup.rows.length, 0);
const unrelatedLookup = await as(U.otherOwner, () => db.query(LOOKUP, [B.otherW]));
assert.equal(unrelatedLookup.rows.length, 0);
passed += 1;
console.log("ok   pending pharmacy and unrelated users get no discount data");

console.log(`\n${passed} database checks passed`);
