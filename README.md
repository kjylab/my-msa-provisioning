# my-msa-provisioning

> **kjylab 개인 GitOps 연습 환경** — [KTCloud-CloudNative-Troica-Team/msa-provisioning](https://github.com/KTCloud-CloudNative-Troica-Team/msa-provisioning) 포크.  
> 원본 대비 주요 차이: Docker Hub 사용, Traefik NLB HTTP 리스너 추가, E2E Secret 자동 갱신 스크립트.

AWS 인프라 (Terraform) + Kubernetes 클러스터 셋업 (Ansible) 단일 진실의 원천.

---

## 아키텍처 개요

```
[인터넷]
   │  port 80 (HTTP)
   ▼
[AWS NLB] ─── port 6443 (K8s API)
   │
   │  port 80 → NodePort 31896
   ▼
[Traefik (워커 노드)]
   │
   ├── /api/auth/**      → auth-service
   ├── /api/v1/users/**  → user-service
   ├── /api/v1/orders/** → user-api-gateway
   └── ...
```

- **클러스터**: AWS EC2 기반 kubeadm (master 3 + worker 3, ap-northeast-2)
- **Ingress**: Traefik NodePort 31896 → NLB port 80 경유 외부 노출
- **GitOps**: ArgoCD (NodePort 30090/30493, SSH 터널 접근)
- **Container Registry**: Docker Hub (원본 ECR 대신)

---

## 사전 요구사항

| 항목 | 버전 |
|---|---|
| AWS CLI | 2.x + `aws configure` |
| Terraform | **1.10.0+** |
| Ansible | 2.16+ (WSL Ubuntu / Linux / Mac) |
| Go | 1.22+ (ecr-credential-provider 빌드용) |
| gh CLI | latest (`gh auth login` 완료) |
| SSH key | `~/.ssh/ktcloud-bastion-node-key` |

---

## 전체 흐름

```
STEP 1: S3 backend 생성 (1회)
STEP 2: terraform apply
STEP 3: ecr-credential-provider 빌드
STEP 4: Ansible 실행 (k8s + ArgoCD + Traefik)
STEP 5: GitHub Secret 갱신 (BASE_URL)
STEP 6: ArgoCD 앱 배포 확인
─── 작업 종료 ───
STEP 7: destroy-temp.sh (임시 자원 정리)
─── 다음 사이클 ───
terraform apply → Ansible → GitHub Secret 갱신 반복
```

---

## STEP 1 — S3 backend 생성 (1회)

```bash
SUFFIX="troica-2026-jyupk"   # backend.tf와 일치
BUCKET="troica-tfstate-${SUFFIX}"
REGION="ap-northeast-2"

aws s3api create-bucket \
  --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"

aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration \
    'Rules=[{ApplyServerSideEncryptionByDefault:{SSEAlgorithm:AES256}}]'

aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

---

## STEP 2 — terraform apply

```bash
cd terraform

# 첫 실행
terraform init

# 플랜 확인 후 적용
terraform plan -out cluster-up.tfplan
terraform apply cluster-up.tfplan
```

완료 후 주요 output 확인:

```bash
terraform output ap-northeast-2a-bastion-node-connect-command
terraform output ap-northeast-2b-bastion-node-connect-command
terraform output nlb_dns_name   # E2E BASE_URL로 사용
```

### 생성 자원 분류

| 분류 | 자원 | 월 비용 |
|---|---|---|
| **영구** | OIDC, IAM, ECR KMS, ECR 레포, VPC/SG | ~$1 |
| **임시** | EC2 ×8, EBS ×3, EFS, NAT ×2, NLB, EIP ×4, VPC Endpoint ×3 | ~$300 |
| **수동** | S3 backend bucket | <$1 |

---

## STEP 3 — ecr-credential-provider 빌드

ECR pull을 위한 kubelet 플러그인 (GitHub Release에 바이너리 없어 직접 빌드):

```bash
mkdir -p /tmp/build && cd /tmp/build
git clone --depth 1 --branch v1.30.10 \
  https://github.com/kubernetes/cloud-provider-aws.git
cd cloud-provider-aws
CGO_ENABLED=0 go build -o /tmp/ecr-credential-provider ./cmd/ecr-credential-provider

# 확인
ls -lh /tmp/ecr-credential-provider   # ~30MB
```

---

## STEP 4 — Ansible 실행

### bastion SSH fingerprint 등록 (1회)

```bash
# terraform output으로 IP 확인 후
ssh ec2-user@<2a-bastion-ip> -i ~/.ssh/ktcloud-bastion-node-key   # yes → exit
ssh ec2-user@<2b-bastion-ip> -i ~/.ssh/ktcloud-bastion-node-key   # yes → exit
```

### ping 확인

```bash
cd ansible
ansible all -m ping -i inventory.ini -o
# 6개 노드 모두 pong 기대
```

### 전체 클러스터 셋업 (~10-15분)

```bash
ansible-playbook -i inventory.ini main.yaml
```

### 완료 확인

```bash
# bastion 경유 master 접속
ssh-add ~/.ssh/ktcloud-bastion-node-key
ssh -A -J ec2-user@<2b-bastion-ip> ec2-user@<b-master-01-private-ip>

kubectl get nodes          # 6개 Ready
kubectl get pods -A        # 모두 Running
kubectl -n argocd get application   # root-app 확인
```

### ArgoCD 접근 (SSH 터널)

```bash
# 로컬 PC에서
ssh -L 8080:<b-master-01-private-ip>:30090 \
    -i ~/.ssh/ktcloud-bastion-node-key \
    ec2-user@<2b-bastion-ip> -N

# 브라우저: http://localhost:8080
# admin 비밀번호:
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

---

## STEP 5 — GitHub Secret 갱신 (BASE_URL)

terraform apply 후 NLB DNS가 바뀌므로 매번 실행:

```bash
cd /path/to/my-msa-provisioning

# gh CLI 로그인 (최초 1회)
gh auth login

# Secret 자동 갱신
bash scripts/update-github-secrets.sh
```

대상 레포: `kjylab/my-msa-user-api-gateway`의 `BASE_URL` Secret  
→ 이후 E2E CI에서 `http://<새-NLB-DNS>` 자동 사용

---

## STEP 6 — 서비스 배포 확인

ArgoCD가 `kjylab/my-msa-manifest-values`를 바라보므로 각 서비스 main push 후 자동 배포됨.

```bash
# 전체 서비스 상태
kubectl get pods -n default

# 수동 테스트 (로컬 PC에서 NLB DNS로)
NLB=$(cd terraform && terraform output -raw nlb_dns_name)

# 로그인
TOKEN=$(curl -s -X POST $NLB/api/auth/sign-in \
  -H "Content-Type: application/json" \
  -d '{"email":"test@test.com","password":"test1234"}' \
  | grep -o '"accessToken":"[^"]*"' | cut -d'"' -f4)

# 주문 생성
curl -s -X POST $NLB/api/v1/orders \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"items":[{"inventoryId":1,"productId":"1","skuCode":"SKU-001","price":1000,"quantity":1,"status":"PENDING"}]}'
```

---

## STEP 7 — destroy (작업 종료, 비용 절감)

임시 자원만 삭제 (EC2, NAT, NLB, EFS, VPC Endpoint). 영구 자원(IAM, ECR, VPC, SG)은 유지.

```bash
cd /path/to/my-msa-provisioning

# Linux/Mac
bash scripts/destroy-temp.sh

# 무인 (확인 프롬프트 없이)
bash scripts/destroy-temp.sh --auto-approve
```

완료 후:
- ✅ 영구 자원 유지 (IAM Role ARN, ECR URL 불변 → GitHub Secrets 재등록 불필요)
- ✅ ECR 이미지 유지 → 다음 사이클 서비스 재빌드 불필요
- ✅ Docker Hub 이미지 유지
- 💰 월 ~$300 → $0 (destroy 기간)

---

## 다음 사이클 재개

```bash
cd terraform
terraform apply          # 임시 자원만 재생성 (영구는 unchanged)

cd ../ansible
ansible-playbook -i inventory.ini main.yaml

# GitHub Secret 갱신 (NLB DNS 변경됨)
bash scripts/update-github-secrets.sh
```

---

## 원본 대비 변경 사항 (kjylab fork)

| 항목 | 원본 | 이 포크 |
|---|---|---|
| Container Registry | AWS ECR | Docker Hub |
| CI 인증 | OIDC | GitHub PAT (`GH_PAT` secret) |
| Traefik NLB 노출 | 없음 | NLB port 80 → NodePort 31896 추가 |
| E2E Secret 갱신 | 없음 | `scripts/update-github-secrets.sh` 추가 |
| ArgoCD NodePort | 30080/30443 | 30090/30493 |

---

## 트러블슈팅

| 증상 | 원인 | 해결 |
|---|---|---|
| `kubectl` 연결 안됨 | kubeconfig 없음 | `ssh -L 6443:...` 터널 또는 마스터 노드 직접 접속 |
| E2E curl exit code 6 | NLB DNS 변경 | `bash scripts/update-github-secrets.sh` 재실행 |
| ArgoCD App OutOfSync | ConfigMap 수동 패치 | manifest-values 레포 git push로 반영 |
| `K8S_VARS_HOLDER unreachable` | Ansible 가상 호스트 | 다른 노드 정상이면 무시 |
| Traefik 404 | 라우트 미설정 | `my-msa-manifest-values`의 user-api-gateway values 확인 |
| DB connection 초과 | PostgreSQL 100 슬롯 | app pool size 줄이거나 pod 재시작 |
