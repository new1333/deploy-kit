# deploy-kit

个人 VPS 的项目无关部署框架：GitHub Actions 可复用 workflow + VPS 端幂等部署脚本 + 共享 edge 反代（Caddy）。

设计文档见 dear-notes 仓库 `docs/ci-cd-deploy-technical-design.md`。

## 架构

- 项目仓库 push `main` → 自己的 test job → `uses: new1333/deploy-kit/.github/workflows/deploy.yml@v1`
- kit 负责：构建镜像推 GHCR → SSH 到 VPS → 初始化/复用共享 edge → 同步编排文件 → 首次渲染 `.env`（来自项目仓库 Secrets）→ `docker compose pull && up -d` → 等健康 → 清理本项目旧镜像
- VPS 隔离：`/opt/<project>` 目录、`edge` 网络别名 `<project>-app`、`hosts/<project>.caddy` 站点、镜像 `ghcr.io/<owner>/<project>-*`，全部由 `project` 输入派生

## 新项目接入（3 步）

1. 仓库内放三个文件（模板见 `templates/`）：
   - `compose.yaml`：不含反代、不映射 host 端口；顶层 `name: <project>`；app 挂外部网络 `edge` 并声明唯一别名 `<project>-app`
   - `deploy/edge-site.caddy`：本项目站点块（`reverse_proxy <project>-app:<端口>`）
   - `.github/workflows/deploy.yml`：薄调用（模板改 `with:` 即可）
2. 配置 GitHub Secrets（`gh secret set`）：
   - VPS 级：`SSH_PRIVATE_KEY`、`VPS_HOST`、`VPS_USER`、（可选）`VPS_PORT`
   - `.env` 渲染值：`POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD` / `APP_ORIGIN` / `LOG_LEVEL`；项目特有变量放 `EXTRA_ENV`（多行 `KEY=VALUE`）
3. push 到 `main`，首次部署自动完成其余一切（含 edge 初始化，仅第一个项目发生）。

## 回滚

项目仓库 Actions 页手动触发 deploy workflow，`image_tag` 输入填上一个短 sha。

## 约定与限制

- `.env` 仅首次部署渲染；密码类值永不自动重写（轮换 `POSTGRES_PASSWORD` 需手动 `ALTER USER`）
- kit 以 `@v1` tag 引用，升级影响所有接入项目
- VPS 级 Secrets 每个接入仓库各存一份，轮换用 `gh` 批量刷
