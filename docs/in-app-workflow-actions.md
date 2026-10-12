# In-app workflow actions

Application confirmations use the shared accessible confirmation dialog in `src/lib/confirm-action.tsx`, mounted at the root. No application code calls native alert, confirm, prompt, or desktop Notification APIs. Pending confirmations fail closed if another action asks for confirmation.

Covered workflows: external supply documents, receipt editor dismissal, branding navigation, CRM archive/restore, reorder-list deletion, credit revocation, and verification approval overrides.

## External procurement

- Save a request/order draft, reopen it, and choose **Continue / edit draft**.
- **Remove draft** uses the existing authorized/versioned cancellation RPC. It is a removal from active work, not permanent database deletion.
- Enable **Include cancelled documents and removed drafts** to inspect the original document and history.
- **Create revised draft** copies an issued/cancelled document into a new editable draft with new line IDs, a cleared delivery date, and an original-reference note. It does not cancel the original or move any receipts. Cancel superseded outstanding balances separately.
- Unposted, non-rejected receipts retain **Continue / edit receipt**. Posted receipts and financial history are not deleted or silently rewritten.
- Receipt dismissal asks before discarding unsaved edits. Failed saves retain the current form.

Save before refreshing/closing the browser tab. Browser-owned unload prompts are disabled as requested; unsaved edits are not persisted across a full page reload. In-app route navigation still asks before discarding a supply/branding edit; workspace switching is blocked with an in-app message until it is saved or closed.

No database migration is required. Existing server authorization, version checks, and document audit history remain authoritative.
