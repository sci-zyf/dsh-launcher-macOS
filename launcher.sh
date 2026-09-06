#!/bin/bash
# DSH Launcher 核心逻辑 —— 自足脚本,不依赖交互 shell 的 PATH/nvm 注入。
# .app 双击是非交互环境,zsh 不读 .zshrc,必须在此显式前置 nvm node 目录,
# 否则 dsh(shebang 为 #!/usr/bin/env node)会找不到 node 而崩溃。

# 自动定位装有 dsh CLI 的 node 版本目录:遍历 ~/.nvm/versions/node 下全部已装版本,
# 从高到低取第一个含 dsh 命令的 bin 目录。找不到时回退写死的默认版本。
detect_node_dir() {
  local d
  for d in $(ls -d "$HOME/.nvm/versions/node/"*/ 2>/dev/null | sort -V -r); do
    if [ -x "${d}bin/dsh" ]; then
      echo "${d}bin"
      return 0
    fi
  done
  return 1
}

NODE_DIR="$(detect_node_dir)"
[ -n "$NODE_DIR" ] || NODE_DIR="$HOME/.nvm/versions/node/v24.16.0/bin"

export PATH="$NODE_DIR:$PATH"
DSH="$NODE_DIR/dsh"
PKG="@deepseek-ai/dsh"
LOG="$HOME/.dsh/launcher.log"
PORT=3080

# ---------- 进程检测 ----------

# dsh web 进程匹配:精确匹配 "dsh web" 命令行,排除 cc-connect、其他 node。
dsh_pids() {
  pgrep -f "bin/dsh web" 2>/dev/null
}

is_running() {
  [ -n "$(dsh_pids)" ]
}

# 端口是否被"我们的 dsh 进程"监听(排除微信等其它进程占端口)
port_listening() {
  local lp pids
  lp="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1)"
  [ -z "$lp" ] && return 1
  pids="$(dsh_pids)"
  [ -n "$pids" ] && echo "$pids" | grep -qx "$lp"
}

# ---------- 命令实现 ----------

cmd_status() {
  local ver running pid
  ver="$("$DSH" --version 2>/dev/null)"
  if is_running; then
    pid="$(dsh_pids | head -1)"
    echo "状态: DSH 正在运行"
    echo "版本: $ver"
    echo "PID: $pid"
    echo "端口: $PORT"
    echo "网址: http://127.0.0.1:$PORT"
  else
    echo "状态: DSH 未运行"
    echo "版本: $ver"
  fi
}

cmd_dist_tags() {
  # 输出:当前已装版本 + 每个轨道一行。供 UI 动态选轨,不写死。
  local cur tags_json
  cur="$("$DSH" --version 2>/dev/null)"
  echo "当前: $cur"
  tags_json="$(npm view "$PKG" dist-tags --json 2>/dev/null)"
  if [ -z "$tags_json" ] || [ "$tags_json" = "{}" ]; then
    echo "! 无法获取 dist-tags(可能离线)"
    return 1
  fi
  # dist-tags JSON 形如 {"latest":"0.1.1-rc.2","next":"0.1.2-rc.1",...}
  echo "$tags_json" \
    | sed 's/[{}",]//g; s/: */ /g' \
    | awk -v cur="$cur" 'NF==2 {
        mark = ($2 == cur) ? "  ← 当前" : ""
        printf "%s %s%s\n", $1, $2, mark
      }'
}

cmd_update() {
  # 跨轨移动:把本地唯一副本装成目标轨道解析出的版本。
  local tag="$1" old new
  [ -z "$tag" ] && { echo "用法: update <tag>"; return 2; }
  old="$("$DSH" --version 2>/dev/null)"
  echo "更新前: $old"
  echo "目标轨道: $tag"
  if ! npm install -g "$PKG@$tag" >>"$LOG" 2>&1; then
    echo "! 更新失败,见 $LOG"
    return 1
  fi
  new="$("$DSH" --version 2>/dev/null)"
  echo "更新后: $new"
}

# 从本次新增日志分析启动失败原因。参数为新增日志起点行号,输出契约:
#   "问题插件: <包名>"   每行一个(可多行),识别不出时为空
#   "故障原因: <文本>"
fail_analysis() {
  local mark="$1" seg pkgs reason
  seg="$(tail -n +$((mark + 1)) "$LOG" 2>/dev/null)"
  pkgs=""; reason=""
  if [ -n "$seg" ]; then
    # 形态一:loader entry <loader> (<scope包名>): 报错 —— 取全部匹配
    pkgs="$(printf '%s\n' "$seg" \
      | grep -oE '\(@[^)]*\)' \
      | sed -E 's/[()]//g' \
      | sort -u)"
    # 形态二:did not activate 下的 "<包名>: pending (waiting for service: …)" —— 取全部
    if [ -z "$pkgs" ]; then
      pkgs="$(printf '%s\n' "$seg" \
        | grep -E '^[[:space:]]*@?[A-Za-z0-9][^ :]*: pending' \
        | sed -E 's/^[[:space:]]*//; s/: pending.*//' \
        | sort -u)"
    fi
    reason="$(printf '%s\n' "$seg" \
      | grep -m1 -E 'Error:|failed to apply loader|did not activate|pending \(waiting' \
      | sed -E 's/^[[:space:]]+//' \
      | head -c 400)"
  fi
  if [ -n "$pkgs" ]; then
    printf '%s\n' "$pkgs" | sed 's/^/问题插件: /'
  else
    printf '问题插件: \n'
  fi
  printf '故障原因: %s\n' "$reason"
}

cmd_start() {
  if is_running && port_listening; then
    echo "! DSH 已在运行 (PID: $(dsh_pids | head -1))"
    return 1
  fi
  # 后台启动并脱离终端;dsh 启动后父进程退出,进程被 launchd 收养为孤儿。
  # dsh 的 HTTP server 先监听、插件随后异步加载——崩溃常发生在监听之后的加载阶段,
  # 且崩溃日志是异步写盘、可能迟到。所以判据不能依赖日志时序:
  # 启动后等端口监听,再等加载期(~8 秒),最终以"进程仍存活"为成功唯一判据;
  # 判失败后再读日志(此时已 flush)定位原因。
  local mark i j survived
  mark="$(wc -l <"$LOG" 2>/dev/null || echo 0)"
  nohup "$DSH" web --no-open >>"$LOG" 2>&1 &
  # 阶段一:等端口监听(最长 ~10 秒)
  for i in $(seq 1 20); do
    if port_listening; then
      # 阶段二:监听后继续观察,进程持续存活才算成功(~8 秒加载期)
      survived=0
      for j in $(seq 1 16); do
        sleep 0.5
        if is_running && port_listening; then
          survived="$j"
        else
          break
        fi
      done
      if [ "$survived" -eq 16 ]; then
        # 已稳定存活过加载期,进程仍活着才算成功(再确认一次)
        if is_running && port_listening; then
          echo "启动成功 (PID: $(dsh_pids | head -1))"
          return 0
        fi
      fi
      break
    fi
    sleep 0.5
  done
  # 启动失败。崩溃日志是异步写盘的:先等日志停止增长(进程退出后最多 1 秒),
  # 再分析本次新增日志给出原因,避免读到未写完的部分。
  local detail seg_before seg_after i2
  for i2 in $(seq 1 4); do
    seg_before="$(tail -c 200 "$LOG" 2>/dev/null)"
    sleep 0.25
    seg_after="$(tail -c 200 "$LOG" 2>/dev/null)"
    [ "$seg_before" = "$seg_after" ] && break
  done
  detail="$(fail_analysis "$mark")"
  printf '%s\n' "$detail"
  echo "! 启动失败,见 $LOG"
  return 1
}

cmd_stop() {
  if ! is_running; then
    echo "! DSH 未运行"
    return 1
  fi
  # 只杀 dsh web 进程,不误伤 cc-connect 等其他 node。
  pkill -f "bin/dsh web"
  local i
  for i in $(seq 1 10); do
    if ! is_running; then
      echo "已关闭"
      return 0
    fi
    sleep 0.3
  done
  echo "! 正常退出超时,强制结束"
  pkill -9 -f "bin/dsh web"
  sleep 0.3
  is_running && { echo "! 仍有关闭失败"; return 1; }
  echo "已强制关闭"
}

cmd_restart() {
  cmd_stop
  echo "---"
  cmd_start
}

# ---------- 禁用插件 ----------
# 走 market 语义的禁用:保留 package.json 依赖(已装),关掉加载(未启用)。
# dsh 运行时优先调 market 的 /dsh-market/toggle(写 state.json + cordis.patch.yml);
# dsh 未运行(启动失败场景)时兜底直接写这两处,效果一致。核心 bundle 列为保护名单。

# 启动时禁用的核心 bundle 名单 —— 动它们会导致 dsh 无法启动。
CORE_BUNDLES="
@deepseek-ai/dsh-base
@deepseek-ai/dsh-web-app
"

MARKET_DIR="$HOME/.dsh/profiles/web/.dsh-market"
PATCH_FILE="$HOME/.dsh/profiles/web/cordis.patch.yml"

# 由包名推导 loader row id(market 内部规则:@scope/name 或 name 的包名部分,
# 形如 @anionex/dsh-turn-rewind -> turn-rewind,@ch4acko3/dsh-turn-fold -> ch4acko3-dsh-turn-fold)
pkg_to_rowid() {
  local pkg="$1" base
  case "$pkg" in
    @*/*)
      base="${pkg#@}"
      base="${base#*/}"   # 去掉 scope 名
      echo "$base"
      ;;
    *) echo "$pkg" ;;
  esac
}

# 尝试调 market toggle API 禁用(需要 dsh 正在运行)
api_disable() {
  local pkg="$1" out
  out="$(curl -s -m 5 -X POST "http://127.0.0.1:$PORT/dsh-market/toggle" \
    -H "Content-Type: application/json" \
    -H "Origin: http://127.0.0.1:$PORT" \
    -d "{\"name\":\"$pkg\",\"enabled\":false}" 2>/dev/null)"
  case "$out" in
    *'"ok":true'*) return 0 ;;
    *) return 1 ;;
  esac
}

# 文件兜底禁用:state.json disabled 加名 + cordis.patch.yml 写 disabled 行 + 从 bundles 移除
file_disable() {
  local pkg="$1" f b suffix profile
  profile="$HOME/.dsh/profiles/web"
  f="$profile/package.json"
  # 从 dsh.profile.bundles 移除(保留 dependencies)
  if grep -q "\"$pkg\"" "$f"; then
    suffix="$(date +%Y%m%d-%H%M%S)"
    cp "$f" "$f.bak-$suffix"
    ls -t "$profile"/package.json.bak-* 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null
    if ! "$NODE_DIR/node" -e '
        const fs = require("fs");
        const f = process.argv[1];
        const pkg = process.argv[2];
        const doc = JSON.parse(fs.readFileSync(f, "utf8"));
        const bundles = doc.dsh && doc.dsh.profile && doc.dsh.profile.bundles;
        if (Array.isArray(bundles)) {
          const i = bundles.indexOf(pkg);
          if (i !== -1) bundles.splice(i, 1);
        }
        fs.writeFileSync(f, JSON.stringify(doc, null, 2) + "\n");
      ' "$f" "$pkg"; then
      echo "! 改写 package.json 失败(已备份在 $f.bak-$suffix)"
      return 1
    fi
  fi
  # state.json disabled 加名(若 market 状态文件存在)
  if [ -f "$MARKET_DIR/state.json" ]; then
    if ! "$NODE_DIR/node" -e '
        const fs = require("fs");
        const f = process.argv[1];
        const pkg = process.argv[2];
        const doc = JSON.parse(fs.readFileSync(f, "utf8"));
        const set = new Set(Array.isArray(doc.disabled) ? doc.disabled : []);
        set.add(pkg);
        doc.disabled = [...set];
        fs.writeFileSync(f, JSON.stringify(doc, null, 2) + "\n");
      ' "$MARKET_DIR/state.json" "$pkg"; then
      echo "! 写入 market 状态失败"
      return 1
    fi
  fi
  # cordis.patch.yml 写 "- id: <rowid>\n  disabled: true"(若文件存在)
  if [ -f "$PATCH_FILE" ]; then
    local rowid
    rowid="$(pkg_to_rowid "$pkg")"
    if ! grep -q "^  disabled: true\$" "$PATCH_FILE" || ! grep -q -- "- id: $rowid" "$PATCH_FILE"; then
      cp "$PATCH_FILE" "$PATCH_FILE.bak-$suffix" 2>/dev/null
      printf -- '- id: %s\n  disabled: true\n' "$rowid" >> "$PATCH_FILE"
    fi
  fi
  return 0
}

cmd_disable_plugin() {
  local pkg="$1" b
  [ -z "$pkg" ] && { echo "用法: disable-plugin <包名>"; return 2; }
  # 校验包名形态(必含 scope,形如 @scope/name)
  case "$pkg" in
    @*/*) ;;
    *) echo "! 插件名需为 @scope/name 形态: $pkg"; return 1;;
  esac
  # 保护名单:不允许禁用核心 bundle
  for b in $CORE_BUNDLES; do
    [ "$pkg" = "$b" ] && { echo "! 拒绝禁用核心 bundle: $pkg"; return 1; }
  done
  # 是否已安装(依赖里)
  grep -q "\"$pkg\"" "$HOME/.dsh/profiles/web/package.json" || { echo "! profile 中未声明插件 $pkg(无需禁用)"; return 1; }
  # 优先 market API(需 dsh 运行)
  if is_running && port_listening; then
    if api_disable "$pkg"; then
      echo "已通过市场禁用: $pkg"
      echo "! 重启后保持关闭;如需启用请在 DSH 市场里打开。"
      return 0
    fi
    echo "! 市场 API 禁用失败,改用本地文件禁用…"
  fi
  if file_disable "$pkg"; then
    echo "已禁用(本地文件): $pkg"
    echo "备份: $HOME/.dsh/profiles/web/package.json.bak-*"
    echo "! 重启后保持关闭;如需彻底卸载请在 DSH 市场里删除。"
    return 0
  fi
  return 1
}

# ---------- 分发 ----------

cmd="${1:-help}"
shift 2>/dev/null || true

case "$cmd" in
  status)    cmd_status ;;
  dist-tags) cmd_dist_tags ;;
  update)    cmd_update "$@" ;;
  start)     cmd_start ;;
  stop)      cmd_stop ;;
  restart)   cmd_restart ;;
  disable-plugin) cmd_disable_plugin "$1" ;;
  help|--help|-h)
    echo "DSH Launcher 用法:"
    echo "  launcher.sh status       查看状态/版本/PID"
    echo "  launcher.sh dist-tags    列出可用版本轨道"
    echo "  launcher.sh update <tag> 更新到指定轨道(跨轨)"
    echo "  launcher.sh start        启动 DSH(后台)"
    echo "  launcher.sh stop         关闭 DSH"
    echo "  launcher.sh restart      重启 DSH"
    echo "  launcher.sh disable-plugin <包名>  从启动清单禁用第三方插件(不重装)"
    ;;
  *) echo "未知命令: $cmd (用 help 查看)" >&2; exit 2 ;;
esac
