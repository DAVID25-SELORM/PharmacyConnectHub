// One Vercel function for this route family; existing URLs and handler authorization remain unchanged.
import invite from "../_staff/invite.js";
import resendInvite from "../_staff/resend-invite.js";
import update from "../_staff/update.js";
import { createStaffRouter } from "../_staff-router.js";

export default createStaffRouter("staff", { invite, "resend-invite": resendInvite, update });
