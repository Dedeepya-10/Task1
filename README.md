# DevOps Round 1 & 2 — Containerized Node.js App on AWS with CI/CD

A simple Express app, containerized with Docker, pushed to AWS ECR, and deployed
onto an EC2 instance provisioned entirely with Terraform (Round 1). Round 2 adds
a GitHub Actions pipeline that tests, builds, pushes, and redeploys automatically
on every push to `main` — see [CI/CD Pipeline (Round 2)](#cicd-pipeline-round-2)
further down.

## Repository layout

```
.
├── app/                        # Node.js/Express application
│   ├── package.json
│   ├── app.js                   # Express app (exported for tests)
│   ├── server.js                 # Entry point - starts app.js on a port
│   ├── app.test.js               # Jest/Supertest unit tests
│   └── .eslintrc.json
├── Dockerfile                   # Multi-stage build, runs as non-root
├── .dockerignore
├── .github/
│   └── workflows/
│       └── deploy.yml            # CI/CD: test -> build/push to ECR -> deploy to EC2
├── scripts/
│   └── build-and-push.sh        # Builds the image and pushes it to ECR (manual/local use)
├── terraform/
│   ├── main.tf                  # Security group, IAM role, SSH key pair, EC2 instance
│   ├── variables.tf             # Region / instance / app configuration
│   ├── outputs.tf                # Public IP, DNS, app URL, SSH key
│   └── templates/
│       └── user_data.sh.tpl     # EC2 bootstrap: installs Docker, pulls & runs the image
└── README.md
```

## Prerequisites

- Docker installed locally
- AWS CLI v2, configured with credentials (`aws configure`)
- Terraform >= 1.5
- An AWS account (free tier is sufficient)

## Part 1 — Build and test the Docker image locally

```bash
docker build -t devops-task-app:local .
docker run --rm -p 3000:3000 devops-task-app:local
```

Verify it's working:

```bash
curl http://localhost:3000/
curl http://localhost:3000/health
```

**Dockerfile design notes:**
- Multi-stage build: a `deps` stage installs production-only dependencies
  (`npm ci --omit=dev`, using the committed `package-lock.json` for a
  reproducible install), and the `runtime` stage copies only `node_modules`
  and app source — no build tooling, dev dependencies, or lockfile end up in
  the final image.
- Based on `node:20-alpine` for a small image footprint (~199MB final image).
- Runs as the built-in unprivileged `node` user, not root.
- Declares a `HEALTHCHECK` that hits the app's `/health` endpoint.
- `.dockerignore` keeps `node_modules`, git metadata, and Terraform/docs out
  of the build context.

## Part 2 — Push the image to AWS ECR

The helper script creates the repository if it doesn't exist, authenticates
Docker to ECR, builds, and pushes:

```bash
./scripts/build-and-push.sh <aws-region> <ecr-repo-name> [tag]

# Example:
./scripts/build-and-push.sh us-east-1 devops-task-app latest
```

Equivalent manual AWS CLI commands (what the script runs under the hood):

```bash
# 1. Create the ECR repository
aws ecr create-repository --repository-name devops-task-app --region us-east-1

# 2. Authenticate Docker to ECR
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com

# 3. Build for linux/amd64 and push (see the architecture note below on why
#    --platform matters) and push
docker buildx build --platform linux/amd64 \
  -t <account-id>.dkr.ecr.us-east-1.amazonaws.com/devops-task-app:latest \
  --push .
```

> **Note:** the EC2 instance runs the standard x86_64 Amazon Linux 2023 AMI.
> If you build on Apple Silicon (M-series Mac), a plain `docker build` produces
> an `arm64` image that will fail on the instance with `exec format error`.
> Always build with `--platform linux/amd64` (or use `build-and-push.sh`,
> which does this automatically) when targeting this EC2 instance type.

Verified pushed image (from this run):

```
$ aws ecr describe-images --repository-name devops-task-app --region us-east-1
imageTags: ["latest"]
imageDigest: sha256:7acb0ba26cf03f4fbeab7253946764049d56f6ab72abd6104574af3bc79a23ab
repositoryUri: 478043880552.dkr.ecr.us-east-1.amazonaws.com/devops-task-app
```

> Screenshot of the pushed image in the ECR console: `docs/ecr-screenshot.png` (add after pushing)

## Part 3 — Provision infrastructure with Terraform

The Terraform config provisions, in the account's default VPC:
- A security group allowing inbound SSH (22), HTTP (80), and HTTPS (443)
- An IAM role + instance profile granting the EC2 instance read-only ECR
  access (so no AWS credentials need to be stored on the box)
- A `t3.micro` EC2 instance (free-tier eligible) running the latest Amazon
  Linux 2023 AMI, bootstrapped via `user_data` to install Docker, log in to
  ECR, and run the container

```bash
cd terraform

terraform init

terraform plan \
  -var="ecr_repository_url=<account-id>.dkr.ecr.us-east-1.amazonaws.com/devops-task-app" \
  -var="allowed_ssh_cidr=<your-ip>/32"

terraform apply \
  -var="ecr_repository_url=<account-id>.dkr.ecr.us-east-1.amazonaws.com/devops-task-app" \
  -var="allowed_ssh_cidr=<your-ip>/32"
```

Or create a `terraform/terraform.tfvars` file instead of passing `-var` flags:

```hcl
aws_region          = "us-east-1"
ecr_repository_url  = "<account-id>.dkr.ecr.us-east-1.amazonaws.com/devops-task-app"
allowed_ssh_cidr    = "<your-ip>/32"
```

> **Round 2 change:** there's no `key_name` variable anymore. Terraform now
> generates the SSH key pair itself (`tls_private_key` + `aws_key_pair`) instead
> of expecting one created out-of-band with the AWS CLI — see
> [CI/CD Pipeline (Round 2)](#cicd-pipeline-round-2) for why.

### Variables (`variables.tf`)

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `us-east-1` | Region to deploy into |
| `instance_type` | `t3.micro` | Free-tier eligible instance size |
| `allowed_ssh_cidr` | `0.0.0.0/0` | CIDR allowed to SSH in — restrict to your IP |
| `ecr_repository_url` | *required* | Full ECR repo URL to pull the image from |
| `app_image_tag` | `latest` | Image tag to deploy |
| `container_port` | `3000` | Port the app listens on inside the container |
| `host_port` | `80` | Port exposed on the EC2 host |
| `project_name` | `devops-task` | Prefix used to name/tag all resources |

### Outputs (`outputs.tf`)

`instance_id`, `instance_public_ip`, `instance_public_dns`,
`security_group_id`, `app_url`, `ssh_key_name`, `ssh_private_key_pem` (sensitive)

### Terraform apply output

Actual output from running this configuration:

```
Plan: 5 to add, 0 to change, 0 to destroy.

aws_iam_role.ec2_ecr_role: Creating...
aws_security_group.app: Creating...
aws_iam_role.ec2_ecr_role: Creation complete after 2s [id=devops-task-ec2-ecr-role]
aws_iam_role_policy_attachment.ecr_read_only: Creating...
aws_iam_instance_profile.ec2_profile: Creating...
aws_iam_role_policy_attachment.ecr_read_only: Creation complete after 1s
aws_security_group.app: Creation complete after 6s [id=sg-0b9733cc1be3a1fe5]
aws_iam_instance_profile.ec2_profile: Creation complete after 8s
aws_instance.app_server: Creating...
aws_instance.app_server: Still creating... [10s elapsed]
aws_instance.app_server: Creation complete after 15s [id=i-076e236d1553839d0]

Apply complete! Resources: 5 added, 0 changed, 0 destroyed.

Outputs:

app_url = "http://3.237.42.95:80"
instance_id = "i-076e236d1553839d0"
instance_public_dns = "ec2-3-237-42-95.compute-1.amazonaws.com"
instance_public_ip = "3.237.42.95"
security_group_id = "sg-0b9733cc1be3a1fe5"
```

And the deployed app responding:

```
$ curl http://3.237.42.95/
{"message":"Hello from the containerized DevOps task app!","hostname":"7d50f355e6fc","timestamp":"2026-07-23T19:17:36.223Z"}

$ curl http://3.237.42.95/health
{"status":"ok"}
```

**Round 2 re-apply** (after adding the Terraform-managed SSH key pair):

```
Plan: 7 to add, 0 to change, 0 to destroy.

tls_private_key.ssh: Creating...
tls_private_key.ssh: Creation complete after 1s
aws_key_pair.generated: Creating...
aws_iam_role.ec2_ecr_role: Creating...
aws_security_group.app: Creating...
aws_key_pair.generated: Creation complete after 2s [id=devops-task-key]
aws_iam_role.ec2_ecr_role: Creation complete after 2s [id=devops-task-ec2-ecr-role]
aws_iam_role_policy_attachment.ecr_read_only: Creating...
aws_iam_instance_profile.ec2_profile: Creating...
aws_iam_role_policy_attachment.ecr_read_only: Creation complete after 1s
aws_security_group.app: Creation complete after 5s [id=sg-01294581e55648c7d]
aws_iam_instance_profile.ec2_profile: Creation complete after 8s
aws_instance.app_server: Creating...
aws_instance.app_server: Still creating... [10s elapsed]
aws_instance.app_server: Creation complete after 16s [id=i-09cb3e309adc27175]

Apply complete! Resources: 7 added, 0 changed, 0 destroyed.

Outputs:

app_url = "http://3.236.126.113:80"
instance_id = "i-09cb3e309adc27175"
instance_public_dns = "ec2-3-236-126-113.compute-1.amazonaws.com"
instance_public_ip = "3.236.126.113"
security_group_id = "sg-01294581e55648c7d"
ssh_key_name = "devops-task-key"
ssh_private_key_pem = <sensitive>
```

```
$ curl http://3.236.126.113/
{"message":"Hello from the containerized DevOps task app!","hostname":"aa168a6b869d","timestamp":"2026-07-24T20:03:29.013Z"}

$ curl http://3.236.126.113/health
{"status":"ok"}
```

> Note: this IP is only valid while this specific instance is running — no
> Elastic IP is attached (see Assumptions below), so it will change on the
> next `terraform apply`.

## Part 4 — Access the running application

Once `terraform apply` finishes, the instance takes a minute or two to run
its bootstrap script (installing Docker, logging into ECR, pulling and
starting the container). Then:

```bash
curl $(terraform output -raw app_url)/
curl $(terraform output -raw app_url)/health
```

Or open `app_url` in a browser.

To tear everything down:

```bash
terraform destroy
```

## Assumptions & notes

- Deploys into the account's **default VPC** rather than creating a new one,
  to keep the config minimal and free-tier friendly.
- The EC2 instance authenticates to ECR via an **IAM instance profile**
  instead of long-lived credentials baked into `user_data`.
- `allowed_ssh_cidr` defaults to `0.0.0.0/0` for convenience during grading;
  in a real deployment this should be locked down to a specific IP.
- The app listens on port `3000` inside the container; the security group
  and `host_port` variable expose it on port `80` so it's reachable without
  specifying a port in the URL.
- No Elastic IP is used, so the public IP will change if the instance is
  stopped/started (not an issue for `terraform destroy`/`apply` cycles).

## Challenges faced

- **`arm64`/`amd64` image mismatch.** Built and pushed the image from an
  Apple Silicon Mac using a plain `docker build`, which defaults to `arm64`.
  The EC2 instance (standard x86_64 Amazon Linux 2023 AMI) pulled it fine but
  the container crash-looped with `exec /usr/local/bin/docker-entrypoint.sh:
  exec format error`. Fixed by rebuilding with
  `docker buildx build --platform linux/amd64 ... --push` and updating
  `scripts/build-and-push.sh` to always target `linux/amd64` regardless of
  the host architecture running the script — otherwise this bites anyone
  building on an M-series Mac.
- **Docker credential store pointed at a helper that didn't exist.**
  `~/.docker/config.json` had `"credsStore": "desktop"` left over from an
  earlier attempt to install Docker Desktop, but Docker was actually running
  via Colima. `docker login` failed with
  `error saving credentials: ... docker-credential-desktop: executable file
  not found`. Fixed by removing the stale `credsStore` key so Docker falls
  back to its default config-file-based auth storage.
- **Stale AWS session token blocking authentication.** `~/.aws/credentials`
  still had an `aws_session_token` line left over from an earlier AWS
  Academy/learner-lab account. Running `aws configure` with a new IAM user's
  permanent access key doesn't clear unrelated existing fields, so the CLI
  kept sending the new access key alongside the old, expired session token —
  producing `InvalidClientTokenId`. Fixed by removing the stale
  `aws_session_token` line, keeping only the new key pair.

---

## CI/CD Pipeline (Round 2)

Round 1 was manual: build the image, push it to ECR, run Terraform, SSH in
if something needed fixing. Round 2 automates that whole chain with GitHub
Actions — every push to `main` tests, builds, pushes, and redeploys without
anyone running a command by hand.

### Pipeline flow

```
push to main / PR opened
        │
        ▼
┌───────────────┐
│   test job    │  ESLint + Jest, every push and PR
└───────┬───────┘
        │ (only continues past here on a push to main)
        ▼
┌────────────────────┐
│  build-and-push job │  docker buildx build --platform linux/amd64
│                      │  push to ECR tagged :latest and :<commit sha>
└──────────┬───────────┘
           ▼
┌────────────────────────┐
│      deploy job         │  1. open SG port 22 for this runner's IP only
│                          │  2. SSH in, pull new image, restart container
│                          │  3. curl /health on the box
│                          │  4. revoke the SG rule (runs even on failure)
│                          │  5. curl the public IP from outside to confirm
└──────────────────────────┘
```

Pull requests only ever run the `test` job — a PR branch can never build,
push, or touch the EC2 instance. Only a push that lands on `main` triggers
`build-and-push` and `deploy`.

### Why the SSH access is temporary, not a static IP allowlist

GitHub-hosted runners don't come from a small, fixed IP range you could add
to the security group once and forget about. Rather than opening port 22 to
`0.0.0.0/0` permanently (or standing up a NAT/bastion just for this), the
`deploy` job looks up its own public IP at the start of the run, adds a
security-group rule for just that `/32`, deploys, and removes the rule again
in a step marked `if: always()` — so it gets cleaned up even if the SSH step
itself fails partway through. Port 22 is closed to the internet the rest of
the time.

### Setting up GitHub Secrets

Go to the repo → **Settings → Secrets and variables → Actions → New repository secret**, and add each of these:

| Secret | Value | Where to get it |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | your IAM user's access key | IAM → Users → your user → Security credentials → Create access key |
| `AWS_SECRET_ACCESS_KEY` | the matching secret key | shown once when the access key is created |
| `AWS_REGION` | e.g. `us-east-1` | whichever region you deployed into |
| `ECR_REPOSITORY` | e.g. `<account-id>.dkr.ecr.us-east-1.amazonaws.com/devops-task-app` | `terraform output` from Round 1, or the ECR console |
| `SECURITY_GROUP_ID` | e.g. `sg-01294581e55648c7d` | `terraform output security_group_id` |
| `EC2_HOST` | the instance's public IP | `terraform output instance_public_ip` |
| `EC2_USER` | `ec2-user` | fixed for Amazon Linux 2023 |
| `EC2_SSH_KEY` | the full private key, including the `-----BEGIN...` / `-----END...` lines | `terraform output -raw ssh_private_key_pem` |

The IAM user behind `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` needs ECR
push/pull access and `ec2:AuthorizeSecurityGroupIngress` /
`RevokeSecurityGroupIngress` (both included in `AmazonEC2FullAccess` if
you're using the same broad policy set from Round 1).

Because Terraform now generates the SSH key pair itself instead of one
created manually with the AWS CLI, `EC2_SSH_KEY` always matches whatever
key the currently-deployed instance actually trusts — no more manually
tracking a `.pem` file separately from the instance it belongs to.

### Workflow steps explained

- **`test`** — checks out the code, installs dependencies, runs `eslint .`
  and `jest`. Runs on every push and every PR. If either fails, nothing
  downstream runs.
- **`build-and-push`** — configures AWS credentials, logs into ECR, and uses
  `docker/build-push-action` with `platforms: linux/amd64` (see Round 1's
  arm64/amd64 challenge below for why that flag is non-negotiable), pushing
  two tags: `latest` and the commit SHA. The SHA tag means every deploy is
  tied to an exact, traceable build instead of just overwriting `latest`
  blind.
- **`deploy`** — opens temporary SSH access, connects with
  `appleboy/ssh-action`, and on the box: logs into ECR using the instance's
  own IAM role (no AWS keys ever touch the EC2 box itself), pulls the
  SHA-tagged image, force-removes the old `app` container, starts the new
  one, and curls `/health` locally before closing the SSH session. It then
  revokes the temporary SG rule and does one more external curl to confirm
  the app is reachable from outside, not just from localhost on the box.

### Testing strategy

Went with **Jest + Supertest for a couple of route-level unit tests, plus
ESLint for linting** — both of the "pick at least one" options, since
neither takes much extra effort for an app this small and together they
catch different problems: ESLint catches syntax/style issues before the app
even runs, Jest/Supertest actually exercises the two routes (`/` and
`/health`) and checks the response shape, which is what the Docker
`HEALTHCHECK` and the deploy job's own health check depend on being correct.
Didn't reach for a heavier test setup (e.g. spinning up the whole container
in CI) since the app itself is intentionally minimal — the infrastructure is
the actual point of this task, not the app logic.

### Monitoring & viewing logs

- **Workflow logs**: repo → **Actions** tab → click a run → expand any step.
  Every `test`, `build-and-push`, and `deploy` step's full output is there.
- **Container logs on EC2**:
  ```bash
  ssh -i <your-key>.pem ec2-user@<instance-ip>
  sudo docker logs app --tail 100 -f
  ```
- **Container health status**:
  ```bash
  sudo docker inspect --format='{{.State.Health.Status}}' app
  ```
- **Instance boot/bootstrap log** (useful if the container never started at all):
  ```bash
  sudo tail -100 /var/log/cloud-init-output.log
  ```

### Troubleshooting common CI/CD failures

| Symptom | Likely cause | Fix |
|---|---|---|
| `test` job fails | Lint or test failure | Read the step output — it names the exact rule/assertion that failed. Fix locally and re-push. |
| `build-and-push` fails at ECR login | Wrong/expired `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`, or wrong `AWS_REGION` | Double-check the secret values match a currently-active access key in the right region. |
| `deploy` fails at "Temporarily allow SSH" | The IAM user lacks `ec2:AuthorizeSecurityGroupIngress`, or `SECURITY_GROUP_ID` is wrong/stale | Confirm the secret matches `terraform output security_group_id` for the *current* instance. |
| SSH step times out or connection refused | `EC2_HOST` is stale (instance was recreated and got a new IP), or the instance isn't running | Re-check `terraform output instance_public_ip` and update the `EC2_HOST` secret. |
| SSH step connects but auth fails | `EC2_SSH_KEY` doesn't match the key pair Terraform generated for the *current* instance | Re-run `terraform output -raw ssh_private_key_pem` and update the secret — this happens if the instance was replaced (e.g. after a `terraform apply` that recreates it) without updating the secret. |
| Container starts but health check fails | App crashed on startup, or wrong port mapping | `sudo docker logs app` on the instance — this is exactly how the Round 1 `exec format error` (arm64/amd64 mismatch) was diagnosed. |
| Deploy succeeds but app unreachable from outside | Security group doesn't allow port 80, or the instance's public IP changed | Confirm the SG still has the HTTP rule from Terraform, and that `EC2_HOST` matches the live IP. |

### Challenges faced (Round 2)

- Reused the exact `exec format error` lesson from Round 1 by making
  `--platform linux/amd64` a permanent, non-optional part of the build step
  rather than something that only lives in a shell script someone has to
  remember to run correctly.
- GitHub-hosted runner IPs aren't static, which rules out a simple
  "allowlist this one IP forever" security group rule for SSH. Settled on
  opening/closing the rule per-run instead of the two easier-but-worse
  options: leaving port 22 open to the world, or standing up a bastion host
  for a task this size.
- Moved the SSH key from something created once by hand with the AWS CLI
  (Round 1) to something Terraform generates and outputs — otherwise the
  GitHub Secret and the actual running instance's trusted key can silently
  drift apart the next time the instance gets recreated.
