import { execFileSync, spawn } from "node:child_process";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
const container = "supabase_db_drugxone-local-validation";
const database = process.env.EXTERNAL_TEST_DB || "external_procurement_review";
if (!/^external_procurement_[a-z_]+$/.test(database)) throw new Error("Use an isolated external_procurement_* local database.");
const args = ["exec", "-i", container, "psql", "-U", "postgres", "-d", database, "-v", "ON_ERROR_STOP=1", "-Atq"];
const sql = text => execFileSync("docker", args, { input: text, encoding: "utf8" }).trim();
const asyncSql = text => new Promise(resolve => {
 const child=spawn("docker",args,{windowsHide:true});let out="",err="";
 child.stdout.on("data",d=>out+=d);child.stderr.on("data",d=>err+=d);
 child.on("close",code=>resolve({code,out,err}));child.stdin.end(text);
});
const suffix=randomUUID();
const [user,pharmacy]=sql("SELECT u_po,good FROM zz.cc").split("|");
const auth=`SELECT set_config('request.jwt.claim.sub','${user}',true); SET LOCAL ROLE authenticated;`;
const fixture=sql(`BEGIN;
SELECT set_config('request.jwt.claim.sub','${user}',true);
CREATE TEMP TABLE new_receipt(id uuid);
INSERT INTO new_receipt SELECT public.save_external_purchase('${pharmacy}',jsonb_build_object(
 'purchase_date',current_date,'channel','unknown','source_type','external_wholesaler','source',jsonb_build_object('name','Concurrency source'),
 'items',jsonb_build_array(jsonb_build_object('product',jsonb_build_object('name','Concurrency ${suffix}'),'quantity',20,'unit_cost_ghs',10,
 'batches',jsonb_build_array(jsonb_build_object('quantity',20,'batch_number','CONC-${suffix}','expiry_date',current_date+365))))),'${randomUUID()}');
SELECT public.configure_external_procurement('${pharmacy}',false,'${user}',true);
INSERT INTO storage.objects(bucket_id,name) SELECT 'external-procurement','${pharmacy}/'||id||'/invoice.pdf' FROM new_receipt;
SELECT public.external_document_action(id,'supplier_invoice','${pharmacy}/'||id||'/invoice.pdf','invoice.pdf') FROM new_receipt;
SELECT public.review_external_purchase(id,'submit') FROM new_receipt;
SELECT 'FIXTURE:'||id FROM new_receipt; COMMIT;`).split("\n").find(l=>l.startsWith("FIXTURE:")).slice(8);
const approve=`SELECT public.review_external_purchase('${fixture}','approved','Evidence reviewed');`;
const approved=await Promise.all([asyncSql(`BEGIN;${auth}${approve}SELECT pg_sleep(1);COMMIT;`),asyncSql(`BEGIN;${auth}${approve}COMMIT;`)]);
assert.ok(approved.every(r=>r.code===0),JSON.stringify(approved));
const [stock,movements,batch]=sql(`SELECT stock,(SELECT count(*) FROM public.pharmacy_inventory_movements WHERE item_id=s.id),b.id FROM public.external_purchase_items i JOIN public.pharmacy_inventory_items s ON s.id=i.inventory_item_id JOIN public.external_purchase_batches b ON b.item_id=i.id WHERE i.purchase_id='${fixture}'`).split("|");
assert.equal(stock,"20");assert.equal(movements,"1");
const request=randomUUID();const payment=`SELECT public.record_external_payment('${fixture}',20,'cash','Concurrent',current_date,'${request}');`;
const payments=await Promise.all([asyncSql(`BEGIN;${auth}${payment}SELECT pg_sleep(1);COMMIT;`),asyncSql(`BEGIN;${auth}${payment}COMMIT;`)]);
assert.ok(payments.every(r=>r.code===0),JSON.stringify(payments));
assert.equal(sql(`SELECT sum(amount_ghs) FROM public.external_purchase_payments WHERE purchase_id='${fixture}'`),"20.00");
const returnSql=()=>`SELECT public.adjust_external_batch('${batch}',15,'return','Concurrent return','Source',current_date,0,'${randomUUID()}');`;
const returns=await Promise.all([asyncSql(`BEGIN;${auth}${returnSql()}SELECT pg_sleep(1);COMMIT;`),asyncSql(`BEGIN;${auth}${returnSql()}COMMIT;`)]);
assert.equal(returns.filter(r=>r.code===0).length,1,JSON.stringify(returns));
assert.ok(returns.find(r=>r.code!==0).err.includes("exceeds this batch"));
assert.equal(sql(`SELECT stock FROM public.pharmacy_inventory_items WHERE id=(SELECT inventory_item_id FROM public.external_purchase_items WHERE purchase_id='${fixture}')`),"5");
console.log("PASS: concurrent approval posts once; payment retry posts once; concurrent returns cannot overspend a batch.");
