#!/usr/bin/env bash
set -euo pipefail

log()  { echo "$*"; }
ok()   { echo "OK: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

echo "=== Terraform: init → apply local_file → verify → destroy ==="

# 1) container up?
if ! docker compose ps -a terraform | grep -q 'Up'; then
  fail "terraform container is not Up"
else
  ok "terraform container is Up"
fi

# 2) terraform CLI present in container
if docker compose exec -T terraform terraform version >/dev/null 2>&1; then
  ok "terraform CLI present"
else
  fail "terraform CLI missing in container"
fi

# 3) create a tiny project (inside container) and apply it
docker compose exec -T terraform sh -lc '
set -e
mkdir -p /workspace/infra
cd /workspace/infra
rm -rf .terraform* main.tf smoke_terraform.txt

cat > main.tf <<'"'"'TF'"'"'
terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "local" {}

resource "local_file" "smoke" {
  filename = "/workspace/infra/smoke_terraform.txt"
  content  = "hello-terraform"
}
TF

terraform init -input=false -no-color
terraform apply -auto-approve -input=false -no-color
'

# 4) verify file content
if docker compose exec -T terraform sh -lc 'test "$(cat /workspace/infra/smoke_terraform.txt)" = "hello-terraform"'; then
  ok "verification query returned expected content"
else
  fail "verification failed (unexpected file contents)"
fi

# 5) destroy
docker compose exec -T terraform sh -lc '
set -e
cd /workspace/infra
terraform destroy -auto-approve -input=false -no-color
'

echo
echo "RESULT: ✅ Terraform smoketest passed"
