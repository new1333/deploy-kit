#!/usr/bin/env bash
# VPS 端通用幂等部署脚本（由 deploy-kit 的 reusable workflow 通过 SSH 调用）。
# 环境变量由 workflow 注入：PROJECT/TAG/OWNER/MIGRATE_TARGET + .env 渲染值（EXTRA_ENV_B64）。
set -euo pipefail
umask 177

: "${PROJECT:?PROJECT is required}"
: "${TAG:?TAG is required}"
: "${OWNER:?OWNER is required}"

STAGE=/tmp/deploy-stage/extracted
EXTRA_ENV="$(printf %s "${EXTRA_ENV_B64:-}" | base64 -d 2>/dev/null || true)"

# ① 共享 edge：初始化或幂等 no-op；本项目站点文件就位后热加载
mkdir -p /opt/edge/hosts
cp -f "$STAGE/edge/compose.yaml" "$STAGE/edge/Caddyfile" /opt/edge/
if [ -f "$STAGE/site.caddy" ]; then
  cp -f "$STAGE/site.caddy" "/opt/edge/hosts/${PROJECT}.caddy"
fi
docker compose -f /opt/edge/compose.yaml up -d
for i in 1 2 3 4 5; do
  docker exec edge-caddy caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 && break
  sleep 3
done
docker exec edge-caddy caddy validate --config /etc/caddy/Caddyfile
docker exec edge-caddy caddy reload --config /etc/caddy/Caddyfile

# ② 项目目录与 .env：首次从注入的环境变量全量渲染；此后只更新镜像两行。
#    密码类值永不重写，避免 GitHub Secret 轮换破坏已初始化的数据卷。
mkdir -p "/opt/$PROJECT"
cd "/opt/$PROJECT"
cp -rf "$STAGE/project/." ./
if [ ! -f .env ]; then
  touch .env
  for k in POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD APP_ORIGIN LOG_LEVEL; do
    v=$(eval "printf %s \"\${$k:-}\"")
    [ -n "$v" ] && printf '%s=%s\n' "$k" "$v" >> .env
  done
  if [ -n "$EXTRA_ENV" ]; then
    printf '%s\n' "$EXTRA_ENV" >> .env
  fi
  chmod 600 .env
  echo "[deploy] rendered .env for first deploy"
fi
upsert_env() {
  if grep -q "^$1=" .env; then
    sed -i "s|^$1=.*|$1=$2|" .env
  else
    printf '%s=%s\n' "$1" "$2" >> .env
  fi
}
upsert_env APP_IMAGE "ghcr.io/${OWNER}/${PROJECT}-app:${TAG}"
if [ -n "${MIGRATE_TARGET:-}" ]; then
  upsert_env MIGRATE_IMAGE "ghcr.io/${OWNER}/${PROJECT}-migrate:${TAG}"
fi

# ③ 拉取并起服务（migrate 一次性服务由 compose 依赖保证先跑、成功才起 app）
docker compose pull
docker compose up -d --remove-orphans

# ④ 等 app 容器 healthy（上限约 60s；unhealthy 立即失败并输出日志）
cid=$(docker compose ps -q app)
healthy=""
for i in $(seq 1 30); do
  status=$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo starting)
  if [ "$status" = "healthy" ]; then healthy=1; break; fi
  if [ "$status" = "unhealthy" ]; then break; fi
  sleep 2
done
if [ -z "$healthy" ]; then
  echo "::error::app container not healthy (status=${status:-unknown}); recent logs:"
  docker compose logs --tail 100 app 2>/dev/null || true
  docker compose logs --tail 50 migrate 2>/dev/null || true
  exit 1
fi
echo "[deploy] $PROJECT ${TAG} is healthy"

# ⑤ 只清理本项目前缀的旧镜像（保留 main 与当前 tag，不动同机其他项目）
docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' \
  | awk -v p="ghcr.io/${OWNER}/${PROJECT}-" -v t="${TAG}" \
      'index($1,p)==1 && $1 !~ /:(main)$/ && $1 !~ (":" t "$") {print $2}' \
  | sort -u | xargs -r docker rmi >/dev/null 2>&1 || true

rm -rf /tmp/deploy-stage
echo "[deploy] done"
