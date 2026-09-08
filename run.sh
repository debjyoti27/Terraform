#!/usr/bin/env bash
# run.sh — multi-account SQS provisioner (create-only)
#
# The ONLY file you ever edit is terraform.tfvars.
#   • Add/remove accounts  →  edit the accounts = [...] list
#   • Add/remove queues    →  edit the queues   = {...} map
# Never edit this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="${SCRIPT_DIR}/terraform.tfvars"
REGION="${TF_VAR_region:-ap-south-1}"

mkdir -p "${SCRIPT_DIR}/state" "${SCRIPT_DIR}/env"

# ── Read accounts from terraform.tfvars ───────────────────────────────────────
# Parses:  accounts = [ { profile = "x", brand = "y" }, ... ]
# Outputs one "profile brand" line per entry.
if [[ ! -f "${TFVARS}" ]]; then
  echo "ERROR: terraform.tfvars not found."
  echo "Run:  cp terraform.tfvars.example terraform.tfvars  then fill in your values."
  exit 1
fi

mapfile -t ACCOUNTS < <(python3 - "${TFVARS}" <<'EOF'
import re, sys

content = open(sys.argv[1]).read()
m = re.search(r'accounts\s*=\s*\[(.*?)\]', content, re.DOTALL)
if not m:
    print("ERROR: no accounts block found in terraform.tfvars", file=sys.stderr)
    sys.exit(1)

for entry in re.finditer(r'\{([^}]+)\}', m.group(1)):
    e = entry.group(1)
    profile = re.search(r'profile\s*=\s*"([^"]*)"', e)
    brand   = re.search(r'brand\s*=\s*"([^"]*)"',   e)
    if profile and brand:
        print(profile.group(1), brand.group(1))
EOF
)

if [[ ${#ACCOUNTS[@]} -eq 0 ]]; then
  echo "ERROR: no accounts found in terraform.tfvars."
  echo "Add an accounts = [ { profile = \"x\", brand = \"y\" } ] block."
  exit 1
fi

echo "Accounts loaded:"
for account in "${ACCOUNTS[@]}"; do
  read -r profile brand <<< "$account"
  printf "  profile=%-20s brand=%s\n" "$profile" "$brand"
done
echo ""

# ── Helper: import queues that already exist in AWS but are not yet in state ──
import_existing_queues() {
  local profile="$1"
  local brand="$2"
  local region="$3"
  local plan_tmp="${SCRIPT_DIR}/.tfplan.${brand}.tmp"

  echo "  → Scanning for pre-existing queues to import..."

  terraform plan \
    -input=false \
    -out="${plan_tmp}" \
    -var "profile=${profile}" \
    -var "brand=${brand}" \
    -var "region=${region}" \
    > /dev/null

  terraform show -json "${plan_tmp}" \
  | jq -r '
      .resource_changes[]?
      | select(
          .type == "aws_sqs_queue"
          and (.change.actions | length == 1)
          and (.change.actions[0] == "create")
        )
      | [.address, .change.after.name]
      | @tsv
    ' \
  | while IFS=$'\t' read -r addr queue_name; do
      echo "  → Checking: ${queue_name}"
      if queue_url=$(aws sqs get-queue-url \
            --profile    "${profile}" \
            --region     "${region}" \
            --queue-name "${queue_name}" \
            --output text 2>/dev/null); then
        echo "     Found in AWS — importing ${addr}"
        terraform import \
          -input=false \
          -var "profile=${profile}" \
          -var "brand=${brand}" \
          -var "region=${region}" \
          "${addr}" "${queue_url}" \
          || echo "     Already in state — skipping"
      else
        echo "     Not in AWS — will be created by apply"
      fi
    done

  rm -f "${plan_tmp}"
}

# ── 1. Pre-flight gate (all-or-nothing) ───────────────────────────────────────
# Verify every unique profile before touching any account.
# If any profile fails, nothing is deployed — not even the ones that passed.
declare -A ACCOUNT_IDS
declare -A CHECKED_PROFILES
FAILED=()

echo "════════════════════════════════════════════════════════════════"
echo "  Pre-flight: verifying AWS profiles"
echo "════════════════════════════════════════════════════════════════"

for account in "${ACCOUNTS[@]}"; do
  read -r profile brand <<< "$account"
  [[ -v CHECKED_PROFILES["$profile"] ]] && continue  # skip if already verified

  if account_id=$(aws sts get-caller-identity \
        --profile "${profile}" \
        --query   Account \
        --output  text 2>&1); then
    printf "  OK   profile=%-20s account=%s\n" "${profile}" "${account_id}"
    ACCOUNT_IDS["${profile}"]="${account_id}"
    CHECKED_PROFILES["${profile}"]=1
  else
    printf "  FAIL profile=%-20s %s\n" "${profile}" "${account_id}"
    FAILED+=("${profile}")
    CHECKED_PROFILES["${profile}"]=1
  fi
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo ""
  echo "Pre-flight FAILED for profiles: ${FAILED[*]}"
  echo "Fix these in ~/.aws/config and re-run. No accounts were modified."
  exit 1
fi

echo ""
echo "All profiles verified."
echo ""

# ── 2. Per-account deployment (sequential) ───────────────────────────────────
for account in "${ACCOUNTS[@]}"; do
  read -r profile brand <<< "$account"
  account_id="${ACCOUNT_IDS[${profile}]}"
  state_file="${SCRIPT_DIR}/state/${brand}.tfstate"
  env_file="${SCRIPT_DIR}/env/${brand}.env"

  echo "════════════════════════════════════════════════════════════════"
  echo "  profile=${profile}   brand=${brand}   account=${account_id}"
  echo "════════════════════════════════════════════════════════════════"

  export TF_DATA_DIR="${SCRIPT_DIR}/.terraform.${brand}"
  cd "${SCRIPT_DIR}"

  echo "→ terraform init"
  terraform init \
    -reconfigure \
    -input=false \
    -backend-config="path=${state_file}"

  import_existing_queues "${profile}" "${brand}" "${REGION}"

  echo "→ terraform apply"
  terraform apply \
    -auto-approve \
    -input=false \
    -var "profile=${profile}" \
    -var "brand=${brand}" \
    -var "region=${REGION}"

  echo "→ Writing ${env_file}"
  terraform output -raw env_vars > "${env_file}"

  echo ""
  echo "  ${env_file}:"
  sed 's/^/    /' "${env_file}"
  echo ""

  unset TF_DATA_DIR
done

echo "════════════════════════════════════════════════════════════════"
echo "  All accounts deployed. env/ files ready."
echo "════════════════════════════════════════════════════════════════"
