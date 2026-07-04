# Guia de Execução Local e Implantação Multicloud (AWS & Azure)
## Tech Challenge - Fase 02 (ToggleMaster)

Este guia consolida as instruções completas para:
1. **Executar e testar a aplicação localmente** (Docker Compose, LocalStack e script automatizado).
2. **Implantar na AWS** (Conta Pessoal com EKS, ECR, RDS, ElastiCache, SQS e DynamoDB via IRSA e KEDA).
3. **Implantar no Azure** (AKS, ACR, Azure PostgreSQL, Azure Redis e integração híbrida com SQS/DynamoDB).

---

## 💻 1. Execução e Teste Local

O ambiente local emula toda a infraestrutura de nuvem necessária (PostgreSQL, Redis, SQS e DynamoDB via LocalStack).

### Passo 1: Inicializar os Containers
Suba os 9 containers da aplicação:
```bash
docker compose up -d
```

### Passo 2: Semear a Chave de API de Teste
Os microsserviços utilizam o token `local-test-key` para comunicação interna. Insira o hash dessa chave no banco de dados de autenticação:
```bash
docker compose exec -T db-auth psql -U user -d auth -c "INSERT INTO api_keys (name, key_hash) VALUES ('local-test-key', 'ed80667ec3d95b40e0d38f0ca5661b5c2765c1dd62682640d0976f20bbd8254a') ON CONFLICT DO NOTHING;"
```

### Passo 3: Criar Recursos no LocalStack
Como o LocalStack inicia sem estado, crie a fila SQS e a tabela DynamoDB usadas pelo fluxo analítico:
```bash
# Criar fila SQS
docker compose exec localstack awslocal sqs create-queue --queue-name my-queue

# Criar tabela DynamoDB (analytics-events com chave de partição event_id)
docker compose exec localstack awslocal dynamodb create-table \
  --table-name analytics-events \
  --attribute-definitions AttributeName=event_id,AttributeType=S \
  --key-schema AttributeName=event_id,KeyType=HASH \
  --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5
```

### Passo 4: Executar Teste Ponta a Ponta
Rode o script de testes automatizado em Python localizado na raiz:
```bash
python3 test-local.py
```
O script testará os health checks, cadastrará uma flag e uma regra de porcentagem (75%), fará 10 requisições de avaliação, e mostrará que as mensagens foram enviadas à fila SQS, lidas pelo Analytics Worker e salvas com sucesso no banco DynamoDB.

---

## ☁️ 2. Implantação na AWS (Conta Pessoal - Opção B)

Ao rodar em conta pessoal, utilize ferramentas padrão de mercado (**eksctl, helm, IRSA, KEDA**) sem as restrições da AWS Academy.

### Arquitetura de Mapeamento AWS
* **EKS Cluster:** Criado via `eksctl` com provedor OIDC habilitado para autenticação segura.
* **ECR:** Registro privado para armazenar as 5 imagens de microsserviços.
* **RDS PostgreSQL:** 3 instâncias db.t3.micro (ou 1 instância compartilhando 3 bases de dados para economizar custos).
* **ElastiCache:** Cluster Redis (`cache.t3.micro`) simples de 1 nó.
* **DynamoDB:** Tabela `analytics-events` para logs analíticos.
* **SQS:** Fila padrão (`Standard`) para comunicação assíncrona.

### Passo 1: Enviar Imagens para o ECR
Substitua `123456789012` pelo ID da sua conta AWS:
```bash
# Autenticar no ECR
aws ecr get-login-password --region us-east-2 | docker login --username AWS --password-stdin 288302021178.dkr.ecr.us-east-2.amazonaws.com

# Criar os repositórios (Repita para os 5 serviços)
aws ecr create-repository --repository-name auth-service --region us-east-2

# Enviar imagem (Exemplo com auth-service)
docker tag auth-service:latest 123456789012.dkr.ecr.us-east-2.amazonaws.com/auth-service:latest
docker push 123456789012.dkr.ecr.us-east-2.amazonaws.com/auth-service:latest
```

### Passo 2: Criar Cluster EKS
Crie o arquivo `eks-cluster.yaml`:
```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: toggle-master-cluster
  region: us-east-1
  version: "1.29"
managedNodeGroups:
  - name: toggle-master-nodes
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 1
    maxSize: 4
iam:
  withOIDC: true
```
Execute o provisionamento:
```bash
eksctl create cluster -f eks-cluster.yaml
```

### Passo 3: Configurar Service Accounts com IRSA (SQS/DynamoDB)
Crie políticas locais do IAM para liberar acesso à fila SQS e tabela DynamoDB, depois vincule-as às contas de serviço no EKS:
```bash
# Criar conta de serviço para o analytics-service (Lê SQS e escreve no DynamoDB)
eksctl create iamserviceaccount \
  --name analytics-service-sa \
  --namespace toggle-master \
  --cluster toggle-master-cluster \
  --role-name EKS-AnalyticsService-Role \
  --attach-policy-arn=arn:aws:iam::123456789012:policy/SqsQueueAccessPolicy \
  --attach-policy-arn=arn:aws:iam::123456789012:policy/DynamoDbTableAccessPolicy \
  --approve
```

### Passo 4: Instalar Metrics Server, Nginx Ingress e KEDA
```bash
# Metrics Server (HPA)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Nginx Ingress
helm upgrade --install ingress-nginx ingress-nginx --repo https://kubernetes.github.io/ingress-nginx --namespace ingress-nginx --create-namespace

# KEDA
helm upgrade --install keda kedacore/keda --repo https://kedacore.github.io/charts --namespace keda --create-namespace
```

### Passo 5: Configurar HPA e KEDA
Abaixo está o ScaledObject do KEDA para o `analytics-service` ler do SQS na AWS e escalar de 0 a N:
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: analytics-service-scaler
  namespace: toggle-master
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: analytics-service
  minReplicas: 0
  maxReplicas: 5
  triggers:
    - type: aws-sqs-queue
      metadata:
        queueURL: https://sqs.us-east-1.amazonaws.com/123456789012/my-queue
        queueLength: "5"
        awsRegion: us-east-1
        identityOwner: operator
```

---

## ☁️ 3. Implantação na Nuvem Microsoft Azure

Para implantar no Azure de maneira eficiente e sem a necessidade de reescrever o código-fonte (que está acoplado ao SDK da AWS para chamadas SQS/DynamoDB), utilizamos uma **arquitetura híbrida**. Os microsserviços e bancos relacionais rodam no Azure, enquanto os pods no AKS consomem a mensageria e o NoSQL da AWS injetando credenciais do IAM via segredos do Kubernetes.

### Arquitetura de Mapeamento Azure
* **Compute & Cache:** Azure Kubernetes Service (AKS) e Azure Cache for Redis.
* **Bancos de Dados Relacionais:** Azure Database for PostgreSQL (Flexible Server).
* **Imagens:** Azure Container Registry (ACR).
* **Fila & NoSQL:** Amazon SQS e Amazon DynamoDB (AWS Pessoal).

### Passo 0: Registrar Provedores de Recursos na Azure (Obrigatório)
Se a sua assinatura do Azure for nova ou nunca tiver usado esses serviços, você precisa registrar os Provedores de Recursos (Resource Providers) para evitar erros de `MissingSubscriptionRegistration`. Execute os seguintes comandos:

```bash
# Registrar Container Registry (ACR)
az provider register --namespace Microsoft.ContainerRegistry

# Registrar Kubernetes Service (AKS)
az provider register --namespace Microsoft.ContainerService

# Registrar PostgreSQL Flexible Server
az provider register --namespace Microsoft.DBforPostgreSQL

# (Opcional) Verificar o status do registro (pode demorar alguns minutos)
az provider show --namespace Microsoft.ContainerRegistry --query "registrationState"
```

### Passo 1: Configurar Registro de Imagens (Azure ACR)
```bash
# Criar Grupo de Recursos
az group create --name toggle-master-rg --location eastus

# Criar ACR
az acr create --resource-group toggle-master-rg --name togglemasterregistry --sku Basic

# --- Opção A: Usando Azure Cloud Shell (Recomendado - não precisa de Docker local) ---
# O ACR build envia o código para a nuvem da Azure e compila lá diretamente.
az acr build --registry togglemasterregistry --image auth-service:latest ./auth-service
az acr build --registry togglemasterregistry --image flag-service:latest ./flag-service
az acr build --registry togglemasterregistry --image targeting-service:latest ./targeting-service
az acr build --registry togglemasterregistry --image evaluation-service:latest ./evaluation-service
az acr build --registry togglemasterregistry --image analytics-service:latest ./analytics-service

# --- Opção B: Usando terminal com Docker local ---
# az acr login --name togglemasterregistry
# docker tag auth-service:latest togglemasterregistry.azurecr.io/auth-service:latest
# docker push togglemasterregistry.azurecr.io/auth-service:latest
```

### Passo 2: Criar Cluster AKS integrado ao ACR
```bash
az aks create \
    --resource-group toggle-master-rg \
    --name toggle-master-aks \
    --node-count 2 \
    --attach-acr togglemasterregistry \
    --node-vm-size Standard_D2s_v3 \
    --generate-ssh-keys

# Obter credenciais de acesso locais do kubectl
az aks get-credentials --resource-group toggle-master-rg --name toggle-master-aks
```

### Passo 3: Provisionar PostgreSQL e Redis no Azure
```bash
# Criar servidor PostgreSQL Flexível (Crie as DBs auth, flags e targeting nele)
az postgres flexible-server create \
    --resource-group toggle-master-rg \
    --name togglemaster-db \
    --location eastus \
    --admin-user postgresuser \
    --admin-password MinhaSenhaSeguraAqui \
    --sku-name Standard_B1ms \
    --tier Burstable \
    --version 15

# Criar instância do Azure Cache for Redis
az redis create \
    --resource-group toggle-master-rg \
    --name togglemaster-cache \
    --location eastus \
    --sku Basic \
    --vm-size c0
```
> [!IMPORTANT]
> Lembre-se de abrir o firewall do servidor PostgreSQL para aceitar o tráfego originado da VNet do cluster AKS.

### Passo 4: Definir Kubernetes Secrets no AKS
Crie as chaves de acesso que apontam para os recursos do Azure (Postgres/Redis) e as chaves de credencial da AWS para que os SDKs se conectem ao SQS/DynamoDB na nuvem AWS.

Crie o arquivo `secrets.yaml`:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: toggle-master-cloud-secrets
  namespace: toggle-master
type: Opaque
data:
  # Connection strings codificadas em base64 (use echo -n '...' | base64)
  DATABASE_URL_AUTH: cG9zdGdyZXNxbDovL3Bvc3RncmVzdXNlcjpNaW5oYVNlbmhhU2VndXJhQWhlYWRA...
  DATABASE_URL_FLAGS: cG9zdGdyZXNxbDovL3Bvc3RncmVzdXNlcjpNaW5oYVNlbmhhU2VndXJhQWhlYWRA...
  DATABASE_URL_TARGETING: cG9zdGdyZXNxbDovL3Bvc3RncmVzdXNlcjpNaW5oYVNlbmhhU2VndXJhQWhlYWRA...
  REDIS_URL: cmVkaXM6Ly86c2VuaGFAZG9wLXJlZGlzLmNhY2hlLndpbmRvd3MubmV0OjYzNzk=

  # AWS Credentials para consumo remoto do SQS e DynamoDB
  AWS_ACCESS_KEY_ID: QUtJQVRFU1R...
  AWS_SECRET_ACCESS_KEY: U2VjcmV0S2V5SGVyZQ==
```
Aplique as chaves no AKS:
```bash
kubectl create namespace toggle-master
kubectl apply -f secrets.yaml
```

### Passo 5: Configurar Ingress e KEDA no AKS
Instale o Nginx Ingress Controller e o KEDA utilizando o Helm no cluster AKS:
```bash
# Nginx Ingress para expor as portas HTTP
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-resource-group"="toggle-master-rg"

# KEDA para autoescalamento orientado a eventos no Azure
helm upgrade --install keda kedacore/keda --repo https://kedacore.github.io/charts --namespace keda --create-namespace
```

Use o seguinte arquivo de configuração para fazer o KEDA se autenticar no SQS da AWS usando o segredo criado no Azure:
```yaml
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: aws-sqs-auth
  namespace: toggle-master
spec:
  secretTargetRef:
    - parameter: awsAccessKeyID
      name: toggle-master-cloud-secrets
      key: AWS_ACCESS_KEY_ID
    - parameter: awsSecretAccessKey
      name: toggle-master-cloud-secrets
      key: AWS_SECRET_ACCESS_KEY
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: analytics-service-scaler
  namespace: toggle-master
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: analytics-service
  minReplicas: 0
  maxReplicas: 5
  triggers:
    - type: aws-sqs-queue
      metadata:
        queueURL: https://sqs.us-east-1.amazonaws.com/123456789012/my-queue
        queueLength: "5"
        awsRegion: us-east-1
      authenticationRef:
        name: aws-sqs-auth
```

---

## 🧹 4. Descomissionamento de Recursos

Para evitar cobranças surpresa em suas contas pessoais após concluir a gravação do vídeo do Tech Challenge, delete os grupos de recursos:

**Na AWS (EKS & Outros):**
```bash
eksctl delete cluster --name toggle-master-cluster --region us-east-1
# Excluir instâncias criadas no console manualmente (RDS, ElastiCache, SQS e DynamoDB)
```

**No Azure:**
```bash
az group delete --name toggle-master-rg --yes --no-wait
```
