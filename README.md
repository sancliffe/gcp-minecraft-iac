# gcp-minecraft

Run a **Minecraft Bedrock Edition** server on a Google Cloud Platform (GCP) virtual machine. Terraform provisions an `e2-micro` VM sized for GCP's Always Free tier, opens the firewall for Minecraft traffic, and the VM installs Docker and starts the custom Bedrock server container by itself on first boot. The image, [`superflea2828/gcp-custom-bedrock-server`](https://hub.docker.com/r/superflea2828/gcp-custom-bedrock-server), is built and published from [sancliffe/gcp-custom-bedrock-server](https://github.com/sancliffe/gcp-custom-bedrock-server). One command (`make deploy`) takes you from a fresh clone to a running server, with no SSH step.

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/sancliffe/gcp-minecraft-iac&cloudshell_workspace=.&show=terminal)

## What's in this repo

| File | Purpose |
| --- | --- |
| `terraform/main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` | Terraform for the VM, its static IP, service account, backup bucket, the SSH and Minecraft firewall rules, and the instance metadata that carries `docker-compose.yml`, `server.properties` and the allowlist to the VM |
| `terraform/minecraft.auto.tfvars.example` | Template for your project settings (`project_id`, `backup_bucket_name`). Copy it to `terraform/minecraft.auto.tfvars` (git-ignored) and **edit it for your own project**. Terraform loads that file automatically, so no `-var` flags are needed |
| `terraform/backend.tf` | Terraform state is a local file, `terraform/terraform.tfstate`, on the machine that deploys (Cloud Shell). See [Terraform state](#terraform-state) |
| `scripts/deploy.sh` | One-command deploy (`make deploy`): creates `minecraft.auto.tfvars` from your gcloud project if missing, runs `terraform init`, guards against lost state, imports an existing backup bucket, then `terraform apply`. Safe to re-run |
| `scripts/startup.sh` | The VM's startup script, run as root on every boot: hardens sshd, adds swap, installs Docker and the Ops Agent, writes the server files, schedules the daily Cloud Storage backup (a systemd timer), pulls the image and starts the server |
| `scripts/lib.sh` | Helper used by `deploy.sh` (reads `minecraft.auto.tfvars`) |
| `docker-compose.yml` | Defines the Bedrock server container. The image comes from the `server_image` variable (see [Container image](#container-image)) |
| `data/` | `server.properties` holds all server settings and is delivered to the VM on every boot. `allowlist.json` seeds the VM's allowlist on first boot. World data is git-ignored |
| `scripts/backup.sh` | Takes a consistent local backup: stops the server, archives `data/`, restarts the server (see [Backups](#backups)) |
| `tests/` | `test-startup.sh` and `test-deploy.sh` run the startup and deploy scripts against stubbed commands, so they need no VM, GCP account or Terraform (`make test`) |
| `Makefile` | Shortcuts: `make deploy`, `ssh`, `logs`, `init`, `plan`, `apply`, `destroy`, `fmt`, `test`, and `make check` (format check, validate, ShellCheck and the script tests, as CI runs them) |
| `.github/workflows/terraform.yml` | CI: `terraform fmt`, `terraform validate`, TFLint, tfsec, ShellCheck and the script tests on every push and pull request, plus a `terraform plan` comment on pull requests (see [Plan on pull requests](#plan-on-pull-requests)). CI never applies |
| `.github/workflows/lock.yml` | Manually triggered workflow that creates or refreshes the provider lock file and opens a pull request (see [Provider lock file](#provider-lock-file)) |
| `LICENSE` | Apache License 2.0 |

## How it fits together

1. **Image:** [gcp-custom-bedrock-server](https://github.com/sancliffe/gcp-custom-bedrock-server) builds the server image and publishes it to Docker Hub with a Bedrock-version tag, an immutable `sha-` tag and `latest`.
2. **`make deploy`**, run in Google Cloud Shell, has **Terraform** create the VM (Debian 12, `e2-micro`, 30 GB standard disk), a static external IP, a dedicated service account, the backup bucket and the two firewall rules (SSH and Minecraft). It passes `scripts/startup.sh`, `docker-compose.yml`, `data/server.properties`, `data/allowlist.json` and the image reference to the VM as instance metadata.
3. On every boot, the VM's **startup script** hardens sshd, creates a 1 GB swapfile, installs Docker Engine, the Compose plugin and `unattended-upgrades`, writes the server files to `/opt/minecraft`, schedules the daily backup, pulls the image and starts the server. World data is stored in `/opt/minecraft/data`.
4. **You** wait a few minutes and join the server. No SSH session is needed.

## Prerequisites

The easiest place to deploy from is **Google Cloud Shell** (the *Open in Cloud Shell* button above). It already has `gcloud` (signed in, with a project selected) and `terraform`, and Terraform uses its credentials automatically, so there is nothing to install.

- A GCP project with billing enabled, selected with `gcloud config set project <project-id>` (Cloud Shell usually has one selected already)
- Elsewhere, install [Terraform](https://developer.hashicorp.com/terraform/install) 1.5 or newer (the Google provider `~> 6.0` is downloaded by `terraform init`) and the [`gcloud` CLI](https://cloud.google.com/sdk/docs/install), then run `gcloud auth login` and `gcloud auth application-default login`
- To SSH through IAP (the default) your user needs `roles/iap.tunnelResourceAccessor` and an OS Login role. Use `roles/compute.osAdminLogin` if you want `sudo` on the VM (needed for the console and backup commands below). `roles/compute.osLogin` alone gives no sudo access. SSH is optional for a normal deploy.

## Getting started

### 1. Deploy

In Cloud Shell (or any shell with the prerequisites):

```bash
git clone https://github.com/sancliffe/gcp-minecraft-iac.git
cd gcp-minecraft-iac
make deploy
```

`make deploy` runs `scripts/deploy.sh`, which is safe to re-run. It:

1. creates `terraform/minecraft.auto.tfvars` from your current `gcloud` project if the file is missing (or use the one you already edited);
2. runs `terraform init`. The state is a local file, so this needs no bucket;
3. guards against lost state: if the local state is empty it restores the copy that older versions of this repo kept in the bucket, and if the VM already exists with no state to restore it stops with an explanation instead of failing with `409 already exists` errors (see [Terraform state](#terraform-state));
4. imports the backup bucket if it already exists but is not in the state;
5. runs `terraform apply` and asks you to confirm. Use `make deploy YES=1` (or `scripts/deploy.sh --yes`) to skip the prompt.

Without `make`, run `./scripts/deploy.sh` directly. To use OpenTofu, set `TERRAFORM=tofu`.

When it finishes it prints the outputs: `minecraft_address` (what to type into Minecraft), `static_external_ip`, `instance_name`, `server_image`, `backup_bucket_name`, and `ssh_command_iap`. You can show them again at any time with `terraform -chdir=terraform output`.

To use a different project or bucket name, or to pin the image, copy `terraform/minecraft.auto.tfvars.example` to `terraform/minecraft.auto.tfvars` and edit it before running `make deploy`. You can still override any value on the command line, e.g. `terraform -chdir=terraform apply -var project_id=<other-project>`.

#### Step by step instead

`make deploy` is a wrapper around these steps, if you prefer to run them yourself:

```bash
cp terraform/minecraft.auto.tfvars.example terraform/minecraft.auto.tfvars   # then edit it
terraform -chdir=terraform init
terraform -chdir=terraform apply
```

If the backup bucket already exists, import it first: `terraform -chdir=terraform import google_storage_bucket.minecraft_backups <bucket-name>`. Terraform enables the required APIs (Compute Engine, IAM, Cloud Resource Manager, Logging, Monitoring, Cloud Storage) and creates the resources.

#### What gets created

| Resource | Details |
| --- | --- |
| VM `free-tier-vm` | `e2-micro`, Debian 12, 30 GB `pd-standard` disk, Shielded VM (secure boot, vTPM, integrity monitoring), OS Login on, project-wide SSH keys blocked, serial port disabled, hardened sshd (see [SSH hardening](#ssh-hardening)), network tags `ssh` and `minecraft` |
| Static IP `minecraft-static-ip` | Reserved external IPv4 address (Standard tier), created only when `enable_external_ip = true` |
| Service account `free-tier-vm` | Has `roles/logging.logWriter` and `roles/monitoring.metricWriter` on the project, and `roles/storage.objectCreator` on the backup bucket. The VM's access scopes are narrowed to `logging-write`, `monitoring-write` and `storage-rw` instead of `cloud-platform` |
| Bucket `<project-id>-minecraft-backups` | Uniform access, public access prevented, versioning off. World backups under `backups/` are deleted after 30 days. It holds backups only, not Terraform state |
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
| **Backup bucket** | | |
| `backup_bucket_name` | `<project_id>-minecraft-backups` | Cloud Storage bucket for world backups. Terraform creates it (`deploy.sh` imports it first if it already exists). The VM learns the name through instance metadata, so the daily backup goes to the right bucket |
| `bucket_location` | `US` | Location of the bucket. Changing it replaces the bucket and the backups in it. Cloud Storage's Always Free tier only covers regional buckets in `us-west1`, `us-central1` and `us-east1`; `US` is kept as the default so existing deployments are not replaced |
| `bucket_force_destroy` | `true` | Let `terraform destroy` delete the bucket while it holds backups, so destroy and re-deploy cycles work. Set `false` to make destroy refuse to delete backups (see [Tearing down](#tearing-down)) |
| **Networking and access** | | |
| `enable_external_ip` | `true` | Attach an external IPv4 address (Standard network tier). See the cost note below |
| `minecraft_source_ranges` | `["0.0.0.0/0"]` | CIDRs allowed to reach the Minecraft ports. The default suits a public server; narrow it to your players' addresses for a private one. Must be valid CIDRs |
| `ssh_source_ranges` | `["35.235.240.0/20"]` | CIDRs allowed to SSH. The default is Google's IAP range; add `<your-ip>/32` for direct SSH. Must be valid CIDRs, non-empty, and cannot include `0.0.0.0/0` or `::/0` |
| `require_os_login_2fa` | `false` | Require 2-step verification for OS Login SSH sessions. Everyone who needs SSH must have 2-step verification enabled on their Google account first, or they are locked out |
| **Server container** | | |
| `server_image` | `superflea2828/gcp-custom-bedrock-server:latest` | Image the VM runs, as `<repository>:<tag>`. See [Container image](#container-image) |
| **Instance** | | |
| `deletion_protection` | `false` | Blocks deleting the VM via the API or Terraform when `true` |

#### Cost notes

- The VM, 30 GB standard disk, and region fall within the Always Free tier, but **external IPv4 addresses are billed** and are not covered by it. Check [current GCP pricing](https://cloud.google.com/vpc/network-pricing#ipaddress) before you apply.
- Players need to reach the server over the internet, so for a public server keep `enable_external_ip = true`.
- Setting it to `false` leaves the VM with no outbound internet access (including `apt` and Docker image pulls) unless you add Cloud NAT, which has its own cost.

### 2. Join the server

Allow a few minutes after `make deploy` for the VM to install Docker and start the server. In Minecraft Bedrock Edition choose *Play → Servers → Add Server*, then enter the VM's external IP (the `static_external_ip` Terraform output) and port `19132`.

To watch the first boot: `make logs` (it follows the startup script over IAP; press Ctrl+C to stop).

The server runs with an allowlist (`allow-list=true` in `data/server.properties`), so only listed players can join. On first boot the VM's allowlist is seeded from `data/allowlist.json` in this repo, so add your players there **before** the first `make deploy`. Entries look like `{"name": "<gamertag>"}`. The file is only seeded once, because the server edits it. To add a player to a running server, either edit `/opt/minecraft/data/allowlist.json` on the VM and restart the container, or use the server console:

```bash
make ssh                          # SSH to the VM through IAP
sudo docker attach bedrock-server # server console; type: allowlist add <gamertag>
                                  # detach with Ctrl-p then Ctrl-q (not Ctrl-c, which stops the server)
```

To make yourself an operator, use the same console: `op <gamertag>`.

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

Two files in this repo configure the server, and both are copied to the VM on every boot (edit them here, not on the VM):

- **`data/server.properties`** holds every game setting: server name, difficulty, game mode, view and tick distance, `max-threads`, ports, the allowlist switch and so on. The image reads it as `/data/server.properties`. The custom image does not read environment variables, so there is no other place to set these.
- **`docker-compose.yml`** controls how the container runs:

| Setting | Value | Description |
| --- | --- | --- |
| `image` | `${MC_IMAGE}` | Comes from the `server_image` variable via `/opt/minecraft/.env` (see [Container image](#container-image)) |
| `container_name` | `bedrock-server` | Name of the running container |
| `restart` | `unless-stopped` | Container restarts automatically after crashes or VM reboots |
| `network_mode` | `host` | Container shares the VM's network, so no `ports:` mapping is needed |
| `stop_grace_period` | `30s` | Time the server gets to save the world when the container stops |
| `stdin_open`, `tty` | `true` | Keep the console attached so `docker attach bedrock-server` works |
| `logging` | `json-file`, 10 MB x 3 files | Rotates container logs so they can't fill the boot disk |
| `./data:/data` | volume | World data and server files persist in `./data` next to the compose file (`/opt/minecraft/data` on the VM) |

To change a setting, edit the file in this repo and run `make deploy`. That updates the VM's instance metadata; the VM picks the change up on its next boot, or immediately if you run `sudo google_metadata_script_runner startup` on it (`make ssh` first). The startup script rewrites `/opt/minecraft/docker-compose.yml` and `/opt/minecraft/data/server.properties` from the repo's copies and runs `docker compose up -d`, so edits made directly on the VM are overwritten. The allowlist and the world are never overwritten.

The firewall rule created by Terraform covers the default ports (TCP 19132, UDP 19132, 19133 and 19140-19150). If you change `server-port`, `server-portv6` or `server-udp-ports` in `server.properties`, update the ports in the `google_compute_firewall.minecraft` resource in `terraform/main.tf` and apply again. With `network_mode: host`, the container's ports are the VM's ports.

### Container image

The VM runs the image named by the `server_image` variable (default `superflea2828/gcp-custom-bedrock-server:latest`). The startup script writes it to `/opt/minecraft/.env`, runs `docker compose pull` and then `docker compose up -d` on every boot, so `latest` follows new builds whenever the VM reboots. If the pull fails (Docker Hub down), the server starts from the cached copy. The image repository publishes three kinds of tags:

| Tag | Moves? | Use it for |
| --- | --- | --- |
| `latest` | Every build of `main` | Always running the newest image |
| `<bedrock-version>`, e.g. `1.26.62.1` | When the image is rebuilt on the same Bedrock version | Staying on one Bedrock version while getting image fixes |
| `sha-<commit>` | Never | Fully reproducible deploys and easy rollback |

To pin a version, set it in `terraform/minecraft.auto.tfvars` (for example `server_image = "superflea2828/gcp-custom-bedrock-server:1.26.62.1"`) and run `make deploy`, then reboot the VM or run `sudo google_metadata_script_runner startup` on it. To roll back, set the previous `sha-` tag the same way. To update a `latest` VM right now without a deploy, reboot it or run `sudo docker compose pull && sudo docker compose up -d` in `/opt/minecraft`.

## Common operations

Run these on the VM (`make ssh`) from `/opt/minecraft`, the directory that holds the compose file:

```bash
cd /opt/minecraft

# View server logs
sudo docker compose logs -f

# Stop the server
sudo docker compose down

# Update to the newest image for the configured tag and restart
sudo docker compose pull && sudo docker compose up -d

# Open the server console (detach with Ctrl-p then Ctrl-q)
sudo docker attach bedrock-server
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

If you turned on `deletion_protection`, turn it off first. `bucket_force_destroy` is `true` by default, so `terraform destroy` also deletes every world backup in the bucket. Download any you want to keep first, or set `bucket_force_destroy = false` and apply, which makes destroy refuse to delete a bucket that still holds backups:

```bash
terraform -chdir=terraform apply   -var deletion_protection=false
terraform -chdir=terraform destroy -var deletion_protection=false
```

The boot disk is deleted along with the VM.

## Upgrading an existing VM

If your server was started with the old `setup-vm.sh` (world in `~/minecraft-bedrock`), upgrading keeps the world:

1. Take a backup first: run your existing `~/minecraft-bedrock/backup.sh` once, or copy `~/minecraft-bedrock/data` somewhere safe.
2. Run `make deploy` and read the plan before confirming. Only the VM's metadata and startup script should change in place; if the plan wants to destroy and recreate the VM, stop and check why.
3. On the VM (`make ssh`), run `sudo google_metadata_script_runner startup` (or reboot). The startup script stops the old container, moves `~/minecraft-bedrock/data` to `/opt/minecraft/data`, and starts the server from there.
4. Remove the old cron backup, which points at the old directory: `crontab -l | grep -v 'minecraft-bedrock/backup.sh' | crontab -`. The new systemd timer replaces it. You can then delete what is left of `~/minecraft-bedrock`.

**Switching from the old `itzg/minecraft-bedrock-server` image:** the world directory has the same layout, so the world carries over. The startup script hands `/opt/minecraft/data` to UID 999, the user the custom image runs as. Settings that used to be environment variables (`SERVER_NAME`, `VIEW_DISTANCE`, `OPS` and so on) are now in `data/server.properties`; operators are set from the console (`op <gamertag>`), since `OPS` is no longer read. Back up the world first.

## Plan on pull requests

CI can run `terraform plan` on every pull request and post the result as a comment (updated on each push). Terraform's state is a local file on the machine that deploys, so CI has nothing to compare against: **the plan runs against empty state and shows every resource as "to add"**. It verifies that the configuration resolves (variables, `file()` paths, the provider's schema), not drift from the running server. It never applies, and it takes no state lock. It needs **read-only** credentials of its own, and it is skipped (with a notice in the run) until you set them up, so CI stays green without them. It also skips pull requests from forks, which get no secrets.

Create a read-only service account once. Against empty state the plan makes almost no API calls, so `roles/viewer` should be enough; if the first run reports a missing permission, grant that one:

```bash
PROJECT=<your-project-id>
gcloud iam service-accounts create minecraft-tf-plan --project "$PROJECT"
SA="minecraft-tf-plan@$PROJECT.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$PROJECT" --member "serviceAccount:$SA" --role roles/viewer
```

Then give GitHub the credentials, using either option:

| Option | What to set in the repository |
| --- | --- |
| **Service account key** | Secret `GCP_PLAN_SA_KEY` (the JSON key): `gcloud iam service-accounts keys create key.json --iam-account "$SA"`, then `gh secret set GCP_PLAN_SA_KEY < key.json` and delete `key.json` |
| **Workload identity federation** (no stored key, preferred) | Variables `GCP_WORKLOAD_IDENTITY_PROVIDER` and `GCP_SERVICE_ACCOUNT`, and also `GCP_PROJECT_ID`, which federation cannot infer. See [google-github-actions/auth](https://github.com/google-github-actions/auth#preferred-direct-workload-identity-federation) for creating the pool and provider |

`GCP_PROJECT_ID` (a variable) is optional with a key, which carries its own project. Keep this account read-only: pull request code runs with these credentials.

## Terraform state

State is a local file, `terraform/terraform.tfstate`, on the machine that ran `make deploy`. In Cloud Shell it lives in your persistent home directory, which survives sessions but is deleted if Cloud Shell is reset or goes unused for a long time. The backup bucket holds world backups only. Keep the state file safe: it is the only record of what Terraform created. Copying it somewhere (for example `cp terraform/terraform.tfstate ~/tfstate-backup-$(date +%F)`) before risky changes is cheap insurance.

**Upgrading from an older version of this repo** that kept the state in the bucket: `make deploy` notices the empty local state, restores `gs://<bucket>/terraform/state/default.tfstate` into `terraform/terraform.tfstate`, and carries on.

### Lost Terraform state

If the VM exists but `terraform/terraform.tfstate` is gone (and there is no bucket copy), `make deploy` stops with an explanation, because applying would fail on every resource with `409 already exists`. Your options:

- **Restore a copy** of `terraform.tfstate` into `terraform/`, if you have one.
- **Start clean:** delete the old VM `free-tier-vm`, the static address `minecraft-static-ip`, the firewall rules `free-tier-vm-allow-ssh` and `free-tier-vm-allow-minecraft`, and the service account `free-tier-vm`, then run `make deploy`. Download your world backups from the bucket first; the world on the old VM's disk is lost with the VM.
- **Import** each resource with `terraform -chdir=terraform import <address> <id>`; see the [import documentation](https://developer.hashicorp.com/terraform/cli/import) and the resource names in `terraform/main.tf`.

## Provider lock file

`terraform/.terraform.lock.hcl` pins the exact Google provider version and checksums. Create it by running the **Update provider lock file** workflow from the Actions tab (Run workflow), or `make lock` locally. The workflow needs no GCP credentials. If the file changes it opens a pull request; that needs *Settings, Actions, General, Allow GitHub Actions to create and approve pull requests*, otherwise it still pushes the branch `chore/update-lock-file` for you to open a PR from. Checks don't start automatically on a pull request that a workflow opened, so close and reopen it. Once the file is committed, CI initialises with `-lockfile=readonly` and fails if the providers would change.

## Notes

- **Memory is tight.** An `e2-micro` has 1 GB of RAM. The startup script adds a 1 GB swapfile, but expect the server to struggle with many players or a large view distance.
- **The startup script runs on every boot.** It is safe to re-run: it only creates the swapfile and installs Docker if they are missing, refreshes `docker-compose.yml` from instance metadata, and leaves the allowlist and world data alone.
- **Image tag:** the compose file follows the `server_image` variable, `latest` by default, and the VM pulls on every boot. Pin a version tag for controlled upgrades (see [Container image](#container-image)).
- The Minecraft firewall rule is open to `0.0.0.0/0` by default. That's needed for a public server; set `minecraft_source_ranges` to narrow it if only certain people play.
- **Provider versions:** `terraform/versions.tf` constrains the Google provider to `~> 6.0`. For fully reproducible runs, create `terraform/.terraform.lock.hcl` with `make lock` or the *Update provider lock file* workflow (see [Provider lock file](#provider-lock-file)) and commit it. It pins the exact version and checksums for Linux, macOS and Windows, and Terraform and CI then use it automatically.
- The VM uses a reserved static external IP, so the server address survives stop/start cycles. Remember that external IPv4 addresses are billed.
- `terraform/main.tf` assumes the `default` VPC network exists in your project.
- **State:** see [Terraform state](#terraform-state). It is a local file, not in the bucket.
- **CI** (`.github/workflows/terraform.yml`): the validate job runs `terraform init -backend=false` inside `terraform/`, so it needs no GCP credentials. It then runs `terraform fmt -check`, `terraform validate`, TFLint and tfsec; a separate job runs ShellCheck on `scripts/*.sh` and `tests/*.sh` and then the script tests. Run `make check` locally for the format, validate, ShellCheck and script-test steps (or `make test` for just the tests). Pull requests also get a `terraform plan` comment once plan credentials are set (see [Plan on pull requests](#plan-on-pull-requests)). The few `tfsec:ignore` comments in `terraform/main.tf` each say why (public game port, external IP, and no customer-managed encryption keys on a free-tier server).
- **No automatic deploy.** CI used to run `terraform apply` on every push to `main`. That cannot work with local state (each CI run starts with no state and would collide with the resources that exist), so deploys are manual: `make deploy` from Cloud Shell.

## License

Licensed under the [Apache License 2.0](LICENSE).