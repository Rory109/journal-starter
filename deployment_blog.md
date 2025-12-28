# 从本地到云端：FastAPI 应用的 Azure 全自动化部署实战总结

## 前言

在现代软件开发中，将应用从本地环境（Localhost）迁移到生产环境（Cloud）往往是开发周期中最具挑战性的一环。本文记录了将一个 Python FastAPI 应用（Journal API）容器化，并通过 CI/CD 流水线自动化部署到 Azure 云平台的完整过程。

在这个过程中，我们遇到了数据库连接字符串解析错误、自动化建表难题以及 CI/CD 环境变量传递等经典“坑点”，希望这份实战记录能为你的 DevOps 之路提供参考。

---

## 技术栈概览

*   **应用框架**: FastAPI (Python 3.10)
*   **数据库**: Azure Database for PostgreSQL
*   **基础设施**: Terraform (IaC)
*   **容器化**: Docker & Docker Compose
*   **CI/CD**: GitHub Actions

---

## 1. 基础设施即代码 (IaC) 与密码的“陷阱”

我们使用 Terraform 来编排 Azure 资源（虚拟机和数据库）。看似顺利的过程，却在数据库连接上绊了一跤。

### 遇到的问题：Invalid IPv6 URL
在应用尝试连接数据库时，报错 `ValueError: Invalid IPv6 URL`。
**原因分析**：Terraform 生成的随机密码中包含了一些特殊字符（如 `[` 或 `]`）。Python 的 `urllib` 库在解析连接字符串时，误将这些方括号识别为 IPv6 地址的标记。

### 解决方案
最初我们尝试对密码进行 URL 编码（Percent-encoding），但这治标不治本。最终，我们在源头解决了问题——修改 Terraform 配置，限制随机密码生成的特殊字符范围：

```hcl
# infra/main.tf
resource "random_password" "db_password" {
  length           = 16
  special          = true
  # 只使用 URL 安全的特殊字符，避免解析冲突
  override_special = "_-!~"
}
```

---

## 2. 数据库迁移：从手动到自动

在本地开发时，我们习惯手动运行 SQL 脚本来建表。但在云端环境中，每次重新部署或销毁重建后都手动连数据库显然是不现实的。

### 方案演进
1.  **手动模式**：通过 SSH 连上服务器，用 `psql` 运行 `database_setup.sql`。❌ (太繁琐)
2.  **Alembic**：引入专业的数据库迁移工具。❌ (对于当前 MVP 阶段，配置偏重)
3.  **应用自举 (Bootstrap)**：✅ 让 FastAPI 在启动时自动检查并创建表。

我们实现了一个轻量级的初始化逻辑：

```python
# api/repositories/postgres_repository.py
async def initialize_tables(self):
    async with self.pool.acquire() as conn:
        await conn.execute("""
            CREATE TABLE IF NOT EXISTS entries (
                ...
            );
        """)
```

并在 `main.py` 的启动事件中调用它：

```python
# api/main.py
@app.on_event("startup")
async def startup_db_client():
    logger.info("Checking database tables...")
    async with PostgresDB() as db:
        await db.initialize_tables()
```

---

## 3. 构建 CI/CD 流水线

我们使用 GitHub Actions 实现了“提交代码即上线”。

### 关键配置技巧
在部署环节，最大的挑战是如何安全地将 GitHub Secrets 中的 `DATABASE_URL` 传递给远端的 Docker 容器，而不将其暴露在日志中。

我们使用了 `appleboy/ssh-action`，通过 `envs` 参数透传环境变量：

```yaml
# .github/workflows/ci.yml
- name: Deploy to Azure VM
  uses: appleboy/ssh-action@v1.0.0
  with:
    host: ${{secrets.SSH_HOST}}
    # ...
    envs: DATABASE_URL  # 显式声明要传递的变量
    script: |
      # 安全地将变量写入 .env 文件
      if [ ! -f .env ];then
        echo "DATABASE_URL=$DATABASE_URL" > .env 
      fi
      docker compose pull
      docker compose up -d
  env:
    DATABASE_URL: ${{secrets.DATABASE_URL}}
```

---

## 4. 经验教训 (Troubleshooting)

1.  **Python 导入错误**：在 `main.py` 中使用了 `PostgresDB` 类却忘记 import，导致应用启动失败。 -> **检查你的 Imports！**
2.  **YAML 缩进**：CI 配置文件对缩进极其敏感，错误的缩进曾导致环境变量无法正确读取。
3.  **连接字符串协议**：`asyncpg` 需要 `postgresql://` 而非 `postgres://`，且对空值非常敏感。

## 结语

通过这次实战，我们成功实现了一个无需人工干预、具备自我修复能力（自动建表、自动重启）的云原生应用部署架构。从手动 SSH 到全自动 CI/CD，不仅提高了发布效率，更增强了系统的稳定性。

Happy Coding! 🚀
