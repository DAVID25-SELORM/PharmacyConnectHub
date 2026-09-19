# Production deployment

Production is connected to the `main` branch of:

`https://github.com/DAVID25-SELORM/PharmacyConnectHub`

The Vercel project is `pharmacy-connect-hub`, which serves `drugxone.com`.

For production changes, work from this repository and push to `origin/main`:

```powershell
git switch main
git pull --ff-only origin main
git push origin main
```

Feature and hotfix branches create preview deployments only. Do not use the
unrelated `yingoh` Vercel project for this application. Verify the Vercel
deployment is Ready before announcing a production change.
