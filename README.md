# DevOps Round 1 Task — Containerized Node.js App on AWS (Docker + ECR + Terraform)

A simple Express app, containerized with Docker, pushed to AWS ECR, and deployed
onto an EC2 instance provisioned entirely with Terraform.

## Repository layout

```
.
├── app/                        # Node.js/Express application
│   ├── package.json
│   └── server.js
├── Dockerfile                   # Multi-stage build, runs as non-root
├── .dockerignore
├── scripts/
│   └── build-and-push.sh        # Builds the image and pushes it to ECR
├── terraform/
│   ├── main.tf                  # Security group, IAM role, EC2 instance
│   ├── variables.tf             # Region / instance / app configuration
│   ├── outputs.tf                # Public IP, DNS, app URL
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
  -var="key_name=<your-ec2-key-pair-name>" \
  -var="allowed_ssh_cidr=<your-ip>/32"

terraform apply \
  -var="ecr_repository_url=<account-id>.dkr.ecr.us-east-1.amazonaws.com/devops-task-app" \
  -var="key_name=<your-ec2-key-pair-name>" \
  -var="allowed_ssh_cidr=<your-ip>/32"
```

Or create a `terraform/terraform.tfvars` file instead of passing `-var` flags:

```hcl
aws_region          = "us-east-1"
ecr_repository_url  = "<account-id>.dkr.ecr.us-east-1.amazonaws.com/devops-task-app"
key_name            = "<your-ec2-key-pair-name>"
allowed_ssh_cidr    = "<your-ip>/32"
```

### Variables (`variables.tf`)

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `us-east-1` | Region to deploy into |
| `instance_type` | `t3.micro` | Free-tier eligible instance size |
| `key_name` | `""` | Existing EC2 key pair name for SSH (optional) |
| `allowed_ssh_cidr` | `0.0.0.0/0` | CIDR allowed to SSH in — restrict to your IP |
| `ecr_repository_url` | *required* | Full ECR repo URL to pull the image from |
| `app_image_tag` | `latest` | Image tag to deploy |
| `container_port` | `3000` | Port the app listens on inside the container |
| `host_port` | `80` | Port exposed on the EC2 host |
| `project_name` | `devops-task` | Prefix used to name/tag all resources |

### Outputs (`outputs.tf`)

`instance_id`, `instance_public_ip`, `instance_public_dns`,
`security_group_id`, `app_url`

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
