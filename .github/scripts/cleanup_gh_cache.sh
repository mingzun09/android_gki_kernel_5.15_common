#!/usr/bin/env bash
# ==============================================================================
#  清理 GitHub Actions 的缓存 / 过期产物
# ==============================================================================
#  用途：Actions 缓存配额是「每个仓库 10GB」，产物与运行日志也占存储。
#        ccache 这类大缓存若每次运行都新建条目，几周就会把配额塞满 —— 既挤掉
#        其它缓存，也白白占用 GitHub 的存储资源。本脚本按「最近访问时间」清理。
#
#  用法（本地，需要已登录的 gh CLI）：
#    ./scripts/cleanup_gh_cache.sh                              # 默认 dry-run，只看会删什么
#    ./scripts/cleanup_gh_cache.sh --apply                      # 真删：清掉 14 天未访问的缓存
#    ./scripts/cleanup_gh_cache.sh --apply --keep-days 7
#    ./scripts/cleanup_gh_cache.sh --apply --purge-caches        # 清掉全部缓存
#    ./scripts/cleanup_gh_cache.sh --apply --artifacts-days 30   # 顺带删过期产物
#    ./scripts/cleanup_gh_cache.sh --apply --no-protect --keep-days 0   # 连受保护的大缓存也清
#    ./scripts/cleanup_gh_cache.sh --repo owner/name --apply
#
#  默认策略：
#    * 受保护 key（`--protect`，默认 Linux-repo-sync-v1）永不自动删除 —— build_gki.yml 的
#      AOSP 源码/prebuilts 缓存本体约 8G，重新 repo sync 代价很高。
#    * ccache 缓存（`--keep-newest-ccache`，默认 3）只按天龄清理，最新的 N 条始终保留。
#
#  GH 环境变量可指定 gh 可执行文件路径（例如 Windows 下 "/c/Program Files/GitHub CLI/gh.exe"）。
# ==============================================================================
set -euo pipefail

GH_BIN="${GH:-gh}"
REPO=""
APPLY=0
KEEP_DAYS=14
ARTIFACTS_DAYS=0
PURGE_CACHES=0
MAX_DELETE=200
# 默认保护 build_gki.yml 存的 AOSP 源码/prebuilts 缓存（本体 ~8G，重建代价高）
PROTECT_KEYS="Linux-repo-sync-v1"
# ccache 缓存只保留最新 N 条，其余按天龄清理
KEEP_NEWEST_CCACHE=3

# 统一封装：路径带空格也不会出错
ghx() { "$GH_BIN" "$@"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)               APPLY=1; shift ;;
    --dry-run)             APPLY=0; shift ;;
    --keep-days)           KEEP_DAYS="$2"; shift 2 ;;
    --artifacts-days)      ARTIFACTS_DAYS="$2"; shift 2 ;;
    --purge-caches)        PURGE_CACHES=1; shift ;;
    --max-delete)          MAX_DELETE="$2"; shift 2 ;;
    --protect)             PROTECT_KEYS="$2"; shift 2 ;;
    --no-protect)          PROTECT_KEYS=""; shift ;;
    --keep-newest-ccache)  KEEP_NEWEST_CCACHE="$2"; shift 2 ;;
    --repo)                REPO="$2"; shift 2 ;;
    -h|--help)        sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$REPO" ]; then
  REPO="$(ghx repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
[ -n "$REPO" ] || { echo "无法确定仓库，请用 --repo owner/name" >&2; exit 1; }

human() { awk -v b="${1:-0}" 'BEGIN{ split("B KB MB GB TB",u," "); i=1; while (b>=1024 && i<5){b/=1024;i++} printf "%.2f %s", b, u[i] }'; }
to_epoch() { date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || echo 0; }
now() { date -u +%s; }

echo "仓库        : $REPO"
echo "模式        : $([ $APPLY -eq 1 ] && echo '真删 (--apply)' || echo 'dry-run（只看不动）')"
echo "缓存策略    : $([ $PURGE_CACHES -eq 1 ] && echo '全清' || echo "保留最近 ${KEEP_DAYS} 天内访问过的")"
echo "保护 key    : ${PROTECT_KEYS:-<无>}"
echo "ccache 轮转 : 保留最新 ${KEEP_NEWEST_CCACHE} 条"
[ "$ARTIFACTS_DAYS" -gt 0 ] && echo "产物策略    : 删除 ${ARTIFACTS_DAYS} 天前（或已过期）的产物"
echo "----------------------------------------------------------------------"

echo "[1/3] 当前用量"
usage_json="$(ghx api "repos/$REPO/actions/cache/usage")"
used="$(printf '%s' "$usage_json" | grep -o '"active_caches_size_in_bytes":[0-9]*' | cut -d: -f2 || true)"
cnt="$(printf '%s' "$usage_json" | grep -o '"active_caches_count":[0-9]*' | cut -d: -f2 || true)"
echo "  缓存条数: ${cnt:-0}   占用: $(human "${used:-0}")   (仓库上限 10GB)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo
echo "[2/3] 缓存"
ghx api --paginate "repos/$REPO/actions/caches?per_page=100" \
  --jq '.actions_caches[] | [.id, .size_in_bytes, .last_accessed_at, .created_at, .key] | @tsv' > "$TMP/caches.tsv" 2>/dev/null || true

# ccache 轮转：按创建时间从新到旧，前 N 条列入「保留」
KEEP_IDS=" "
if [ "$KEEP_NEWEST_CCACHE" -gt 0 ] && [ -s "$TMP/caches.tsv" ]; then
  KEEP_IDS="$(awk -F'\t' 'tolower($5) ~ /ccache/' "$TMP/caches.tsv" | sort -t$'\t' -k4,4r | head -n "$KEEP_NEWEST_CCACHE" | cut -f1 | tr '\n' ' ')"
fi

del_count=0; del_bytes=0; keep_count=0
if [ -s "$TMP/caches.tsv" ]; then
  while IFS=$'\t' read -r id size accessed created key; do
    [ -n "${id:-}" ] || continue
    should_del=0
    why=""
    if [ "$PURGE_CACHES" -eq 1 ]; then
      should_del=1; why="全清模式"
    elif [ -n "${KEEP_IDS# }" ] && [ "${KEEP_IDS#* $id }" != "$KEEP_IDS" ]; then
      keep_count=$((keep_count+1)); echo "  * 保留 $(human "$size")（最新 ccache 配额内）$key"; continue
    elif [ -n "$PROTECT_KEYS" ] && printf '%s' "$PROTECT_KEYS" | tr ',' '\n' | grep -qxF "$key"; then
      keep_count=$((keep_count+1)); echo "  * 保留 $(human "$size")（受保护 key）$key"; continue
    else
      acc="$(to_epoch "$accessed")"; [ "$acc" = "0" ] && acc="$(now)"
      age_days=$(( ($(now) - acc) / 86400 ))
      [ "$age_days" -ge "$KEEP_DAYS" ] && { should_del=1; why="${age_days} 天未访问"; }
    fi
    if [ "$should_del" -eq 1 ]; then
      if [ "$del_count" -ge "$MAX_DELETE" ]; then echo "  [!] 达单次上限 ${MAX_DELETE} 条，剩余下次再删"; break; fi
      printf "  - 删除 %-10s 创建 %-11s 访问 %-11s %s  [%s]\n" "$(human "$size")" "${created%%T*}" "${accessed%%T*}" "$key" "$why"
      [ $APPLY -eq 1 ] && ghx api -X DELETE "repos/$REPO/actions/caches/$id" >/dev/null
      del_count=$((del_count+1)); del_bytes=$((del_bytes+size))
    else
      keep_count=$((keep_count+1))
    fi
  done < "$TMP/caches.tsv"
  echo "  小计: 删除 $del_count 条（$(human "$del_bytes")），保留 $keep_count 条"
else
  echo "  没有缓存"
fi

echo
echo "[3/3] 产物"
if [ "$ARTIFACTS_DAYS" -gt 0 ]; then
  ghx api --paginate "repos/$REPO/actions/artifacts?per_page=100" \
    --jq '.artifacts[] | [.id, .size_in_bytes, .created_at, .expired, .name] | @tsv' > "$TMP/arts.tsv" 2>/dev/null || true
  a_del=0; a_bytes=0
  if [ -s "$TMP/arts.tsv" ]; then
    while IFS=$'\t' read -r id size created expired name; do
      [ -n "${id:-}" ] || continue
      c="$(to_epoch "$created")"; age=$(( ($(now) - c) / 86400 ))
      if [ "$expired" = "true" ] || [ "$age" -ge "$ARTIFACTS_DAYS" ]; then
        printf "  - 删除产物 %-10s %-11s %s\n" "$(human "$size")" "${created%%T*}" "$name"
        [ $APPLY -eq 1 ] && ghx api -X DELETE "repos/$REPO/actions/artifacts/$id" >/dev/null
        a_del=$((a_del+1)); a_bytes=$((a_bytes+size))
      fi
    done < "$TMP/arts.tsv"
    echo "  小计: 删除 $a_del 个产物（$(human "$a_bytes")）"
  else
    echo "  没有产物"
  fi
else
  echo "  跳过（加 --artifacts-days N 才会清理）"
fi

echo "----------------------------------------------------------------------"
if [ $APPLY -eq 1 ]; then echo "完成。"; else echo "以上为 dry-run，加 --apply 才会真正删除。"; fi
