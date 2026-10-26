#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
node_bin='/Users/ahaoxiao/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node'
export PATH="${node_bin:h}:/usr/bin:/bin:/usr/sbin:/sbin"
export N8N_USER_FOLDER="$PWD/runtime-data"
export N8N_LISTEN_ADDRESS=127.0.0.1 N8N_HOST=localhost N8N_PORT=5678 N8N_PROTOCOL=http
export N8N_DIAGNOSTICS_ENABLED=false N8N_PERSONALIZATION_ENABLED=false N8N_VERSION_NOTIFICATIONS_ENABLED=false
export N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
if /usr/bin/curl --max-time 3 --fail --silent http://127.0.0.1:5678/healthz >/dev/null; then
  print '本地 n8n 已在运行：http://localhost:5678'
  exit 0
fi
if [[ ! -x "$node_bin" || ! -f node_modules/n8n/bin/n8n ]]; then
  print '缺少本机运行环境，请按使用说明恢复依赖。'
  exit 1
fi
print '本地 n8n 启动后，浏览器访问 http://localhost:5678。关闭此窗口会停止服务。'
exec "$node_bin" node_modules/n8n/bin/n8n start
