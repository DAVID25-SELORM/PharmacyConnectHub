// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { beforeEach, afterEach, expect, it, vi } from "vitest";
const mocks=vi.hoisted(()=>({rpc:vi.fn(),read:vi.fn(),block:vi.fn()}));
vi.mock("@tanstack/react-router",()=>({useBlocker:mocks.block}));
vi.mock("@/integrations/supabase/client",()=>({
 supabase:{
  rpc:mocks.rpc,
  from:()=>({select:()=>({eq:(_id:string,business:string)=>({maybeSingle:()=>mocks.read(business)})})}),
  storage:{from:()=>({getPublicUrl:(path:string)=>({data:{publicUrl:`https://example.test/${path}`}})})}
 }
}));
import { DocumentBrandingSettings } from "./DocumentBrandingSettings";
let host:HTMLDivElement,root:Root;
beforeEach(()=>{
  mocks.rpc.mockReset().mockResolvedValue({error:null});
  mocks.read.mockReset().mockImplementation(async(id:string)=>({data:{display_name:id,logo_path:`${id}/logo.webp`,accent_color:"#0f766e",show_license:true,show_secondary_contact:true,footer_note:null,signatory_name:null,signatory_title:null,payment_instructions:null},error:null}));
  host=document.createElement("div");document.body.append(host);root=createRoot(host);
});
afterEach(async()=>{await act(async()=>root.unmount());host.remove();});
async function render(id="a"){await act(async()=>root.render(<DocumentBrandingSettings businessId={id} businessName={`Business ${id}`}/>));}
async function click(name:string){const b=Array.from(host.querySelectorAll("button")).find(b=>b.textContent===name)!;await act(async()=>b.click());}
it("removes only the current logo reference and saves through presentation RPC",async()=>{
  await render();await click("Remove logo");expect(host.textContent).toContain("Unsaved changes");await click("Save document branding");
  expect(mocks.rpc).toHaveBeenCalledWith("save_document_presentation",expect.objectContaining({p_business_id:"a",p_logo_path:null}));
  expect(host.textContent).not.toContain("Unsaved changes");
});
it("discard restores saved logo and tenant switching reloads the correct identity",async()=>{
  await render();await click("Remove logo");await click("Discard changes");
  expect(host.querySelector('img[alt="Current business logo"]')?.getAttribute("src")).toContain("a/logo.webp");
  await render("b");expect(host.querySelector('img[alt="Current business logo"]')?.getAttribute("src")).toContain("b/logo.webp");
  expect(host.textContent).not.toContain("Business a");
});
it("failed saves retain draft changes for retry",async()=>{
  await render();await click("Remove logo");mocks.rpc.mockResolvedValueOnce({error:new Error("offline")});await click("Save document branding");
  expect(host.textContent).toContain("Unsaved changes");
});
