# gcp-minecraft

Run a **Minecraft Bedrock Edition** server on a Google Cloud Platform (GCP) virtual machine. Terraform provisions an `e2-micro` VM sized for GCP's Always Free tier, opens the firewall for Minecraft traffic, and installs Docker on first boot. Docker Compose then runs the [`itzg/minecraft-bedrock-server`](https://hub.docker.com/r/itzg/minecraft-bedrock-server) image.

## What's in this repo

| File | Purpose |
| --- | --- |
| `terraform/main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` | Terraform for the VM, its static IP, service account, backup bucket, the SSH and Minecraft firewall rules, and a startup script that adds swap, hardens sshd and installs Docker |
| `terraform/minecraft.auto.tfvars.example` | Template for your project settings (`project_id`, `backup_bucket_name`). Copy it to `terraform/minecraft.auto.tfvars` (git-ignored) and **edit it for your own project**. Terraform loads that file automatically, so no `-var` flags are needed |
| `terraform/backend.tf` / `backend.hcl` | Remote Terraform state in a GCS bucket. The bucket name comes from `backup_bucket_name` in `minecraft.auto.tfvars` (via `scripts/terraform-init.sh`); `backend.hcl` holds the state prefix (see [Notes](#notes)) |
| `scripts/terraform-init.sh` | Runs `terraform init` with the state bucket read from `terraform/minecraft.auto.tfvars`. Use it instead of a bare `terraform init` |
| `docker-compose.yml` | Defines the Bedrock server container and its configuration |
| `data/` | `server.properties` and `allowlist.json`, used when you run Compose from a clone of the repo (Option B below). World data is git-ignored |
| `scripts/setup-vm.sh` | Helper to run on the VM: checks Docker is installed, adds you to the `docker` group, installs the compose file into `~/minecraft-bedrock`, starts the server, and schedules a daily world backup to Cloud Storage |
| `Makefile` | Shortcuts: `make init`, `plan`, `apply`, `destroy`, `fmt`, and `make check` (format check, validate and ShellCheck, as CI runs them) |
| `.github/workflows/terraform.yml` | CI: `terraform fmt`, `terraform validate`, TFLint, tfsec and ShellCheck on every push and pull request, plus an optional deploy job (see [Notes](#notes)) |
| `LICENSE` | Apache License 2.0 |

## How it fits together

1. **Terraform** creates the VM (Debian 12, `e2-micro`, 30 GB standard disk), a static external IP, a dedicated service account, a Cloud Storage bucket for backups, and two firewall rules: SSH and Minecraft.
2. On first boot, the VM's **startup script** creates a 1 GB swapfile and installs Docker Engine, the Compose plugin, and `unattended-upgrades`.
3. **You** SSH in and start the server with Docker Compose. World data is stored in a `data/` directory on the VM.

## Prerequisites

- A GCP project with billing enabled
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.5 or newer (the Google provider `~> 6.0` is downloaded by `terraform init`)
- The [`gcloud` CLI](https://cloud.google.com/sdk/docs/install), authenticated (`gcloud auth application-default login`)
- To SSH through IAP (the default) your user needs `roles/iap.tunnelResourceAccessor` and an OS Login role. Use `roles/compute.osAdminLogin` if you want `sudo` on the VM, which Docker setup and `setup-vm.sh` require. `roles/compute.osLogin` alone gives no sudo access.

## Getting started

### 1. Provision the VM

```bash
git clone https://github.com/sancliffe/gcp-minecraft-iac.git
cd gcp-minecraft-iac

# Create your settings file, then edit project_id and backup_bucket_name in it
cp terraform/minecraft.auto.tfvars.example terraform/minecraft.auto.tfvars

./scripts/terraform-init.sh
terraform -chdir=terraform apply
```

`make init` and `make apply` do the same thing.

`project_id` and `backup_bucket_name` come from `terraform/minecraft.auto.tfvars`, which Terraform loads automatically. You can still override any value on the command line, e.g. `terraform -chdir=terraform apply -var project_id=<other-project>`.

#### If the backup bucket already exists

The Terraform state is stored in the same bucket this configuration manages. If the bucket exists but Terraform doesn't know about it yet, `apply` fails with `Error 409: ... you already own it`. Import the existing bucket into the state, then apply again:

```bash
terraform -chdir=terraform import google_storage_bucket.minecraft_backups <bucket-name>
terraform -chdir=terraform apply
```

(`<bucket-name>` is the `backup_bucket_name` value, for example `steanlabs-web-minecraft-backups`.) On a brand-new project with no state bucket yet, create it first with `gcloud storage buckets create gs://<bucket-name> --location=<region>`, then import it the same way.

Terraform enables the required APIs (Compute Engine, IAM, Cloud Resource Manager, Logging, Monitoring, Cloud Storage) and creates the resources. When it finishes it prints four outputs: `instance_name`, `static_external_ip`, `backup_bucket_name`, and `ssh_command_iap`. You can show them again at any time with `terraform output`.

#### What gets created

| Resource | Details |
| --- | --- |
| VM `free-tier-vm` | `e2-micro`, Debian 12, 30 GB `pd-standard` disk, Shielded VM (secure boot, vTPM, integrity monitoring), OS Login on, project-wide SSH keys blocked, serial port disabled, hardened sshd (see [SSH hardening](#ssh-hardening)), network tags `ssh` and `minecraft` |
| Static IP `minecraft-static-ip` | Reserved external IPv4 address (Standard tier), created only when `enable_external_ip = true` |
| Service account `free-tier-vm` | Has `roles/logging.logWriter` and `roles/monitoring.metricWriter` on the project, and `roles/storage.objectCreator` on the backup bucket |
| Bucket `<project-id>-minecraft-backups` | Uniform access, public access prevented, object versioning on. World backups under `backups/` are deleted after 30 days (noncurrent versions after 1 more day); the last 10 versions of the Terraform state are kept |
| Firewall `free-tier-vm-allow-ssh` | TCP 22 from `ssh_source_ranges`, applied to VMs tagged `ssh` |
| Firewall `free-tier-vm-allow-minecraft` | TCP 19132, UDP 19132, 19133 and 19140-19150 from `0.0.0.0/0`, applied to VMs tagged `minecraft` |

#### Terraform variables

| Variable | Default | Description |
| --- | --- | --- |
| `project_id` | *(required)* | GCP project ID. Set in `minecraft.auto.tfvars` |
| `backup_bucket_name` | `<project_id>-minecraft-backups` | Cloud Storage bucket for world backups. Set in `minecraft.auto.tfvars`. The VM learns the name through instance metadata, so `setup-vm.sh` backs up to the right bucket |
| `region` | `us-central1` | Must be `us-west1`, `us-central1`, or `us-east1` (Always Free e2-micro regions) |
| `zone` | `<region>-a` | Zone inside the chosen region |
| `enable_external_ip` | `true` | Attach an external IPv4 address (Standard network tier). See the cost note below |
| `ssh_source_ranges` | `["35.235.240.0/20"]` | CIDRs allowed to SSH. The default is Google's IAP range; add `<your-ip>/32` for direct SSH. Must be valid CIDRs, non-empty, and cannot include `0.0.0.0/0` or `::/0` |
| `require_os_login_2fa` | `false` | Require 2-step verification for OS Login SSH sessions. Everyone who needs SSH must have 2-step verification enabled on their Google account first, or they are locked out |
| `deletion_protection` | `false` | Blocks deleting the VM via the API or Terraform when `true` |

#### Cost notes

- The VM, 30 GB standard disk, and region fall within the Always Free tier, but **external IPv4 addresses are billed** and are not covered by it. Check [current GCP pricing](https://cloud.google.com/vpc/network-pricing#ipaddress) before you apply.
- Players need to reach the server over the internet, so for a public server keep `enable_external_ip = true`.
- Setting it to `false` leaves the VM with no outbound internet access (including `apt` and Docker image pulls) unless you add Cloud NAT, which has its own cost.

### 2. Connect to the VM

Use the command Terraform printed (it tunnels through IAP):

```bash
gcloud compute ssh free-tier-vm --zone us-central1-a --project <your-project-id> --tunnel-through-iap
```

The startup script needs a few minutes on first boot to install Docker. Check that it has finished:

```bash
docker --version && docker compose version
```

If Docker isn't there yet, wait a moment, or follow the startup script's progress with `sudo journalctl -u google-startup-scripts -f`.

### 3. Start the server

Pick one of the two options. Either way the server stores its world in a `data/` directory beside the compose file.

**Option A: `setup-vm.sh` (no git needed on the VM)**

From your own machine, copy the script and the compose file over, then run the script on the VM:

```bash
gcloud compute scp scripts/setup-vm.sh docker-compose.yml free-tier-vm:~ --zone us-central1-a --project <your-project-id> --tunnel-through-iap
```

```bash
# on the VM
bash setup-vm.sh
```

The script checks that Docker is installed (it exits with a hint if the startup script hasn't finished), adds your user to the `docker` group, copies `docker-compose.yml` into `~/minecraft-bedrock`, starts the server, and schedules the daily backup described under [Backups](#backups). Group membership only applies after you log out and back in, so use `sudo docker ...` until then. It detects the project ID from the VM's metadata server; set `PROJECT_ID=<id>` to override.

**Option B: clone this repo on the VM**

```bash
git clone https://github.com/sancliffe/gcp-minecraft-iac.git
cd gcp-minecraft-iac
sudo docker compose up -d
```

(Install git first with `sudo apt-get install -y git` if it isn't present.)

> Re-running `setup-vm.sh` overwrites `~/minecraft-bedrock/docker-compose.yml` with the copy that sits next to the script (or a built-in default if you didn't copy it), so keep a note of any local changes.

### 4. Join the server

In Minecraft Bedrock Edition choose *Play → Servers → Add Server*, then enter the VM's external IP (the `static_external_ip` Terraform output) and port `19132`.

The server runs with an allowlist (`ALLOW_LIST: "true"`), so only listed players can join. A clone of the repo (Option B) ships `data/allowlist.json`. With Option A the allowlist starts empty, so add each player's gamertag from the VM:

```bash
sudo docker exec bedrock-server send-command allowlist add <gamertag>
```

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
| `ALLOW_LIST` | `true` | Only players on the allowlist can join (see [Join the server](#4-join-the-server)) |
| `OPS` | `superflea2828` | Gamertag(s) of server operators, resolved to XUIDs at startup |
| `VIEW_DISTANCE` | `10` | View distance in chunks |
| `TICK_DISTANCE` | `4` | Simulation distance in chunks |
| `MAX_THREADS` | `2` | Maximum threads the server uses |
| `./data:/data` | volume | World data and server files persist in `./data` on the host |

To change any of these, edit the `environment:` section of the compose file on the VM and run `sudo docker compose up -d` again. See the [image documentation](https://github.com/itzg/docker-minecraft-bedrock-server) for the full list of supported variables.

The firewall rule created by Terraform covers the default ports above. If you change `SERVER_PORT`, `SERVER_PORT_V6`, or `SERVER_UDP_PORTS`, update the ports in the `google_compute_firewall.minecraft` resource in `terraform/main.tf` and run `terraform -chdir=terraform apply` again. With `network_mode: host`, the container's ports are the VM's ports.

## Common operations

Run these from the directory that holds the compose file (`~/minecraft-bedrock` for Option A, or the cloned repo for Option B):

```bash
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

All world data lives in the `data/` directory next to the compose file.

`setup-vm.sh` installs `~/minecraft-bedrock/backup.sh` and a cron job that runs it daily at 4:00 AM. The script archives `data/` and uploads it to `gs://<project-id>-minecraft-backups/backups/world-backup-<date>.tar.gz`. Output is logged to `~/minecraft-bedrock/backup.log`. Backups older than 30 days are deleted by the bucket's lifecycle rule.

The backup runs while the server is up, so a world being written at that moment could be captured inconsistently. For a guaranteed-consistent copy (for example before an upgrade), stop the server first:

```bash
cd ~/minecraft-bedrock
sudo docker compose down
sudo tar -czf minecraft-backup-$(date +%F).tar.gz data/
sudo docker compose up -d
```

To restore, download an archive with `gcloud storage cp gs://<project-id>-minecraft-backups/backups/<file> .`, stop the server, and extract it over `data/`.

## Tearing down

If you turned on `deletion_protection`, turn it off first. The backup bucket has `force_destroy` enabled, so `terraform destroy` deletes it along with every backup and **the Terraform state stored under `terraform/state`**. Download any backups you want to keep first, and if you use the GCS backend from `backend.tf`, migrate the state elsewhere before destroying.

```bash
terraform -chdir=terraform apply -var deletion_protection=false
terraform -chdir=terraform destroy
```

The boot disk is deleted along with the VM.

## Notes

- **Memory is tight.** An `e2-micro` has 1 GB of RAM. The startup script adds a 1 GB swapfile, but expect the server to struggle with many players or a large view distance.
- **The startup script runs on every boot.** It is safe to re-run: it only creates the swapfile and installs Docker if they are missing.
- The compose file uses the `latest` image tag, so `docker compose pull` may bring in a newer Bedrock server version. Pin a specific tag if you want to control upgrades.
- The Minecraft firewall rule is open to `0.0.0.0/0`. That's needed for a public server, but you can narrow `source_ranges` in `terraform/main.tf` if only certain people play.
- The VM uses a reserved static external IP, so the server address survives stop/start cycles. Remember that external IPv4 addresses are billed.
- `terraform/main.tf` assumes the `default` VPC network exists in your project.
- **Remote state:** Terraform state is stored in the same bucket that `terraform/main.tf` manages for backups. Terraform backends can't read variables or `.tfvars` files, so `./scripts/terraform-init.sh` reads `backup_bucket_name` from `terraform/minecraft.auto.tfvars` (falling back to `<project_id>-minecraft-backups`) and passes it to `terraform init` as `-backend-config="bucket=..."`; the state prefix comes from `terraform/backend.hcl`. Extra arguments are forwarded, e.g. `./scripts/terraform-init.sh -reconfigure`. For your own project you only need to edit `terraform/minecraft.auto.tfvars`. Run a bare `terraform -chdir=terraform init` and Terraform will prompt for the bucket instead. See [If the backup bucket already exists](#if-the-backup-bucket-already-exists) for the first-deploy order. Only objects under `backups/` expire, so the state is not aged out.
- **CI** (`.github/workflows/terraform.yml`): the validate job runs `terraform init -backend=false` inside `terraform/`, so it needs no GCP credentials and does not run `terraform plan`. It then runs `terraform fmt -check`, `terraform validate`, TFLint and tfsec; a separate job runs ShellCheck on `scripts/*.sh`. Run `make check` locally for the format, validate and ShellCheck steps. The few `tfsec:ignore` comments in `terraform/main.tf` each say why (public game port, external IP, and no customer-managed encryption keys on a free-tier server).
- **Automatic deploy:** on every push to `main`, once the checks pass, CI runs `terraform apply -auto-approve`. It needs the repository secret `GCP_SA_KEY` (a service account key as JSON). The project defaults to the one the key belongs to; set the repository variable `GCP_PROJECT_ID` to override it. The state bucket defaults to `<project_id>-minecraft-backups`; set `BACKUP_BUCKET_NAME` to override it. Without the secret the deploy job is skipped (with a notice in the run), so you can deploy by hand and keep CI green.

## License

Licensed under the [Apache License 2.0](LICENSE).