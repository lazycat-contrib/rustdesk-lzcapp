#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 一键发布脚本 — 复制镜像 → 更新版本 → 构建 → 发布 → git 提交推送
# ==============================================================================

usage() {
  cat <<'USAGE'
用法: scripts/release.sh <version> [options]

一键完成: 复制镜像到 LazyCat registry → 更新 package.yml / lzc-manifest.yml
→ 构建 LPK → 发布到应用商店 → git commit & push

选项:
  --service <name>             要更新的 service 名称（多镜像项目必选）
  --source-image <image>       上游镜像完整地址
  --source-template <template> 上游镜像模板，用 {version} 占位，如 ghcr.io/acme/app:{version}
  --changelog <text>           发布 changelog，默认: 更新到 <version>
  --lang <lang>                Changelog 语言，默认: zh
  --no-publish                 跳过发布
  --no-push                    跳过 git push（只 commit）
  --no-commit                  跳过 git 操作
  --dry-run                    仅展示将要执行的操作
  -h, --help                   显示帮助

示例:
  scripts/release.sh 0.2.29
  scripts/release.sh 0.2.29 --no-publish
  scripts/release.sh 0.2.29 --changelog "修复了几个 bug"
  scripts/release.sh 0.2.29 --no-push --dry-run
USAGE
}

# ============================================================================
# 工具函数
# ============================================================================

die()  { echo "❌ error: $*" >&2; exit 1; }
note() { echo "==> $*" >&2; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }

# ============================================================================
# 参数解析
# ============================================================================

VERSION=${1:-}
if [[ -z "$VERSION" || "$VERSION" == "-h" || "$VERSION" == "--help" ]]; then
  usage
  [[ "$VERSION" == "-h" || "$VERSION" == "--help" ]] && exit 0
  exit 1
fi
shift
[[ "$VERSION" != *[[:space:]]* ]] || die "版本号不能包含空格"

PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$PROJECT_DIR"

PACKAGE_FILE="package.yml"
MANIFEST_FILE="lzc-manifest.yml"
BUILD_FILE="lzc-build.yml"
CONFIG_FILE=".lazycat-release.env"

PUBLISH=1
DO_PUSH=1
DO_COMMIT=1
DRY_RUN=0
LANG_CODE="zh"
CHANGELOG=""
SERVICE=""
SOURCE_IMAGE=""
SOURCE_TEMPLATE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)          SERVICE=${2:-}; shift 2 ;;
    --source-image)     SOURCE_IMAGE=${2:-}; shift 2 ;;
    --source-template)  SOURCE_TEMPLATE=${2:-}; shift 2 ;;
    --changelog)        CHANGELOG=${2:-}; shift 2 ;;
    --lang)             LANG_CODE=${2:-}; shift 2 ;;
    --no-publish)       PUBLISH=0; shift ;;
    --no-push)          DO_PUSH=0; shift ;;
    --no-commit)        DO_COMMIT=0; shift ;;
    --dry-run)          DRY_RUN=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) die "未知选项: $1" ;;
  esac
done

CHANGELOG=${CHANGELOG:-"更新到 ${VERSION}"}
need_cmd git
need_cmd awk
need_cmd grep
need_cmd sed

# ============================================================================
# 读取/写入记忆配置
# ============================================================================

load_config() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  while IFS='=' read -r key value || [[ -n "${key:-}" ]]; do
    [[ -z "${key:-}" || "$key" == \#* ]] && continue
    value=$(printf '%s' "${value:-}" | sed 's/[[:space:]]*$//; s/^"//; s/"$//')
    case "$key" in
      service)         [[ -z "${SERVICE:-}" ]]         && SERVICE=$value ;;
      source_template) [[ -z "${SOURCE_TEMPLATE:-}" ]] && SOURCE_TEMPLATE=$value ;;
    esac
  done <"$CONFIG_FILE"
}

write_config() {
  {
    echo "# release.sh 记忆配置"
    [[ -n "${SERVICE:-}" ]]         && printf 'service=%s\n' "$SERVICE"         || true
    [[ -n "${SOURCE_TEMPLATE:-}" ]] && printf 'source_template=%s\n' "$SOURCE_TEMPLATE" || true
  } >"$CONFIG_FILE"
}

load_config

# ============================================================================
# Manifest 解析
# ============================================================================

# 通用的 YAML services 块解析器
# 自动适配 2/4 空格缩进，返回 "service<TAB>image" 每行一个
_awk_parse_services() {
  local mode=${1:-images}   # images | comments
  awk -v mode="$mode" '
    function get_indent(s) {
      match(s, /^[[:space:]]*/)
      return RLENGTH
    }
    /^[[:space:]]*services:[[:space:]]*$/ {
      in_services = 1
      svc_indent = -1
      svc = ""; comment = ""
      next
    }
    in_services && /^[^[:space:]]/ {
      in_services = 0; svc = ""; comment = ""
    }
    in_services && svc_indent < 0 && /^[[:space:]]+[A-Za-z0-9_.-]+:/ {
      svc_indent = get_indent($0)
    }
    in_services && /^[[:space:]]+[A-Za-z0-9_.-]+:[[:space:]]*$/ {
      if (get_indent($0) == svc_indent) {
        svc = $1; sub(/:$/,"",svc); comment = ""
      }
      next
    }
    in_services && svc != "" && /^[[:space:]]+# / && mode == "comments" {
      comment = $0; sub(/^[[:space:]]*#[[:space:]]*/,"",comment); gsub(/[[:space:]]*$/,"",comment)
      next
    }
    in_services && svc != "" && /^[[:space:]]+image:[[:space:]]*/ {
      img = $0; sub(/^[[:space:]]*image:[[:space:]]*/,"",img)
      gsub(/^["\047]|["\047]$/,"",img)
      if (mode == "comments") {
        if (comment != "" && comment ~ /^[a-zA-Z0-9].*:[a-zA-Z0-9]/) print svc "\t" comment
        comment = ""
      } else {
        print svc "\t" img
      }
    }
  ' "$MANIFEST_FILE"
}

list_manifest_images()   { _awk_parse_services images; }
list_manifest_comments() { _awk_parse_services comments; }

find_service_image()   { list_manifest_images   | awk -F'\t' -v t="$1" '$1==t{print $2; exit}'; }
find_service_comment() { list_manifest_comments | awk -F'\t' -v t="$1" '$1==t{print $2; exit}'; }

# ============================================================================
# 选择要更新的 service
# ============================================================================

select_service() {
  mapfile -t ENTRIES < <(list_manifest_images)
  [[ ${#ENTRIES[@]} -gt 0 ]] || die "$MANIFEST_FILE 中没有找到 services.*.image"

  # 如果已指定 SERVICE，验证它存在
  if [[ -n "${SERVICE:-}" ]]; then
    CURRENT_IMAGE=$(find_service_image "$SERVICE") || {
      echo "可用的 service 镜像:" >&2
      for e in "${ENTRIES[@]}"; do printf '  - %s\n' "$e" >&2; done
      die "service '$SERVICE' 在 $MANIFEST_FILE 中没有 image"
    }
    if [[ ${#ENTRIES[@]} -gt 1 ]]; then
      note "更新多镜像项目中的 service '$SERVICE'"
    fi
    return 0
  fi

  # 单镜像：自动选择
  if [[ ${#ENTRIES[@]} -eq 1 ]]; then
    SERVICE=${ENTRIES[0]%%$'\t'*}
    CURRENT_IMAGE=${ENTRIES[0]#*$'\t'}
    note "单镜像项目，自动选择 service '$SERVICE'"
    return 0
  fi

  # 多镜像且未指定 service
  echo "此 manifest 有多个镜像，请用 --service 指定:" >&2
  for e in "${ENTRIES[@]}"; do printf '  - %s\n' "$e" >&2; done
  die "请用 --service <name> 指定要更新的 service"
}

# ============================================================================
# 推导上游镜像
# ============================================================================

resolve_source_image() {
  if [[ -n "${SOURCE_IMAGE:-}" ]]; then
    note "使用指定的上游镜像: $SOURCE_IMAGE"
    return 0
  fi

  if [[ -n "${SOURCE_TEMPLATE:-}" ]]; then
    local img="${SOURCE_TEMPLATE//\{version\}/$VERSION}"
    img="${img//\{\{version\}\}/$VERSION}"
    SOURCE_IMAGE="$img"
    note "从模板推导上游镜像: $SOURCE_IMAGE"
    return 0
  fi

  # 尝试从注释推导
  local comment_img
  comment_img=$(find_service_comment "$SERVICE")
  if [[ -n "$comment_img" ]]; then
    local img_name tag_prefix resolved_version
    if [[ "$comment_img" == *:* ]]; then
      img_name="${comment_img%:*}"
      # 保留原始 tag 的版本前缀（如 v0.2.28 中的 v）
      tag_prefix=$(printf '%s' "${comment_img##*:}" | sed -E 's/[0-9].*//')
    else
      img_name="$comment_img"
      tag_prefix=""
    fi
    resolved_version="$VERSION"
    # 如果用户版本不带前缀而原始 tag 有，自动补上
    [[ -n "$tag_prefix" && "$resolved_version" != "$tag_prefix"* ]] && resolved_version="$tag_prefix$resolved_version"
    SOURCE_IMAGE="${img_name}:${resolved_version}"
    note "从 manifest 注释推导上游镜像: $comment_img → $SOURCE_IMAGE"
    return 0
  fi

  # 从当前镜像推导
  if [[ "$CURRENT_IMAGE" == registry.lazycat.cloud/* ]]; then
    die "当前镜像已是 LazyCat registry 地址，请用 --source-image 或 --source-template 指定上游镜像"
  fi
  if [[ "${CURRENT_IMAGE##*/}" == *:* ]]; then
    SOURCE_IMAGE="${CURRENT_IMAGE%:*}:$VERSION"
  else
    SOURCE_IMAGE="$CURRENT_IMAGE:$VERSION"
  fi
  note "从当前镜像推导上游镜像: $SOURCE_IMAGE"
}

# ============================================================================
# 复制镜像
# ============================================================================

copy_image() {
  local src=$1 output

  note "复制镜像: $src"

  # 优先使用 fish 函数
  if command -v fish >/dev/null 2>&1 && fish -lc 'functions -q lzc-copy-image' 2>/dev/null; then
    output=$(fish -lc "lzc-copy-image '$src'" 2>&1) || {
      echo "$output" >&2
      die "镜像复制失败"
    }
  else
    need_cmd lzc-cli
    output=$(lzc-cli appstore copy-image "$src" 2>&1) || {
      echo "$output" >&2
      die "镜像复制失败"
    }
  fi

  # 从输出中解析 LazyCat registry 地址
  local registry_img
  registry_img=$(echo "$output" | grep -Eo 'registry\.lazycat\.cloud/[A-Za-z0-9._:@/-]+' | tail -n 1)
  [[ -n "$registry_img" ]] || {
    echo "$output" >&2
    die "无法从 copy-image 输出中解析 registry.lazycat.cloud 镜像地址"
  }
  echo "$registry_img"
}

# ============================================================================
# 更新文件
# ============================================================================

update_package_version() {
  local tmp
  tmp=$(mktemp)
  awk -v ver="$VERSION" '
    BEGIN { updated=0 }
    !updated && /^version:[[:space:]]*/ { print "version: " ver; updated=1; next }
    { print }
    END { if (!updated) { print "package.yml 中未找到 version 字段" > "/dev/stderr"; exit 1 } }
  ' "$PACKAGE_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$PACKAGE_FILE"
  note "已更新 $PACKAGE_FILE → version: $VERSION"
}

update_manifest_image() {
  local tmp
  tmp=$(mktemp)
  awk -v svc="$SERVICE" -v img="$LAZYCAT_IMAGE" '
    function get_indent(s) {
      match(s, /^[[:space:]]*/)
      return RLENGTH
    }
    BEGIN { in_services=0; in_target=0; svc_indent=-1; updated=0 }
    /^[[:space:]]*services:[[:space:]]*$/  { in_services=1; svc_indent=-1; print; next }
    in_services && /^[^[:space:]]/ { in_services=0; in_target=0 }
    in_services && svc_indent<0 && /^[[:space:]]+[A-Za-z0-9_.-]+:/ { svc_indent=get_indent($0) }
    in_services && /^[[:space:]]+[A-Za-z0-9_.-]+:[[:space:]]*$/ {
      if (get_indent($0) == svc_indent) {
        cur=$1; sub(/:$/,"",cur); in_target=(cur==svc)
      }
    }
    in_target && /^[[:space:]]+image:[[:space:]]*/ {
      # 保留原始缩进
      match($0, /^[[:space:]]*/)
      printf "%*simage: %s\n", RLENGTH, "", img
      updated=1; next
    }
    { print }
    END { if (!updated) { print "未能更新 service 镜像" > "/dev/stderr"; exit 1 } }
  ' "$MANIFEST_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$MANIFEST_FILE"
  note "已更新 $MANIFEST_FILE → $SERVICE image: $LAZYCAT_IMAGE"
}

# ============================================================================
# 构建
# ============================================================================

package_id() {
  awk -F':[[:space:]]*' '/^package:/ { gsub(/["\047 ]/, "", $2); print $2; exit }' "$PACKAGE_FILE"
}

build_lpk() {
  need_cmd lzc-cli
  note "构建 LPK..."
  lzc-cli project build -f "$BUILD_FILE"
  [[ -f "$LPK_FILE" ]] || die "构建产物未找到: $LPK_FILE"
  note "构建完成: $LPK_FILE"
}

# ============================================================================
# 发布
# ============================================================================

publish_lpk() {
  [[ "$PUBLISH" == "1" ]] || return 0
  [[ -f "$LPK_FILE" ]] || die "LPK 文件不存在: $LPK_FILE"

  note "发布到应用商店..."

  if command -v fish >/dev/null 2>&1 && fish -lc 'functions -q lzc-publish' 2>/dev/null; then
    fish -lc "lzc-publish '$LPK_FILE' '$CHANGELOG' '$LANG_CODE'" || die "发布失败"
  else
    need_cmd lzc-cli
    lzc-cli appstore publish "$LPK_FILE" -c "$CHANGELOG" --clang "$LANG_CODE" || die "发布失败"
  fi
  note "发布完成"
}

# ============================================================================
# Git 操作
# ============================================================================

git_commit_push() {
  [[ "$DO_COMMIT" == "1" ]] || return 0

  note "Git 提交..."

  git add "$PACKAGE_FILE" "$MANIFEST_FILE"

  if [[ -f "$LPK_FILE" ]]; then
    git add "$LPK_FILE"
  fi

  [[ -f "$CONFIG_FILE" ]] && git add "$CONFIG_FILE"

  # 检查是否有变更
  if git diff --cached --quiet; then
    note "没有需要提交的变更"
    return 0
  fi

  local msg="bump $VERSION"
  git commit -m "$msg"
  note "已提交: $msg"

  if [[ "$DO_PUSH" == "1" ]]; then
    note "推送到 origin main..."
    git push origin main
    note "推送完成"
  else
    note "跳过 git push (--no-push)"
  fi
}

# ============================================================================
# 主流程
# ============================================================================

main() {
  note "=============================================="
  note "一键发布 v$VERSION"
  note "=============================================="

  select_service
  resolve_source_image

  note ""
  note "版本:     $VERSION"
  note "Service:  $SERVICE"
  note "源镜像:   $SOURCE_IMAGE"
  note "Changelog: $CHANGELOG"
  note "发布:     $([[ "$PUBLISH" == "1" ]] && echo '是' || echo '否')"
  note "Git 提交: $([[ "$DO_COMMIT" == "1" ]] && echo '是' || echo '否')"
  note "Git Push: $([[ "$DO_PUSH" == "1" ]] && echo '是' || echo '否')"
  note ""

  if [[ "$DRY_RUN" == "1" ]]; then
    note "=== DRY RUN 结束（未执行任何操作）==="
    return 0
  fi

  # 1. 复制镜像
  LAZYCAT_IMAGE=$(copy_image "$SOURCE_IMAGE")
  note "LazyCat 镜像: $LAZYCAT_IMAGE"

  # 2. 更新文件
  update_package_version
  update_manifest_image

  # 3. 保存配置
  write_config

  # 4. 确定 LPK 文件名
  PACKAGE_ID=$(package_id)
  LPK_FILE="${PACKAGE_ID}-v${VERSION}.lpk"

  # 5. 构建
  build_lpk

  # 6. 发布
  publish_lpk

  # 7. Git 提交推送
  git_commit_push

  note ""
  note "=============================================="
  note "✅ 发布完成!"
  note "   version:  $VERSION"
  note "   service:  $SERVICE"
  note "   image:    $LAZYCAT_IMAGE"
  note "   lpk:      $LPK_FILE"
  note "   publish:  $([[ "$PUBLISH" == "1" ]] && echo '已发布' || echo '跳过')"
  note "=============================================="
}

main
