// One Vercel function for this route family; existing URLs and handler authorization remain unchanged.
import invite from "../_platform-staff/invite.js";
import resendInvite from "../_platform-staff/resend-invite.js";
import update from "../_platform-staff/update.js";
import { createStaffRouter } from "../_staff-router.js";

export default createStaffRouter("platform-staff", {
  invite,
  "resend-invite": resendInvite,
  update,
});
