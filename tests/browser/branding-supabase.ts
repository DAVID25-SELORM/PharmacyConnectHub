const blank = {
  display_name: null,
  logo_path: null,
  accent_color: "#0f766e",
  show_license: true,
  show_secondary_contact: true,
  footer_note: null,
  signatory_name: null,
  signatory_title: null,
  payment_instructions: null,
};
export const supabase = {
  from: () => ({
    select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: blank, error: null }) }) }),
  }),
  rpc: async () => ({ data: blank, error: null }),
  storage: { from: () => ({ getPublicUrl: () => ({ data: { publicUrl: "" } }) }) },
};
