#!/bin/bash
set -euo pipefail
trap "echo -e \"\${RED}Error on line \$LINENO\${NC}\"; exit 1" ERR

RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

COMMIT_SHA=""
CLOUDFLARE_API_TOKEN=""
CF_ACCOUNT_ID=""
CUSTOM_DOMAIN=""
WORKERS_DEV_DOMAIN_ENABLED="true"
R2_BUCKET="r2-pull-through-registry"
R2_BUCKET_EXPIRE_BLOBS="30"
R2_BUCKET_ABORT_MULTIPART="1"
R2_BUCKET_IA_TRANSITION="14"
REPO_URL="https://github.com/cloudflare/serverless-registry.git"
REPO_DIR="/tmp/r2-registry"
REGISTRY_USERNAME=""
REGISTRY_PASSWORD=""
UPSTREAM_USERNAME=""
UPSTREAM_PASSWORD=""
UPSTREAM_REGISTRY="index.docker.io"

print_help() {
  echo -e "${BLUE}Description:${NC} This script automates the creation and deployment of a Docker registry using Cloudflare Workers and R2."
  echo -e "${BLUE}Usage:${NC} $0 [OPTIONS]"
  echo "  --commit-sha COMMIT                           Commit SHA to use for serverless-registry repo (optional)"
  echo "  --cf-token TOKEN                              Cloudflare API Token (required)"
  echo "  --cf-account-id CLOUDFLARE_ACCOUNT_ID         Cloudflare Account ID (required)"
  echo "  --domain DOMAIN                               Custom domain (optional)"
  echo "  --default-worker-domain-enabled [true|false]  Enable default worker domain (optional, default: true)"
  echo "  --r2-bucket NAME                              R2 bucket name (optional, default: r2-pull-through-registry)"
  echo "  --r2-bucket-expire-days DAYS                  Number of days to expire blobs in R2 bucket (optional, default: 30)"
  echo "  --r2-bucket-abort-multipart DAYS              Number of days to abort multipart uploads in R2 bucket (optional, default: 7)"
  echo "  --r2-bucket-ia-transition DAYS                Number of days to transition blobs to Infrequent Access storage in R2 bucket (optional, default: 14)"
  echo "  --username USER                               Registry username (optional)"
  echo "  --password PASS                               Registry password (optional)"
  echo "  --upstream-username UPSTREAM_USER             Upstream registry token (optional, required if deploying with an upstream registry)"
  echo "  --upstream-password UPSTREAM_PASS             Upstream registry token (optional, required if deploying with an upstream registry)"
  echo "  --upstream-registry UPSTREAM_REGISTRY         Upstream registry url (optional, default: index.docker.io)"
  echo "  -h, --help                                    Show help"
  echo
  exit 0
}

parse_arguments() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --commit-sha)
        COMMIT_SHA="$2"
        shift 2
        ;;
      --cf-token)
        CLOUDFLARE_API_TOKEN="$2"
        shift 2
        ;;
      --cf-account-id)
        CLOUDFLARE_ACCOUNT_ID="$2"
        shift 2
        ;;
      --domain)
        CUSTOM_DOMAIN="$2"
        shift 2
        ;;
      --default-worker-domain-enabled)
        WORKERS_DEV_DOMAIN_ENABLED="$2"
        shift 2
        ;;
      --r2-bucket)
        R2_BUCKET="$2"
        shift 2
        ;;
      --r2-bucket-expire-days)
        R2_BUCKET_EXPIRE_BLOBS="$2"
        shift 2
        ;;
      --r2-bucket-abort-multipart)
        R2_BUCKET_ABORT_MULTIPART="$2"
        shift 2
        ;;
        --r2-bucket-ia-transition)
        R2_BUCKET_IA_TRANSITION="$2"
        shift 2
        ;;
      --username)
        REGISTRY_USERNAME="$2"
        shift 2
        ;;
      --password)
        REGISTRY_PASSWORD="$2"
        shift 2
        ;;
      --upstream-username)
        UPSTREAM_USERNAME="$2"
        shift 2
        ;;
      --upstream-password)
        UPSTREAM_PASSWORD="$2"
        shift 2
        ;;
      --upstream-registry)
        UPSTREAM_REGISTRY="$2"
        shift 2
        ;;
      -h|--help)
        print_help
        ;;
      *)
        echo -e "${RED}Unknown option: $1${NC}"
        print_help
        ;;
    esac
  done

  if [ -z "$CUSTOM_DOMAIN" ] && [ "$WORKERS_DEV_DOMAIN_ENABLED" = "false" ]; then
    echo -e "${RED}Error: default worker domain can't be disabled if no custom domain is provided.${NC}"
    exit 1
  fi
}

setup_repo() {
  if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
    echo -e "${RED}Error: Missing required flag '--cf-token'.${NC}"
    print_help
    exit 1
  fi

  if [ -z "$CLOUDFLARE_ACCOUNT_ID" ]; then
    echo -e "${RED}Error: Missing required flag '--cf-account-id'.${NC}"
    print_help
    exit 1
  fi

  export CLOUDFLARE_API_TOKEN
  if [ -d "$REPO_DIR" ]; then
    rm -rf "$REPO_DIR"
  fi

  git clone --single-branch --branch main "$REPO_URL" "$REPO_DIR" || {
    echo -e "${RED}Failed to clone repo.${NC}"
    exit 1
  }

  cd "$REPO_DIR" || { 
    echo -e "${RED}Failed to enter repo directory ${REPO_DIR}${NC}"
  }

  if [ -n "$COMMIT_SHA" ]; then
    git checkout "$COMMIT_SHA"
  fi
}

create_r2_bucket() {
    echo -e "${BLUE}Creating R2 bucket if it does not exist...${NC}"
    if npx wrangler r2 bucket info "$R2_BUCKET" --env production > /dev/null 2>&1; then
        echo -e "${YELLOW}R2 bucket '$R2_BUCKET' already exists.${NC}"
    else
        npx wrangler r2 bucket create "$R2_BUCKET" --env production || true
    fi

    existing_rules=$(npx wrangler r2 bucket lifecycle list "$R2_BUCKET")

    if echo "$existing_rules" | grep -q "registry-managed-rule-expire"; then
        echo -e "${BLUE}Deleting existing R2 bucket expiration policy...${NC}"
        npx wrangler r2 bucket lifecycle remove "$R2_BUCKET" --id registry-managed-rule-expire
    fi
    if [ -n "$R2_BUCKET_EXPIRE_BLOBS" ]; then
        echo -e "${BLUE}Setting R2 bucket expiration policy...${NC}"
        npx wrangler r2 bucket lifecycle add "$R2_BUCKET" \
            --expire-days "$R2_BUCKET_EXPIRE_BLOBS" \
            --env production \
            --id registry-managed-rule-expire \
            --force 
    fi

    if echo "$existing_rules" | grep -q "registry-managed-rule-abort-multipart"; then
        echo -e "${BLUE}Deleting existing R2 bucket multipart upload abort policy...${NC}"
        npx wrangler r2 bucket lifecycle remove "$R2_BUCKET" --id registry-managed-rule-abort-multipart
    fi
    if [ -n "$R2_BUCKET_ABORT_MULTIPART" ]; then
        echo -e "${BLUE}Setting R2 bucket multipart upload abort policy...${NC}"
        npx wrangler r2 bucket lifecycle add "$R2_BUCKET" \
            --abort-multipart-days "$R2_BUCKET_ABORT_MULTIPART" \
            --env production \
            --id registry-managed-rule-abort-multipart \
            --force
    fi

    if echo "$existing_rules" | grep -q "registry-managed-rule-infrequent-access-transition"; then
        echo -e "${BLUE}Deleting existing R2 bucket Infrequent Access transition policy...${NC}"
        npx wrangler r2 bucket lifecycle remove "$R2_BUCKET" --id registry-managed-rule-infrequent-access-transition
    fi
    if [ -n "$R2_BUCKET_IA_TRANSITION" ]; then
        echo -e "${BLUE}Setting R2 bucket Infrequent Access transition policy...${NC}"
        npx wrangler r2 bucket lifecycle add "$R2_BUCKET" \
            --ia-transition-days "$R2_BUCKET_IA_TRANSITION" \
            --env production \
            --id registry-managed-rule-infrequent-access-transition \
            --force
    fi
}

setup_default_credentials() {
  if [ -z "$REGISTRY_USERNAME" ]; then
    REGISTRY_USERNAME="registryadmin"
    echo -e "${YELLOW}No registry username provided. Generated username:${NC} $REGISTRY_USERNAME"
  fi
  if [ -z "$REGISTRY_PASSWORD" ]; then
    REGISTRY_PASSWORD=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 16 2>/dev/null)
    echo -e "${YELLOW}No registry password provided. Generated password:${NC} $REGISTRY_PASSWORD"
  fi
}

create_wrangler_toml() {
  echo -e "${BLUE}Creating wrangler.toml for production...${NC}"
  wrangler_toml="$REPO_DIR/wrangler.toml"

  if [ -n "$CUSTOM_DOMAIN" ]; then
    echo -e "${BLUE}Adding routes section to wrangler.toml under [env.production]...${NC}"
    cat >>"$wrangler_toml" <<EOF
routes = [
  { pattern = "${CUSTOM_DOMAIN}", custom_domain = true }
]

EOF
  fi

  cat >>"$wrangler_toml" <<EOF
name = "r2-registry"

workers_dev = ${WORKERS_DEV_DOMAIN_ENABLED}
main = "./index.ts"
compatibility_date = "2024-12-30"
compatibility_flags = ["nodejs_compat"]

[observability]
enabled = true

[env.production]
r2_buckets = [
  { binding = "REGISTRY", bucket_name = "${R2_BUCKET}" }
]
EOF

  if grep -q "bucket_name = \"${R2_BUCKET}\"" "$wrangler_toml"; then
    echo -e "${BLUE}wrangler.toml created successfully.${NC}"
  else
    echo -e "${RED}Failed to create wrangler.toml.${NC}"
    exit 1
  fi

  if [ -n "$UPSTREAM_USERNAME" ] && [ -n "$UPSTREAM_PASSWORD" ] && [ -n "$UPSTREAM_REGISTRY" ]; then
    echo -e "${BLUE}Appending upstream registry JSON to wrangler.toml...${NC}"
    cat >>"$REPO_DIR/wrangler.toml" <<EOF
[env.production.vars]
REGISTRIES_JSON = "[{ \"registry\": \"${UPSTREAM_REGISTRY}\", \"password_env\": \"REGISTRY_TOKEN\", \"username\": \"${UPSTREAM_USERNAME}\" }]"
EOF
    else 
      echo -e "${YELLOW}No complete upstream registry credentials set provided. Skipping setting upstream registry...${NC}"
    fi
}

install_dependencies() {
  echo -e "${BLUE}Installing dependencies...${NC}"
  pnpm install
}

configure_secrets() {
  if [ -n "$REGISTRY_USERNAME" ] && [ -n "$REGISTRY_PASSWORD" ] && [ -n "$UPSTREAM_PASSWORD" ]; then
    echo -e "${BLUE}Setting registry username/password secrets...${NC}"
    echo "$REGISTRY_USERNAME" | npx wrangler secret put USERNAME --env production
    echo "$REGISTRY_PASSWORD" | npx wrangler secret put PASSWORD --env production
    echo "$UPSTREAM_PASSWORD" | npx wrangler secret put REGISTRY_TOKEN --env production
  fi
}

deploy() {
  echo -e "${BLUE}Deploying to Cloudflare Workers...${NC}"
  npx wrangler deploy --env production --outdir dist
  echo -e "${BLUE}Deployment complete.${NC}"
  echo -e "${YELLOW}The username of your registry is:${NC} ${REGISTRY_USERNAME}"
  echo -e "${YELLOW}The password of your registry is:${NC} ${REGISTRY_PASSWORD}"
}

parse_arguments "$@"
setup_repo
setup_default_credentials
create_wrangler_toml
create_r2_bucket
install_dependencies
configure_secrets
deploy