# Deploying SignalTwin

Two parts: the front end (static files) and the back end (a Python service that needs CPU, memory and disk). They are deployed separately and meet at one address, `VITE_API_URL`.

Nothing in this repository creates cloud resources, spends money or holds a secret. Every step below is something a person does.

## Front end on Vercel

The repository root is the Vite app and `vercel.json` already routes every path to `index.html`.

1. Import the repository at vercel.com/new (or `npx vercel login`, then `npx vercel --prod`).
2. Framework preset Vite, build command `npm run build`, output `dist`.
3. To use a back end, add the environment variable `VITE_API_URL` (for example `https://api.example.com`). It is read at build time and is not a secret: it is an address. Without it the app runs entirely in the browser.
4. Redeploy after changing it.

The browser blocks an `http://` back end from an `https://` page, so the back end needs HTTPS.

## Back end

### With Docker

```
cd signaltwin-api
cp .env.example .env        # set ALLOWED_ORIGINS to your front end's address
docker compose up --build
```

`Dockerfile` installs the CPU build of PyTorch, the API, and the small YOLO11n weights, runs as a non-root user, stores data in the `/data` volume and has a health check on `/v1/health`. It has not been built in this repository's own checks (no Docker on the author's machine), so expect to fix small things on first build.

### Sizing

Measured with YOLO11n on 8 CPU cores (`MEASUREMENTS.md`): about 145 ms per processed frame at 1280 px, which is 0.7 times real time. A 10 minute video takes about 14 minutes on that machine. Options, in order of effect: a GPU (`DEVICE=cuda:0`, use the default PyTorch index in the Dockerfile), a lower `TARGET_FPS`, a lower `MAX_PROC_WIDTH`. Memory peaked near 0.6 GB for the worker plus the API; the default memory cap per job is 6 GB.

`WORKERS=1` runs one analysis at a time; more workers need proportionally more CPU and memory. Jobs wait in a queue of `QUEUE_MAX`; beyond that the API answers 429 with `Retry-After`.

### What must be set in production

| Setting | Why |
| --- | --- |
| `ALLOWED_ORIGINS` | Only your front end may call the API from a browser. |
| `API_KEY` | Otherwise anyone who finds the address can upload and analyse. The key is a shared secret, not a login. |
| HTTPS in front of the API | The key and the videos travel over it. A reverse proxy (Caddy, nginx) or the host's TLS is enough. Turn off response buffering for `/v1/jobs/*/events`. |
| A volume for `DATA_DIR` | Videos, results and the job database live there. |
| `RETENTION_HOURS` | How long videos are kept. Match what the Privacy page says. |

Rate limits are kept in memory per process. Behind several containers use the proxy's rate limiting as well.

### Licence

Ultralytics YOLO is AGPL-3.0. See `signaltwin-api/README.md`.

## Demo day: the back end on your own computer, with a public address

This costs nothing and uses the back end exactly as it runs on your machine (models included). The computer must stay on, awake and online while you demo.

1. Start the back end so that only your Vercel site may call it, and a key is required:

   ```
   cd signaltwin-api
   $env:ALLOWED_ORIGINS = "https://YOUR-SITE.vercel.app,http://localhost:5173"
   $env:API_KEY = "a-long-random-secret-you-choose"
   .\.venv\Scripts\python.exe -m uvicorn signaltwin_api.main:app --host 127.0.0.1 --port 8000
   ```

   `ALLOWED_ORIGINS` must match the site's address exactly: https, no trailing slash. Add a custom domain too if you use one.
2. Give it an https address with a Cloudflare quick tunnel (no account needed). Install once with `winget install Cloudflare.cloudflared`, then in a second window run `cloudflared tunnel --url http://localhost:8000`. It prints an address like `https://something-random.trycloudflare.com`. The address changes every time you start it.
3. Open your Vercel site, click the **Back end** badge, paste that address and the key, and press Check again. The badge turns to Back end connected. Nothing needs redeploying, because the address is saved in that browser.
4. Test the whole path once before the demo: upload a short clip, analyse it, open Perception.

Anyone who has the address and the key can use your back end, so share the key only with people you trust and close the tunnel afterwards.

## A host that stays on

Use a small cloud server (Ubuntu 22.04, at least 2 CPUs and 4 GB of memory) with Docker.

1. `git clone` the repository, then `cd signaltwin-api` and `cp .env.example .env`. Set `ALLOWED_ORIGINS` and `API_KEY` in `.env`.
2. `docker compose up -d --build`. The first build downloads PyTorch (CPU) and the small model, which takes several minutes.
3. For the drone model: `mkdir extra-models`, put the `.pt` file in it (for example `visdrone-yolo11s.pt`), and `docker compose restart api`. It then appears in Setup's Camera view.
4. Put HTTPS in front. With a domain pointing at the server, Caddy is the shortest way. A `Caddyfile` of

   ```
   api.example.com {
     reverse_proxy localhost:8000 {
       flush_interval -1
     }
   }
   ```

   gets a certificate by itself. `flush_interval -1` keeps progress updates flowing. Open ports 80 and 443 on the server's firewall and keep 8000 closed.
5. In Vercel set `VITE_API_URL=https://api.example.com` and redeploy. Check the Back end badge.

The Docker setup has not been built here, so expect small fixes the first time.

## Supabase (optional)

The default storage is local disk plus SQLite, which is enough for one server. `STORAGE=supabase` keeps records in Postgres and files in Storage buckets, so the data survives the container.

**Nothing has been created.** The migration and the adapter are written and tested against an in-memory stand-in only; they have not been run against a live project. A person should decide whether to create one, because it can cost money:

- A free project is fine for trying this. Free projects pause after a week of inactivity and cap each stored file at 50 MB, so the bucket limit is 50 MB. For longer videos use a paid plan and raise the bucket's file size limit; the standard upload used here suits files up to a few hundred MB, and larger ones need the resumable upload protocol (not implemented).
- Check the plan and price in the Supabase dashboard (or ask Claude to read the cost before creating anything) and confirm before creating.

Steps once a project exists:

1. Apply `signaltwin-api/supabase/migrations/20261009000000_init.sql` (SQL editor, `supabase db push`, or the Supabase MCP `apply_migration`).
2. Run the security and performance advisors in the dashboard and fix anything they report. The migration enables row level security on every table, sets the function's `search_path`, revokes its public execute right, and indexes every foreign key, so the usual warnings should not appear; confirm rather than assume.
3. Set `STORAGE=supabase`, `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` on the **server only**. The service role key bypasses row level security: never put it in the front end, the repository or a `VITE_` variable.
4. Start the API. It checks that the schema exists and says so if it does not.

Row level security is on, but with one anonymous owner there are no signed-in users yet. The API reaches the tables with the service role. If accounts are added later the policies already match `auth.uid()`.
