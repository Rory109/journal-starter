# Kubernetes (Kind) 部署完整指南 & 复盘

本文档记录了将 Journal API 项目部署到本地 Kubernetes (Kind) 集群的完整流程与故障排除记录。

## 1. 完整构建与部署流程 (SOP)

### 前置准备
确保已安装 `kind`, `kubectl`, `docker`，并且 Kind 集群已创建。

### 步骤 1: 构建与加载镜像
由于 Kind 运行在 Docker 容器中，它无法直接读取本地 Docker 镜像，必须显式加载。

```bash
# 1. 构建本地镜像
docker build -t journal:local .

# 2. 将镜像加载到 Kind 集群节点中
# 注意：--name 必须匹配你的集群名称 (e.g. journal-cluster)
kind load docker-image journal:local --name journal-cluster
```

### 步骤 2: 环境准备 (Namespace & Secrets)
我们使用 `dev` 命名空间来隔离环境，并用 Secret 存储敏感信息。

```bash
# 1. 创建命名空间
kubectl create namespace dev

# 2. 创建数据库凭证 Secret
kubectl create secret generic postgres-secret \
  --from-literal=POSTGRES_USER=postgres \
  --from-literal=POSTGRES_PASSWORD=password \
  --from-literal=POSTGRES_DB=journal_db \
  -n dev

# 3. 创建应用连接 Secret (注意：主机名必须是 postgres Service 的名字)
kubectl create secret generic app-secret \
  --from-literal=FULL_DB_URL="postgresql://postgres:password@postgres:5432/journal_db" \
  -n dev
```

### 步骤 3: 部署数据库 (Postgres)
数据库是有状态服务，但在开发环境中我们可以简化部署。

```bash
# 应用 Postgres 配置 (包含 Deployment, Service, ConfigMap)
kubectl apply -f k8s/postgres.yaml

# 验证
kubectl get pods -n dev -l app=postgres
```

### 步骤 4: 部署应用 (Journal API)
应用是无状态服务，通过环境变量连接数据库。

```bash
# 应用 App 配置 (包含 Deployment, Service)
kubectl apply -f k8s/deployment.yaml

# 验证
kubectl get pods -n dev -l app=journal-api
```

### 步骤 5: 验证访问
由于我们使用的是 ClusterIP (集群内网 IP)，本地访问需要端口转发。

```bash
# 将集群内的 journal-app 服务端口 80 转发到本地 8081
kubectl port-forward svc/journal-app 8081:80 -n dev

# 测试接口
curl http://localhost:8081/entries
```

---

## 2. 遇到的 Bug 与 解决方案复盘

在部署过程中，我们遇到了以下几个关键问题：

### Bug 1: 部署文件语法错误 (valueFrom)
*   **现象**: 执行 `kubectl apply` 时报错：`strict decoding error: unknown field "spec.template.spec.containers[0].valueFrom"`。
*   **原因**: 在 `deployment.yaml` 中，`env` 列表的写法错误。我们试图直接把 `valueFrom` 作为列表项，但每个列表项必须先有一个 `name`。
*   **错误写法**:
    ```yaml
    env:
      valueFrom: ... # ❌ 缺少 name
    ```
*   **修正**:
    ```yaml
    env:
    - name: DATABASE_URL # ✅ 必须指定变量名
      valueFrom: ...
    ```

### Bug 2: 缺少 Service 定义
*   **现象**: 应用 Pod 虽然启动了，但没有 ClusterIP，导致无法通过网络访问，也无法做端口转发。
*   **原因**: `deployment.yaml` 只定义了 `Deployment` (如何跑容器)，忘记定义 `Service` (如何访问容器)。
*   **修正**: 在 `deployment.yaml` 中追加了 `Service` 定义，暴露端口 80，转发到容器的 8000 端口。

### Bug 3: Secret Key 不匹配 / Pod 启动失败
*   **现象**: Pod 状态显示 `CreateContainerConfigError`。
*   **详情**: `kubectl describe pod` 显示错误 `Error: couldn't find key FULL_DB_URL in Secret dev/app-secret`。
*   **原因**: 之前的操作中 `app-secret` 已经存在（可能是旧的），导致新创建的 Secret 命令失败（`already exists`），因此 Secret 里并没有我们要的 `FULL_DB_URL` key。
*   **修正**:
    1. 删除旧 Secret: `kubectl delete secret app-secret -n dev`
    2. 重新创建 Secret。
    3. 删除报错的 Pod (让 Deployment 自动重启新的)。

### Bug 4: 访问 404 Not Found
*   **现象**: `curl http://localhost:8081/` 返回 `{"detail":"Not Found"}`。
*   **原因**: 这是一个**预期行为**。我们的 `main.py` 虽然定义了 `get_all_entries` 路由，但并没有把它注册到 `app` 实例上。只有 `/entries` 路由被正确注册了。
*   **修正**: 访问正确的路径 `http://localhost:8081/entries`，成功返回数据。

---

## 3. 架构总结图

```mermaid
graph TD
    User[用户/开发者] -- "kubectl port-forward" --> LocalPort[localhost:8081]
    LocalPort -- 转发 --> K8sService[Service: journal-app]
    
    subgraph "K8s Namespace: dev"
        K8sService -- 负载均衡 --> Pod1[Pod: Journal API]
        K8sService -- 负载均衡 --> Pod2[Pod: Journal API]
        
        Pod1 -- "DNS: postgres" --> DBService[Service: postgres]
        Pod2 -- "DNS: postgres" --> DBService
        
        DBService --> DBPod[Pod: Postgres]
        
        Secret[Secret: app-secret] -.-> |注入 ENV: DATABASE_URL| Pod1 & Pod2
    end
```
