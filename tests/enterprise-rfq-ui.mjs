// Real Chrome rendering; mocked HTTP contracts. SQL tests validate backend authorization separately.
import {chromium} from '../.tmp/import-db/node_modules/playwright/index.mjs';
import assert from 'node:assert/strict';
const browser=await chromium.launch({executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true});
const user={id:'00000000-0000-0000-0000-000000000001',email:'rfq-ui@example.test',aud:'authenticated',role:'authenticated',app_metadata:{},user_metadata:{},created_at:'2026-01-01T00:00:00Z'};
const session={access_token:['eyJhbGciOiJIUzI1NiJ9',Buffer.from(JSON.stringify({sub:user.id,exp:9999999999,role:'authenticated'})).toString('base64url'),'test'].join('.'),refresh_token:'test',expires_at:9999999999,expires_in:3600,token_type:'bearer',user};
const business={id:'00000000-0000-0000-0000-000000000002',name:'RFQ Pharmacy',type:'pharmacy',verification_status:'approved',staff_role:'owner',owner_id:user.id};
const rfq={id:'00000000-0000-0000-0000-000000000003',pharmacy_id:business.id,title:'Monthly procurement',reference:'RFQ-TEST',enterprise:true,status:'draft',revision:2,created_at:'2026-10-11T00:00:00Z',response_deadline:'2027-01-01T12:00:00Z',payment_preference:'cod',quote_count:0};
const item={id:'item',rfq_id:rfq.id,product_name:'Paracetamol',quantity:10,specification:{strength:'500 mg'},unit:'pack',minimum_shelf_life_days:90,alternatives_allowed:false,partial_allowed:true,cancelled_quantity:0};
const context=await browser.newContext();await context.addInitScript(s=>localStorage.setItem('sb-127-auth-token',JSON.stringify(s)),session);
let saved=null;let publication=null;
await context.route('http://127.0.0.1:54321/**',async route=>{const path=new URL(route.request().url()).pathname;let data=[];
if(path.endsWith('/user'))data=user;
else if(path.endsWith('/user_roles'))data=[{role:'pharmacy'}];
else if(path.endsWith('/business_staff'))data=[{role:'owner',business}];
else if(path.endsWith('/businesses'))data=[business];
else if(path.endsWith('/rpc/list_enterprise_rfqs'))data={rows:[rfq],count:1};
else if(path.endsWith('/rpc/rfq_supplier_options'))data=[{id:'supplier',name:'Approved Supplier',favourite:false,matching_catalogue_products:1}];
else if(path.endsWith('/rpc/save_enterprise_rfq')){saved=route.request().postDataJSON();rfq.visibility=saved.p_payload.visibility;data=rfq.id;}
else if(path.endsWith('/rpc/publish_enterprise_rfq')){publication=route.request().postDataJSON();data=null;}
else if(path.endsWith('/rfqs'))data=rfq;
else if(path.endsWith('/rfq_items'))data=[item];
await route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(data)});});
const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
try{
for(const width of [390,768,1024,1440]){
await page.setViewportSize({width,height:1000});await page.goto('http://127.0.0.1:5186/pharmacy/rfqs');await page.getByRole('heading',{name:'Requests for quotation',exact:true}).waitFor();
await page.getByRole('button',{name:/Monthly procurement/}).click();await page.getByRole('heading',{name:'Monthly procurement',exact:true}).waitFor();
assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`Detail overflow at ${width}`);
await page.getByRole('button',{name:'Back to RFQs',exact:true}).click();await page.getByRole('button',{name:'New RFQ',exact:true}).click();
await page.getByRole('heading',{name:'Create RFQ',exact:true}).waitFor();assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`Editor overflow at ${width}`);
await page.screenshot({path:`.tmp/rfq-editor-${width}.png`,fullPage:true});
}
await page.getByLabel('Title',{exact:true}).fill('New procurement');await page.getByLabel('Product name',{exact:true}).fill('Paracetamol');await page.getByRole('button',{name:'Review draft',exact:true}).click();await page.getByRole('button',{name:'Confirm and save draft',exact:true}).click();await page.getByRole('heading',{name:'Monthly procurement',exact:true}).waitFor();
assert.equal(saved.p_payload.title,'New procurement');assert.equal(saved.p_payload.items[0].productName,'Paracetamol');assert.ok(saved.p_request_id);
await page.getByRole('button',{name:'Publish private invitations',exact:true}).click();await page.waitForTimeout(250);assert.equal(publication.p_revision,2);
await page.getByRole('button',{name:'Back to RFQs',exact:true}).click();
await page.getByRole('button',{name:'New RFQ',exact:true}).click();await page.getByLabel(/Supplier access/).selectOption('open');
assert.equal(await page.getByLabel('Supplier selection method').count(),0,'Open RFQs should not expose private invitee selection');
await page.getByLabel('Title',{exact:true}).fill('Open procurement');await page.getByLabel('Product name',{exact:true}).fill('Paracetamol');await page.getByRole('button',{name:'Review draft',exact:true}).click();await page.getByRole('button',{name:'Confirm and save draft',exact:true}).click();
assert.equal(saved.p_payload.visibility,'open');assert.deepEqual(saved.p_payload.suppliers,[]);
await page.getByRole('button',{name:'Publish open RFQ',exact:true}).click();await page.waitForTimeout(250);
assert.deepEqual(errors,[]);console.log('PASS: Chrome RFQ editor/detail at 390, 768, 1024, 1440; private/open draft and publication contracts');
}finally{await browser.close();}
