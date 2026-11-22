import { useEffect, useRef, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { supabase } from "@/integrations/supabase/client";
import { useSession } from "@/hooks/use-session";
import {
  idleLimitFor,
  idleStatus,
  readLastActivity,
  secondsLeft,
  writeLastActivity,
} from "@/lib/idle-session";

const ACTIVITY_EVENTS = ["pointerdown", "keydown", "wheel", "touchstart", "scroll"] as const;
/** Writing storage on every mouse move would be wasteful; once every 15 seconds is plenty. */
const WRITE_THROTTLE_MS = 15_000;

/**
 * Signs the person out after a period with no clicks or typing, warning them two minutes
 * before. Mounted once in the app root; does nothing while nobody is signed in.
 */
export function IdleSessionGuard() {
  const { session, roles } = useSession();
  const signedIn = Boolean(session);
  const limitMs = idleLimitFor(roles);
  const lastActivity = useRef(Date.now());
  const lastWrite = useRef(0);
  const [warningSeconds, setWarningSeconds] = useState<number | null>(null);

  useEffect(() => {
    if (!signedIn) {
      setWarningSeconds(null);
      return;
    }

    const storage = typeof window !== "undefined" ? window.localStorage : undefined;
    lastActivity.current = readLastActivity(storage, Date.now());
    // A new sign-in starts a fresh clock even if an old timestamp is lying around.
    if (Date.now() - lastActivity.current >= limitMs) {
      lastActivity.current = Date.now();
      writeLastActivity(storage, lastActivity.current);
    }

    const touch = () => {
      const now = Date.now();
      lastActivity.current = now;
      if (now - lastWrite.current >= WRITE_THROTTLE_MS) {
        lastWrite.current = now;
        writeLastActivity(storage, now);
      }
    };

    const tick = async () => {
      // Another tab may have seen activity more recently.
      const shared = readLastActivity(storage, lastActivity.current);
      if (shared > lastActivity.current) lastActivity.current = shared;
      const now = Date.now();
      const status = idleStatus(now, lastActivity.current, limitMs);
      if (status === "expired") {
        setWarningSeconds(null);
        await supabase.auth.signOut({ scope: "local" });
        toast.info("You were signed out after a period of inactivity. Sign in again to continue.");
        window.location.assign("/login");
      } else if (status === "warning") {
        setWarningSeconds(secondsLeft(now, lastActivity.current, limitMs));
      } else {
        setWarningSeconds(null);
      }
    };

    for (const name of ACTIVITY_EVENTS) window.addEventListener(name, touch, { passive: true });
    const timer = window.setInterval(() => void tick(), 5_000);
    void tick();
    return () => {
      for (const name of ACTIVITY_EVENTS) window.removeEventListener(name, touch);
      window.clearInterval(timer);
    };
  }, [signedIn, limitMs]);

  const stay = () => {
    const now = Date.now();
    lastActivity.current = now;
    lastWrite.current = now;
    writeLastActivity(window.localStorage, now);
    setWarningSeconds(null);
  };

  return (
    <Dialog open={warningSeconds !== null} onOpenChange={(open) => !open && stay()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Still there?</DialogTitle>
          <DialogDescription>
            For your security you will be signed out in {warningSeconds ?? 0} seconds because there
            has been no activity. Anything you have not saved will be lost.
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="hero" onClick={stay}>
            Stay signed in
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
