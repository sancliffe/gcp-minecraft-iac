# gcp-minecraft

Run a **Minecraft Bedrock Edition** server on a Google Cloud Platform (GCP) virtual machine. Terraform provisions an `e2-micro` VM sized for GCP's Always Free tier, opens the firewall for Minecraft traffic, and the VM installs Docker and starts the [`itzg/minecraft-bedrock-server`](https://hub.docker.com/r/itzg/minecraft-bedrock-server) container by itself on first boot. One command (`make deploy`) takes you from a fresh clone to a running server, with no SSH step.

## What's in this repo

| File | Purpose |
| --- | --- |
| `terraform/main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` | Terraform for the VM, its static IP, service account, backup bucket, the SSH and Minecraft firewall rules, and and the instance metadata that carries `docker-compose.yml` and the allowlist to the VM |
| `terraform/minecraft.auto.tfvars.example` | Template for your project settings (`project_id`, `backup_bucket_name`). Copy it to `terraform/minecraft.auto.tfvars` (git-ignored) and **edit it for your own project**. Terraform loads that file automatically, so no `-var` flags are needed |
| `terraform/backend.tf` / `backend.hcl` | Remote Terraform state in a GCS bucket. The bucket name comes from `backup_bucket_name` in `minecraft.auto.tfvars` (via `scripts/terraform-init.sh`); `backend.hcl` holds the state prefix (see [Notes](#notes)) |
| `scripts/deploy.sh` | One-command deploy (`make deploy`): creates `minecraft.auto.tfvars` from your gcloud project if missing, creates the state/backup bucket if missing, runs `terraform init`, imports the bucket, then `terraform apply`. Safe to re-run |
| `scripts/startup.sh` | The VM's startup script, run as root on every boot: hardens sshd, adds swap, installs Docker and the Ops Agent, writes the server files, schedules the daily Cloud Storage backup (a systemd timer) and starts the server |
| `scripts/terraform-init.sh` | Runs `terraform init` with the state bucket read from `terraform/minecraft.auto.tfvars`. Use it instead of a bare `terraform init` if you deploy step by step |
| `scripts/lib.sh` | Helpers shared by the two scripts above (reads `minecraft.auto.tfvars`) |
| `docker-compose.yml` | Defines the Bedrock server container and its configuration |
| `data/` | `allowlist.json` seeds the VM's allowlist on first boot. `server.properties` is only used if you run Compose directly from a clone (see [Running Compose without Terraform](#running-compose-without-terraform)). World data is git-ignored |
| `scripts/backup.sh` | Takes a consistent local backup: stops the server, archives `data/`, restarts the server (see [Backups](#backups)) |
| `tests/` | `test-startup.sh` and `test-deploy.sh` run the startup and deploy scripts against stubbed commands, so they need no VM, GCP account or Terraform (`make test`) |
| `Makefile` | Shortcuts: `make deploy`, `ssh`, `logs`, `init`, `plan`, `apply`, `destroy`, `fmt`, `test`, and `make check` (format check, validate, ShellCheck and the script tests, as CI runs them) |
| `.github/workflows/terraform.yml` | CI: `terraform fmt`, `terraform validate`, TFLint, tfsec, ShellCheck and the script tests on every push and pull request, plus an optional deploy job (see [Notes](#notes)) |
| `.github/workflows/lock.yml` | Manually triggered workflow that creates or refreshes the provider lock file and opens a pull request (see [Provider lock file](#provider-lock-file)) |
| `LICENSE` | Apache License 2.0 |

## How it fits together

1. **`make deploy`** creates the state/backup bucket, then **Terraform** creates the VM (Debian 12, `e2-micro`, 30 GB standard disk), a static external IP, a dedicated service account and the two firewall rules (SSH and Minecraft). It passes `scripts/startup.sh`, `docker-compose.yml` and `data/allowlist.json` to the VM as instance metadata.
2. On first boot, the VM's **startup script** hardens sshd, creates a 1 GB swapfile, installs Docker Engine, the Compose plugin and `unattended-upgrades`, writes the server files to `/opt/minecraft`, schedules the daily backup, and starts the server. World data is stored in `/opt/minecraft/data`.
3. **You** wait a few minutes and join the server. No SSH session is needed.

## Prerequisites

- A GCP project with billing enabled
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.5 or newer (the Google provider `~> 6.0` is downloaded by `terraform init`)
- The [`gcloud` CLI](https://cloud.google.com/sdk/docs/install), authenticated (`gcloud auth login` and `gcloud auth application-default login`) with your project selected (`gcloud config set project <project-id>`)
- To SSH through IAP (the default) your user needs `roles/iap.tunnelResourceAccessor` and an OS Login role. Use `roles/compute.osAdminLogin` if you want `sudo` on the VM (needed for the console and backup commands below). `roles/compute.osLogin` alone gives no sudo access. SSH is optional for a normal deploy.

## Getting started

### 1. Deploy

```bash
git clone https://github.com/sancliffe/gcp-minecraft-iac.git
cd gcp-minecraft-iac
make deploy
```

`make deploy` runs `scripts/deploy.sh`, which is safe to re-run. It:

1. creates `terraform/minecraft.auto.tfvars` from your current `gcloud` project if the file is missing (or use the one you already edited);
2. enables the Cloud Storage API and creates the state/backup bucket if it doesn't exist (Terraform can't create the bucket that holds its own state);
3. runs `terraform init` against that bucket;
4. imports the bucket into the Terraform state if needed, so `apply` doesn't fail with `Error 409: ... you already own it`;
5. runs `terraform apply` and asks you to confirm. Use `make deploy YES=1` (or `scripts/deploy.sh --yes`) to skip the prompt.

Without `make`, run `./scripts/deploy.sh` directly. To use OpenTofu, set `TERRAFORM=tofu`.

When it finishes it prints the outputs: `minecraft_address` (what to type into Minecraft), `static_external_ip`, `instance_name`, `backup_bucket_name`, and `ssh_command_iap`. You can show them again at any time with `terraform -chdir=terraform output`.

To use a different project or bucket name, copy `terraform/minecraft.auto.tfvars.example` to `terraform/minecraft.auto.tfvars` and edit it before running `make deploy`. You can still override any value on the command line, e.g. `terraform -chdir=terraform apply -var project_id=<other-project>`.

#### Step by step instead

`make deploy` is a wrapper around these steps, if you prefer to run them yourself:

```bash
cp terraform/minecraft.auto.tfvars.example terraform/minecraft.auto.tfvars   # then edit it
gcloud storage buckets create gs://<bucket-name> --location=US --uniform-bucket-level-access --public-access-prevention
./scripts/terraform-init.sh
terraform -chdir=terraform import google_storage_bucket.minecraft_backups <bucket-name>
terraform -chdir=terraform apply
```

(`<bucket-name>` is the `backup_bucket_name` value, for example `steanlabs-web-minecraft-backups`. Skip the `gcloud storage buckets create` and `import` steps if Terraform already manages the bucket. Create the bucket in `US`, which matches `main.tf`, or Terraform will want to replace it.)

Terraform enables the other required APIs (Compute Engine, IAM, Cloud Resource Manager, Logging, Monitoring) and creates the resources.

#### What gets created

| Resource | Details |
| --- | --- |
| VM `free-tier-vm` | `e2-micro`, Debian 12, 30 GB `pd-standard` disk, Shielded VM (secure boot, vTPM, integrity monitoring), OS Login on, project-wide SSH keys blocked, serial port disabled, hardened sshd (see [SSH hardening](#ssh-hardening)), network tags `ssh` and `minecraft` |
| Static IP `minecraft-static-ip` | Reserved external IPv4 address (Standard tier), created only when `enable_external_ip = true` |
| Service account `free-tier-vm` | Has `roles/logging.logWriter` and `roles/monitoring.metricWriter` on the project, and `roles/storage.objectCreator` on the backup bucket. The VM's access scopes are narrowed to `logging-write`, `monitoring-write` and `storage-rw` instead of `cloud-platform` |
| Bucket `<project-id>-minecraft-backups` | Uniform access, public access prevented, object versioning on. World backups under `backups/` are deleted after 30 days (noncurrent versions after 1 more day); the last 10 versions of the Terraform state are kept |
| Firewall `free-tier-vm-allow-ssh` | TCP 22 from `ssh_source_ranges`, applied to VMs tagged `ssh` |
| Firewall `free-tier-vm-allow-minecraft` | TCP 19132, UDP 19132, 19133 and 19140-19150 from `minecraft_source_ranges` (default `0.0.0.0/0`), applied to VMs tagged `minecraft` |

#### Terraform variables

Grouped as in `terraform/variables.tf`. Set any of them in `terraform/minecraft.auto.tfvars`.

| Variable | Default | Description |
| --- | --- | --- |
| **Project and location** | | |
| `project_id` | *(required)* | GCP project ID |
| `region` | `us-central1` | Must be `us-west1`, `us-central1`, or `us-east1` (Always Free e2-micro regions) |
| `zone` | `<region>-a` | Zone inside the chosen region |
| **Backup bucket (also holds the Terraform state)** | | |
| `backup_bucket_name` | `<project_id>-minecraft-backups` | Cloud Storage bucket for world backups and Terraform state. The VM learns the name through instance metadata, so the daily backup goes to the right bucket |
| `bucket_location` | `US` | Location of the bucket. `deploy.sh` creates the bucket there, so it must match what Terraform expects or the bucket (and the state in it) would be replaced. Cloud Storage's Always Free tier only covers regional buckets in `us-west1`, `us-central1` and `us-east1`; `US` is kept as the default so existing deployments are not replaced |
| `bucket_force_destroy` | `false` | Let `terraform destroy` delete the bucket while it holds objects. Off by default because the bucket also stores the Terraform state (see [Tearing down](#tearing-down)) |
| **Networking and access** | | |
| `enable_external_ip` | `true` | Attach an external IPv4 address (Standard network tier). See the cost note below |
| `minecraft_source_ranges` | `["0.0.0.0/0"]` | CIDRs allowed to reach the Minecraft ports. The default suits a public server; narrow it to your players' addresses for a private one. Must be valid CIDRs |
| `ssh_source_ranges` | `["35.235.240.0/20"]` | CIDRs allowed to SSH. The default is Google's IAP range; add `<your-ip>/32` for direct SSH. Must be valid CIDRs, non-empty, and cannot include `0.0.0.0/0` or `::/0` |
| `require_os_login_2fa` | `false` | Require 2-step verification for OS Login SSH sessions. Everyone who needs SSH must have 2-step verification enabled on their Google account first, or they are locked out |
| **Instance** | | |
| `deletion_protection` | `false` | Blocks deleting the VM via the API or Terraform when `true` |

#### Cost notes

- The VM, 30 GB standard disk, and region fall within the Always Free tier, but **external IPv4 addresses are billed** and are not covered by it. Check [current GCP pricing](https://cloud.google.com/vpc/network-pricing#ipaddress) before you apply.
- Players need to reach the server over the internet, so for a public server keep `enable_external_ip = true`.
- Setting it to `false` leaves the VM with no outbound internet access (including `apt` and Docker image pulls) unless you add Cloud NAT, which has its own cost.

### 2. Join the server

Allow a few minutes after `make deploy` for the VM to install Docker and start the server. In Minecraft Bedrock Edition choose *Play → Servers → Add Server*, then enter the VM's external IP (the `static_external_ip` Terraform output) and port `19132`.

To watch the first boot: `make logs` (it follows the startup script over IAP; press Ctrl+C to stop).

The server runs with an allowlist (`ALLOW_LIST: "true"`), so only listed players can join. On first boot the VM's allowlist is seeded from `data/allowlist.json` in this repo, so add your players there **before** the first `make deploy`. The file is only seeded once, because the server edits it when you run `allowlist add`. To add a player to a running server:

```bash
make ssh        # SSH to the VM through IAP
sudo docker exec bedrock-server send-command allowlist add <gamertag>
```

### 3. Connect to the VM (optional)

`make ssh` runs the IAP command Terraform prints, equivalent to:

```bash
gcloud compute ssh free-tier-vm --zone us-central1-a --project <your-project-id> --tunnel-through-iap
```

To check that the startup script finished: `docker --version && docker compose version`, or `sudo journalctl -u google-startup-scripts -f` for its log. The server files live in `/opt/minecraft`.

### Running Compose without Terraform

If you already have a Docker host, clone the repo there and run `sudo docker compose up -d`. In that case the server uses `data/server.properties` and `data/allowlist.json` from the clone.

## SSH hardening

SSH access is locked down in several layers:

- **Network:** the SSH firewall rule only allows `ssh_source_ranges` (Google's IAP range by default). Terraform refuses to apply if the list is empty, malformed, or contains `0.0.0.0/0` / `::/0`.
- **Identity:** OS Login is on and project-wide SSH keys are blocked, so access is controlled by IAM roles rather than keys scattered across the project. Optionally set `require_os_login_2fa = true` to require 2-step verification.
- **Serial console:** interactive serial port access is disabled.
- **sshd:** the startup script writes `/etc/ssh/sshd_config.d/10-hardening.conf` to disable root login, password authentication, empty passwords, X11 and agent forwarding, and to limit auth attempts to 3 with a 30 second login grace time. The config is checked with `sshd -t` before sshd reloads, and removed if it doesn't validate, so a bad config can't lock you out.

The sshd settings apply on the next boot of an existing VM (or when you reapply and restart it). Verify with `sudo sshd -T | grep -Ei 'permitrootlogin|passwordauthentication|maxauthtries'`. Direct SSH (not through IAP) is still possible by adding `<your-ip>/32` to `ssh_source_ranges`.

## Server configuration

The defaults in `docker-compose.yml` are:

| Setting | Value | Description |
| --- | --- | --- |
| `image` | `itzg/minecraft-bedrock-server:latest` | Bedrock server image |
| `container_name` | `bedrock-server` | Name of the running container |
| `restart` | `unless-stopped` | Container restarts automatically after crashes or VM reboots |
| `network_mode` | `host` | Container shares the VM's network, so no `ports:` mapping is needed |
| `logging` | `json-file`, 10 MB x 3 files | Rotates container logs so they can't fill the boot disk |
| `EULA` | `TRUE` | Accepts the [Minecraft EULA](https://aka.ms/MinecraftEULA) (required to start) |
| `SERVER_NAME` | `Steanlabs Minecraft` | Server name shown in the game's server list |
| `DIFFICULTY` | `normal` | World difficulty |
| `GAMEMODE` | `survival` | Default game mode |
| `TRANSPORT` | `nethernet` | Transport setting passed to the server |
| `SERVER_PORT` | `19132` | IPv4 port the server listens on |
| `SERVER_PORT_V6` | `19133` | IPv6 port the server listens on |
| `SERVER_UDP_PORTS` | `19140-19150` | Additional UDP port range configured for the server |
| `ALLOW_LIST` | `true` | Only players on the allowlist can join (see [Join the server](#2-join-the-server)) |
| `OPS` | `superflea2828` | Gamertag(s) of server operators, resolved to XUIDs at startup |
| `VIEW_DISTANCE` | `10` | View distance in chunks |
| `TICK_DISTANCE` | `4` | Simulation distance in chunks |
| `MAX_THREADS` | `2` | Maximum threads the server uses |
| `./data:/data` | volume | World data and server files persist in `./data` next to the compose file (`/opt/minecraft/data` on the VM) |

To change any of these, edit the `environment:` section of `docker-compose.yml` in this repo and run `make deploy`. That updates the VM's instance metadata; the VM picks the change up on its next boot, or immediately if you run `sudo google_metadata_script_runner startup` on it (`make ssh` first). The startup script rewrites `/opt/minecraft/docker-compose.yml` from the repo's copy and runs `docker compose up -d`, so edits made directly on the VM are overwritten. See the [image documentation](https://github.com/itzg/docker-minecraft-bedrock-server) for the full list of supported variables.

The firewall rule created by Terraform covers the default ports above. If you change `SERVER_PORT`, `SERVER_PORT_V6`, or `SERVER_UDP_PORTS`, update the ports in the `google_compute_firewall.minecraft` resource in `terraform/main.tf` and run `terraform -chdir=terraform apply` again. With `network_mode: host`, the container's ports are the VM's ports.

## Common operations

Run these on the VM (`make ssh`) from `/opt/minecraft`, the directory that holds the compose file:

```bash
cd /opt/minecraft

# View server logs
sudo docker compose logs -f

# Stop the server
sudo docker compose down

# Update to the latest image and restart
sudo docker compose pull && sudo docker compose up -d

# Run a command in the server console
sudo docker exec bedrock-server send-command <command>
```

## Backups

All world data lives in `/opt/minecraft/data` on the VM.

The startup script installs `/usr/local/bin/minecraft-backup` and a systemd timer (`minecraft-backup.timer`) that runs it daily at 4:00 AM VM time (UTC). It archives `data/` and uploads it to `gs://<project-id>-minecraft-backups/backups/world-backup-<date>-<time>.tar.gz`. Backups older than 30 days are deleted by the bucket's lifecycle rule. Check the schedule and the last run with:

```bash
systemctl list-timers minecraft-backup.timer
sudo journalctl -u minecraft-backup.service
sudo systemctl start minecraft-backup.service    # run a backup right now
```

The backup runs while the server is up, so a world being written at that moment could be captured inconsistently. For a guaranteed-consistent copy (for example before an upgrade), use `scripts/backup.sh`. It stops the server, writes `minecraft-backup-<timestamp>.tar.gz` into the server directory, and always starts the server again, even if archiving fails:

```bash
# copy the script to the VM, then run it there
gcloud compute scp scripts/backup.sh free-tier-vm:~ --zone us-central1-a --project <your-project-id> --tunnel-through-iap
bash ~/backup.sh            # defaults to /opt/minecraft
```

This archive stays on the VM's disk. Copy it to Cloud Storage yourself if you want to keep it, e.g. `gcloud storage cp /opt/minecraft/minecraft-backup-*.tar.gz gs://<bucket>/manual/` (the Terraform lifecycle rule only expires objects under `backups/`).

To restore, download an archive with `gcloud storage cp gs://<project-id>-minecraft-backups/backups/<file> .`, stop the server, and extract it over `/opt/minecraft/data`.

## Tearing down

If you turned on `deletion_protection`, turn it off first. The backup bucket also holds the Terraform state, so `bucket_force_destroy` is `false` by default and `terraform destroy` stops at the bucket instead of deleting every backup and **the Terraform state stored under `terraform/state`**. To remove everything, download any backups you want to keep, then opt in explicitly (the same values are needed for `destroy`):

```bash
terraform -chdir=terraform apply   -var deletion_protection=false -var bucket_force_destroy=true
terraform -chdir=terraform destroy -var deletion_protection=false -var bucket_force_destroy=true
```

Destroying the bucket also deletes the state Terraform is using. If you want a clean teardown, migrate the state to a local backend first (remove the `backend "gcs"` block in `backend.tf`, then `terraform -chdir=terraform init -migrate-state`).

The boot disk is deleted along with the VM.

## Upgrading an existing VM

If your server was started with the old `setup-vm.sh` (world in `~/minecraft-bedrock`), upgrading keeps the world:

1. Take a backup first: run your existing `~/minecraft-bedrock/backup.sh` once, or copy `~/minecraft-bedrock/data` somewhere safe.
2. Run `make deploy` and read the plan before confirming. Only the VM's metadata and startup script should change in place; if the plan wants to destroy and recreate the VM, stop and check why.
3. On the VM (`make ssh`), run `sudo google_metadata_script_runner startup` (or reboot). The startup script stops the old container, moves `~/minecraft-bedrock/data` to `/opt/minecraft/data`, and starts the server from there.
4. Remove the old cron backup, which points at the old directory: `crontab -l | grep -v 'minecraft-bedrock/backup.sh' | crontab -`. The new systemd timer replaces it. You can then delete what is left of `~/minecraft-bedrock`.

## Plan on pull requests

CI can run `terraform plan` on every pull request and post the result as a comment (updated on each push). It is a dry run: nothing is applied, and it takes no state lock. It needs **read-only** credentials of its own, and it is skipped (with a notice in the run) until you set them up, so CI stays green without them. It also skips pull requests from forks, which get no secrets.

Create a read-only service account once. The roles are my best reading of what a plan needs; if the first run reports a missing permission, grant that one:

```bash
PROJECT=<your-project-id>; BUCKET=<your-backup-bucket>
gcloud iam service-accounts create minecraft-tf-plan --project "$PROJECT"
SA="minecraft-tf-plan@$PROJECT.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$PROJECT" --member "serviceAccount:$SA" --role roles/viewer
gcloud projects add-iam-policy-binding "$PROJECT" --member "serviceAccount:$SA" --role roles/iam.securityReviewer
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" --member "serviceAccount:$SA" --role roles/storage.objectViewer
```

Then give GitHub the credentials, using either option:

| Option | What to set in the repository |
| --- | --- |
| **Service account key** | Secret `GCP_PLAN_SA_KEY` (the JSON key): `gcloud iam service-accounts keys create key.json --iam-account "$SA"`, then `gh secret set GCP_PLAN_SA_KEY < key.json` and delete `key.json` |
| **Workload identity federation** (no stored key, preferred) | Variables `GCP_WORKLOAD_IDENTITY_PROVIDER` and `GCP_SERVICE_ACCOUNT`, and also `GCP_PROJECT_ID`, which federation cannot infer. See [google-github-actions/auth](https://github.com/google-github-actions/auth#preferred-direct-workload-identity-federation) for creating the pool and provider |

`GCP_PROJECT_ID` and `BACKUP_BUCKET_NAME` (variables) work as they do for the deploy job. The plan job never uses the deploy key `GCP_SA_KEY`: pull request code runs with these credentials, so keep this account read-only.

## Provider lock file

`terraform/.terraform.lock.hcl` pins the exact Google provider version and checksums. Create it by running the **Update provider lock file** workflow from the Actions tab (Run workflow), or `make lock` locally. The workflow needs no GCP credentials. If the file changes it opens a pull request; that needs *Settings, Actions, General, Allow GitHub Actions to create and approve pull requests*, otherwise it still pushes the branch `chore/update-lock-file` for you to open a PR from. Checks don't start automatically on a pull request that a workflow opened, so close and reopen it. Once the file is committed, CI initialises with `-lockfile=readonly` and fails if the providers would change.

## Notes

- **Memory is tight.** An `e2-micro` has 1 GB of RAM. The startup script adds a 1 GB swapfile, but expect the server to struggle with many players or a large view distance.
- **The startup script runs on every boot.** It is safe to re-run: it only creates the swapfile and installs Docker if they are missing, refreshes `docker-compose.yml` from instance metadata, and leaves the allowlist and world data alone.
- The compose file uses the `latest` image tag, so `docker compose pull` may bring in a newer Bedrock server version. Pin a specific tag if you want to control upgrades.
- The Minecraft firewall rule is open to `0.0.0.0/0` by default. That's needed for a public server; set `minecraft_source_ranges` to narrow it if only certain people play.
- **Provider versions:** `terraform/versions.tf` constrains the Google provider to `~> 6.0`. For fully reproducible runs, create `terraform/.terraform.lock.hcl` with `make lock` or the *Update provider lock file* workflow (see [Provider lock file](#provider-lock-file)) and commit it. It pins the exact version and checksums for Linux, macOS and Windows, and Terraform and CI then use it automatically.
- The VM uses a reserved static external IP, so the server address survives stop/start cycles. Remember that external IPv4 addresses are billed.
- `terraform/main.tf` assumes the `default` VPC network exists in your project.
- **Remote state:** Terraform state is stored in the same bucket that `terraform/main.tf` manages for backups. Terraform backends can't read variables or `.tfvars` files, so `./scripts/terraform-init.sh` reads `backup_bucket_name` from `terraform/minecraft.auto.tfvars` (falling back to `<project_id>-minecraft-backups`) and passes it to `terraform init` as `-backend-config="bucket=..."`; the state prefix comes from `terraform/backend.hcl`. Extra arguments are forwarded, e.g. `./scripts/terraform-init.sh -reconfigure`. For your own project you only need to edit `terraform/minecraft.auto.tfvars`. Run a bare `terraform -chdir=terraform init` and Terraform will prompt for the bucket instead. See [If the backup bucket already exists](#if-the-backup-bucket-already-exists) for the first-deploy order. Only objects under `backups/` expire, so the state is not aged out.
- **CI** (`.github/workflows/terraform.yml`): the validate job runs `terraform init -backend=false` inside `terraform/`, so it needs no GCP credentials and does not run `terraform plan`. It then runs `terraform fmt -check`, `terraform validate`, TFLint and tfsec; a separate job runs ShellCheck on `scripts/*.sh` and `tests/*.sh` and then the script tests. Run `make check` locally for the format, validate, ShellCheck and script-test steps (or `make test` for just the tests). Pull requests also get a `terraform plan` comment once plan credentials are set (see [Plan on pull requests](#plan-on-pull-requests)). The few `tfsec:ignore` comments in `terraform/main.tf` each say why (public game port, external IP, and no customer-managed encryption keys on a free-tier server).
- **Automatic deploy:** on every push to `main`, once the checks pass, CI runs `terraform apply -auto-approve`. It needs the repository secret `GCP_SA_KEY` (a service account key as JSON). The project defaults to the one the key belongs to; set the repository variable `GCP_PROJECT_ID` to override it. The state bucket defaults to `<project_id>-minecraft-backups`; set `BACKUP_BUCKET_NAME` to override it. Without the secret the deploy job is skipped (with a notice in the run), so you can deploy by hand and keep CI green.

## License

Licensed under the [Apache License 2.0](LICENSE).