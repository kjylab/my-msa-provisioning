# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 개요

Troica Market Service MSA의 **AWS 인프라 (Terraform) + Kubernetes 클러스터 셋업 (Ansible)** 레포지토리.

- 매니페스트 + SPEC + ADR: `msa-argocd-manifest` 레포 참조
- 트러블슈팅: `msa-argocd-manifest/docs/TROUBLESHOOTING.md` 참조

## 사전 요구사항

| 항목 | 버전 |
|---|---|
| Terraform | **1.10.0+** (S3 backend native lockfile 요구) |
| Ansible | 2.16+ |
| Go | 1.22+ (ecr-credential-provider 빌드용) |
| AWS CLI | 2.x + `aws configure` |
| SSH key | `~/.ssh/ktcloud-bastion-node-key` |

## 주요 커맨드

### Terraform

```bash
cd terraform

# 초기화 (첫 실행 또는 backend 변경 시)
terraform init
terraform init -migrate-state   # 로컬 state → S3 마이그레이션 시

# 전체 apply
terraform plan -out phase-0.tfplan
terraform apply phase-0.tfplan

# 임시 자원만 destroy (비용 사이클 — EC2/NAT/NLB/EFS 제거, OIDC/IAM/ECR/KMS 보존)
bash scripts/destroy-temp.sh
bash scripts/destroy-temp.sh --auto-approve   # 무인

# 다음 사이클 재개 (임시 자원만 재생성)
terraform apply

# 주요 출력 확인
terraform output gha_ecr_push_role_arn
terraform output ecr_registry_url
terraform output ap-northeast-2a-bastion-node-connect-command
terraform output ap-northeast-2b-bastion-node-connect-command
```

### Ansible

```bash
cd ansible

# 연결 확인 (6개 노드 모두 pong 기대)
ansible all -m ping -i inventory.ini -o

# 전체 클러스터 셋업 (~10-15분)
ansible-playbook -i inventory.ini main.yaml

# 특정 playbook만 실행
ansible-playbook -i inventory.ini <playbook-name>.yaml
```

### ecr-credential-provider 빌드 (Go)

```bash
mkdir -p /tmp/build && cd /tmp/build
git clone --depth 1 --branch v1.30.10 https://github.com/kubernetes/cloud-provider-aws.git
cd cloud-provider-aws
CGO_ENABLED=0 go build -o /tmp/ecr-credential-provider ./cmd/ecr-credential-provider
```

ansible `ecr-credential-provider-setup.yaml` 실행 전 `/tmp/ecr-credential-provider` 바이너리가 있어야 함.

## 아키텍처

### AWS 자원 분류 (자원 수명 관리의 핵심)

| 분류 | 자원 | 보호 방식 |
|------|------|-----------|
| **영구** | OIDC Provider, IAM Role/Policy, ECR KMS key, ECR 레포 × 6, VPC/Subnet/SG | `lifecycle { prevent_destroy = true }` |
| **임시** | EC2 × 8, EBS × 3, EFS, NAT × 2, NLB, EIP × 4, VPC Endpoint × 3 | `destroy-temp.sh -target` |
| **수동** | S3 backend bucket | Terraform 외부 1회 생성 |

**핵심 원칙**: 영구 자원은 모두 **name-based** ARN/URL → destroy 후 재apply해도 동일 ARN/URL 보존 → GitHub Secrets 영구 유효.

### Terraform 구조

- `backend.tf` — S3 remote state (bucket: `troica-tfstate-troica-2026-jyupk`, region: `ap-northeast-2`, Terraform 1.10+ native lockfile, DynamoDB 불필요)
- `vpc.tf` — VPC(`10.0.0.0/16`), NLB(외부), SG(bastion/cluster), k8s API TG(port 6443)
- `ecr.tf` — ECR 레포 6개 (`msa/<service>`), KMS 암호화, IMMUTABLE 태그, 30개 lifecycle
- `oidc.tf` — GitHub Actions OIDC Provider + IAM Role(`troica-gha-ecr-push`), `msa-*` 레포 main 브랜치만 신뢰
- `iam.tf` — EC2 node IAM role/instance profile
- `2a-*.tf` / `2b-*.tf` — AZ별 EC2(master/worker/bastion), NAT, subnet 분리
- `variables.tf` — 6개 MSA 서비스 목록 (`user/auth/product/inventory/order/api-gateway`)

### Ansible Playbook 실행 순서 (main.yaml)

1. `k8s-pre-setup` → `k8s-pkg-install` → `containerd-setup` (모든 노드)
2. `master-init` → `master-cni-setup` (Calico) → `master-python-setup`
3. `join-master` (HA) → `join-worker`
4. `helm-setup` → `argocd-setup`
5. `ecr-credential-provider-setup` (kubelet ECR 인증 — 반드시 클러스터 완성 후)

**주의**: `nlb-setup.yaml`(AWS LB Controller)은 주석 처리됨. Troica는 외부 NLB를 Terraform으로 직접 생성, 클러스터 내 ingress는 Istio Gateway 사용. LBC mutating webhook이 ArgoCD Service 생성을 가로채는 문제로 제거됨.

### CI/CD 연동 (GitHub Actions OIDC)

GHA workflow가 `troica-gha-ecr-push` IAM Role을 STS AssumeRoleWithWebIdentity로 assume → ECR push 권한 획득. long-lived AWS key 미사용.

GitHub Org Secrets/Variables 필요:
- `AWS_ACCOUNT_ID` (Secret)
- `MANIFEST_PAT` (Secret — `msa-argocd-manifest` contents:write + pull-requests:write)
- `AWS_DEPLOYMENTS_ENABLED=true` (Variable — 6개 서비스 CI 활성화)

### 네트워크 구조

- VPC: `10.0.0.0/16`, region: `ap-northeast-2`
- 2개 AZ(2a/2b)에 각각 public/private subnet
- bastion-node-sg: 현재 apply 시점 호출자 IP만 SSH 허용 (`data.http.my_ip`로 동적 취득)
- cluster-node-sg: VPC 내 전 포트 허용 + bastion에서만 SSH + 전체에서 k8s API(6443)

## 주요 트러블슈팅 패턴

- **`.sh` 스크립트 CRLF 오류 (Windows)**: `.gitattributes`로 LF 강제, 재clone 또는 `destroy-temp.ps1` 사용
- **cloud-provider-aws 바이너리 404**: GitHub Release에 asset 없음 → Go 직접 빌드 (STEP 3)
- **kubelet ECR pull 실패**: `kubeadm-flags.env` 직접 수정 fallback이 playbook에 포함됨 (R-30)
- **K8S_VARS_HOLDER unreachable**: `join-master.yaml`의 vars 저장용 가상 호스트 — 다른 노드 정상이면 무시
- **prevent_destroy 일시 해제**: `oidc.tf`/`ecr.tf`의 `prevent_destroy = true` → `false` 변경 후 destroy (프로젝트 종료 시만)
