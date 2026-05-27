#!/usr/bin/env bash
# update-github-secrets.sh
#
# terraform apply 후 NLB DNS를 읽어 GitHub Secret BASE_URL을 자동 갱신.
# E2E 워크플로에서 사용하는 BASE_URL이 항상 현재 NLB를 가리키도록 유지.
#
# 사용:
#   bash scripts/update-github-secrets.sh
#
# 사전 조건:
#   - `gh` CLI 설치 + `gh auth login` 완료 (또는 GITHUB_TOKEN env var)
#   - terraform apply 완료 상태 (state에 NLB 리소스 존재)

set -euo pipefail

cd "$(dirname "$0")/../terraform"

echo "==> Terraform output에서 NLB DNS 읽는 중..."
BASE_URL=$(terraform output -raw nlb_dns_name)

if [[ -z "$BASE_URL" ]]; then
  echo "ERROR: nlb_dns_name output이 비어 있습니다. terraform apply가 완료됐는지 확인하세요."
  exit 1
fi

echo "BASE_URL: $BASE_URL"

# BASE_URL secret을 갱신할 레포 목록
REPOS=(
  "kjylab/my-msa-user-api-gateway"
)

echo ""
echo "==> GitHub Secret 'BASE_URL' 갱신 중..."
for REPO in "${REPOS[@]}"; do
  echo "  → $REPO"
  gh secret set BASE_URL \
    --repo "$REPO" \
    --body "$BASE_URL"
done

echo ""
echo "==> 완료!"
echo "    BASE_URL=$BASE_URL"
echo "    다음 E2E 실행부터 새 NLB 주소를 사용합니다."
