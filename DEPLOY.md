# Deploying VisionTemplate to a VPS

This guide sets up a Docker Compose stack on a Linux VPS that:

1. Runs the app + Postgres.
2. **Rebuilds on every push** to `main` (via GitHub Actions → SSH).
3. **Rolls back automatically** to the previous image if the new build is unhealthy.
4. **Backs up Postgres daily** (via a scheduled GitHub Actions cron).

---

## 0. Requirements

- A Linux VPS with:
  - **Docker Engine** + **Docker Compose v2** (`docker compose` — check with `docker compose version`).
    The bundled playbook installs Docker **and** provisions everything the deploy
    workflow needs (a `deploy` user with docker-group membership, passwordless
    sudo, `/srv/visiontemplate`, and SSH access copied from root):
    ```bash
    cd ansible
    cp inventory.example inventory      # edit: set ansible_host / ansible_user (root, first time)
    ansible-playbook -i inventory install-docker.yml -K
    ```
  - **git** and your SSH public key access.
  - TCP 80/443 (or whatever `APP_PORT` you expose) open.
- A **deploy key** or HTTPS credentials on the VPS so it can `git fetch` this repo
  (read access is enough — `deploy.sh` uses `git reset --hard origin/main`).

## 1. First-time setup on the VPS

```bash
git clone <your-repo-url> /srv/visiontemplate
cd /srv/visiontemplate
cp .env.example .env
# Edit .env: set a strong POSTGRES_PASSWORD, matching DATABASE_URL, etc.
```

Bring the whole stack up the first time (this creates the Postgres data volume
and runs `db/setup.sql` to seed the `notes` table):

```bash
docker compose up -d --build
# Watch the app come up:
docker compose logs -f app
```

Visit `http://127.0.0.1:3000/api/ping` on the VPS — you should see `{"pong":true,...}`.

### Public site (Caddy + automatic HTTPS)

Caddy fronts the app on ports 80/443 and auto-provisions a Let's Encrypt cert for
`DOMAIN` (default `visiontemplate.watchtoken.org`). The app itself is bound to
`127.0.0.1` only, so Caddy is the sole public entry point. Before bringing Caddy
up, make sure:

1. **DNS** — an A record for `DOMAIN` points at the VPS IP, and
2. **Ports** 80 and 443 are open on the VPS firewall (Caddy needs 80 for the
   ACME HTTP-01 challenge and the HTTP→HTTPS redirect, 443 for HTTPS).

Once DNS resolves, `docker compose up -d caddy` and visit
`https://<DOMAIN>/api/ping`. If TLS provisioning fails, check DNS and firewall,
then `docker compose logs -f caddy`.

## 2. Register the deploy secret on GitHub

In the repo: **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Example | Purpose |
| --- | --- | --- |
| `SSH_HOST` | `203.0.113.10` | VPS address |
| `SSH_USER` | `deploy` | The deploy user created by `ansible/install-docker.yml` |
| `SSH_KEY` | *(PEM private key)* | Matches an entry in `~deploy/.ssh/authorized_keys` |
| `SSH_PORT` | `22` | SSH port |
| `DEPLOY_PATH` | `/srv/visiontemplate` | Absolute path to the checkout on the host (created by the playbook) |

Create the keypair on your laptop, **add the public key to the VPS**
(`~/.ssh/authorized_keys` for `SSH_USER`), and paste the **private** key as
`SSH_KEY`.

## 3. Push-to-deploy + auto-rollback

Now any push to `main` triggers `.github/workflows/deploy.yml`, which:

1. SSHs into the VPS,
2. `git fetch` + `git reset --hard origin/main`,
3. runs `scripts/deploy.sh`:

   - Builds `visiontemplate-app:git-<sha>`.
   - Recreates **only** the `app` container (`db` keeps running).
   - Waits up to 90s for the Docker healthcheck (`GET /api/ping`) to pass.
   - On success: records the new sha in `.deploy-state` and prunes dangling images.
   - **On failure: rolls back** to the tag stored in `.deploy-state`, verifies it
     goes healthy again, and saves the failed container's logs to
     `deploy-failure-git-<sha>.log`.

Because of `concurrency: { cancel-in-progress: false }`, concurrent pushes queue
rather than racing a deploy against its own rollback.

> Rollback needs a *previous* good build to return to. The very first deploy has
> nothing to roll back to, so do the first deploy via step 1 (or accept the first
> Actions run has no rollback safety net).

## 4. Daily Postgres backups

`.github/workflows/backup.yml` runs daily at **04:17 UTC** and calls
`scripts/backup-db.sh`, which:

- `pg_dump`s the running db into the `db_backups` volume
  (`/backups/vision_template-<timestamp>.sql.gz`),
- verifies the dump is non-empty,
- prunes dumps older than `BACKUP_KEEP` days (default **14** — set in `.env`).

You can also trigger it manually: **Actions → Daily DB backup → Run workflow**.

Restore a dump:

```bash
docker compose exec -T db sh -c \
  'gunzip -c /backups/vision_template-<ts>.sql.gz | psql -U "$POSTGRES_USER" "$POSTGRES_DB"'
```

Or copy one off the server:

```bash
docker compose cp db:/backups/vision_template-<ts>.sql.gz ./
```

## 5. Useful commands on the VPS

```bash
cd /srv/visiontemplate

# Status
docker compose ps

# Tail logs
docker compose logs -f app
docker compose logs -f db

# Manual deploy / rollback from the current checkout
./scripts/deploy.sh

# Manual backup
./scripts/backup-db.sh

# Shell into the database
docker compose exec db psql -U "$POSTGRES_USER" "$POSTGRES_DB"
```

## 6. Variables

| Variable | Default | Used by |
| --- | --- | --- |
| `POSTGRES_USER` | `vision` | db container, `DATABASE_URL` |
| `POSTGRES_PASSWORD` | `visionpass` | db container — **change this** |
| `POSTGRES_DB` | `vision_template` | db container |
| `DATABASE_URL` | `postgresql://vision:visionpass@db:5432/vision_template` | app |
| `PORT` | `3000` | app (inside container) |
| `APP_PORT` | `3000` | host port published on `127.0.0.1` (behind Caddy) |
| `DOMAIN` | `visiontemplate.watchtoken.org` | public hostname Caddy serves + TLS for |
| `IMAGE_TAG` | `git-<sha>` | which image `deploy.sh` builds/runs |
| `BACKUP_KEEP` | `14` | backup retention in days |
| `HEALTH_TIMEOUT` | `90` | seconds before a deploy is considered failed |
