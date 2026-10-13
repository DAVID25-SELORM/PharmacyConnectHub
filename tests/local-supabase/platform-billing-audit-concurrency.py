"""Local-only overlapping activation/commission updates. Never targets a hosted database."""
import subprocess, sys
C = 'supabase_db_drugxone-local-validation'
D = sys.argv[1] if len(sys.argv)>1 else 'billing_audit_20261013'
if not D.startswith('billing_audit_'): raise SystemExit('Use an isolated billing_audit_ database')
cmd=['docker','exec','-i',C,'psql','-U','postgres','-d',D,'-At','-v','ON_ERROR_STOP=1']
def run(sql):
 r=subprocess.run(cmd,input=sql,text=True,capture_output=True)
 if r.returncode: raise RuntimeError(r.stderr)
 return r.stdout.strip()
def race(first,second):
 a=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 a.stdin.write("BEGIN; SET LOCAL statement_timeout='15s'; "+first+"; SELECT 'READY'; SELECT pg_sleep(2); COMMIT;")
 a.stdin.close()
 while True:
  line=a.stdout.readline()
  if line.strip()=='READY': break
  if not line: raise RuntimeError(a.stderr.read())
 b=subprocess.run(cmd,input="SET statement_timeout='15s'; "+second+';',text=True,capture_output=True,timeout=20)
 a.wait(timeout=20)
 if a.returncode: raise RuntimeError(a.stderr.read())
 if b.returncode==0: raise AssertionError('Conflicting transaction unexpectedly succeeded')
 if 'commission' not in b.stderr.lower(): raise AssertionError(b.stderr)
 if run("SELECT (b.mode='active' AND p.platform_fee_bps<>0)::text FROM billing_settings b CROSS JOIN payments_settings p")!='false': raise AssertionError('conflicting final state')
 print('PASS: concurrent conflicting update rejected')
original=run('SELECT mode FROM billing_settings WHERE id')
try:
 run("UPDATE billing_settings SET mode='disabled' WHERE id; UPDATE payments_settings SET platform_fee_bps=0 WHERE id")
 race("SELECT set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000001',true); SELECT public.admin_billing_activate_platform(TRUE,'ACTIVATE BILLING','Concurrent audit activation')", "UPDATE payments_settings SET platform_fee_bps=100 WHERE id")
 run("UPDATE billing_settings SET mode='disabled' WHERE id")
 race("UPDATE payments_settings SET platform_fee_bps=100 WHERE id", "SELECT set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000001',false); SELECT public.admin_billing_activate_platform(TRUE,'ACTIVATE BILLING','Concurrent audit activation')")
finally:
 run("UPDATE billing_settings SET mode='disabled' WHERE id; UPDATE payments_settings SET platform_fee_bps=0 WHERE id; UPDATE billing_settings SET mode='"+original+"' WHERE id")
