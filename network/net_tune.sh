#!/usr/bin/env bash
set -euo pipefail

archive_url=https://codeload.github.com/yhj945/tools/zip/refs/heads/main
modules=(net_tune.py net_tune_auto.py net_tune_bench.py net_tune_changes.py net_tune_system.py)

fail() {
    printf '错误 %s\n' "$*" >&2
    exit 1
}

find_python() {
    local candidate
    for candidate in python3 python3.{14,13,12,11,10,9,8}; do
        if "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 8))' 2>/dev/null; then
            printf '%s\n' "$candidate"
            return
        fi
    done
    return 1
}

complete_source() {
    local module
    for module in "${modules[@]}"; do
        [[ -f "$1/$module" ]] || return 1
    done
}

find_missing() {
    missing=()
    find_python >/dev/null || missing+=(python3)
    ip -j -V >/dev/null 2>&1 || missing+=(ip)
    tc -j -V >/dev/null 2>&1 || missing+=(tc)
    local tool
    for tool in ss iperf3 ping stdbuf; do
        command -v "$tool" >/dev/null || missing+=("$tool")
    done
    if [[ -z $source_dir ]] && ! command -v curl >/dev/null; then
        missing+=(curl)
    fi
}

install_dependencies() {
    find_missing
    (( ${#missing[@]} > 0 )) || return 0

    local manager package tool
    for manager in apt-get dnf yum pacman zypper apk; do
        if command -v "$manager" >/dev/null; then
            break
        fi
    done
    command -v "$manager" >/dev/null || fail "未找到支持的包管理器，请安装 ${missing[*]}"

    local packages=() as_root=()
    if (( EUID != 0 )); then
        command -v sudo >/dev/null || fail "安装依赖需要 root 或 sudo"
        as_root=(sudo --)
    fi

    for tool in "${missing[@]}"; do
        case "$manager:$tool" in
            pacman:python3) package=python ;;
            dnf:python3|yum:python3)
                package=python3
                if [[ -r /etc/os-release ]] && ( . /etc/os-release; [[ ${PLATFORM_ID:-} == platform:el8 ]] ); then
                    package=python3.11
                fi
                ;;
            dnf:ip|dnf:ss|yum:ip|yum:ss) package=iproute ;;
            dnf:tc|yum:tc) package=iproute-tc ;;
            apk:tc) package=iproute2-tc ;;
            apk:ss) package=iproute2-ss ;;
            *:ip|*:tc|*:ss) package=iproute2 ;;
            zypper:iperf3) package=iperf ;;
            apt-get:ping) package=iputils-ping ;;
            *:ping) package=iputils ;;
            *:stdbuf) package=coreutils ;;
            *) package=$tool ;;
        esac
        if [[ " ${packages[*]} " != *" $package "* ]]; then
            packages+=("$package")
        fi
    done

    printf '安装缺失的依赖（%s） %s\n' "$manager" "${packages[*]}" >&2
    local install_args=()
    case "$manager" in
        apt-get)
            "${as_root[@]}" apt-get update >&2 || fail "软件包索引刷新失败"
            as_root+=(env DEBIAN_FRONTEND=noninteractive)
            install_args=(install -y --no-install-recommends)
            ;;
        dnf|yum) install_args=(install -y) ;;
        pacman) install_args=(-S --needed --noconfirm) ;;
        zypper) install_args=(--non-interactive install --no-recommends) ;;
        apk) install_args=(add --no-cache) ;;
    esac
    "${as_root[@]}" "$manager" "${install_args[@]}" "${packages[@]}" >&2 || fail "依赖安装失败，请检查包仓库和权限"

    hash -r
    find_missing
    (( ${#missing[@]} == 0 )) || fail "以下依赖仍不可用：${missing[*]}。Python 需要 3.8 或更新版本"
}

[[ $(uname -s) == Linux ]] || fail "此工具需要 Linux"
export PATH="$PATH:/usr/sbin:/sbin"

source_dir=
if [[ -f ${BASH_SOURCE[0]:-} ]]; then
    source_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    if ! complete_source "$source_dir"; then
        source_dir=
    fi
fi

if [[ ${1:-} == --install-deps ]]; then
    shift
    install_dependencies
fi

python=$(find_python) || fail "需要 Python 3.8 或更新版本。可将 --install-deps 加在子命令前自动安装依赖"
if [[ -n $source_dir ]]; then
    exec "$python" "$source_dir/net_tune.py" "$@"
fi

command -v curl >/dev/null || fail "远程下载需要 curl，可使用 --install-deps 安装"
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 --output "$temporary/tools.zip" "$archive_url" ||
    fail "下载项目文件失败，请检查 GitHub 连接"

# Read only the required files from one snapshot. Use the same process for
# Python so signals and exit codes reach the tuning command directly.
exec "$python" -I -B -c '
import runpy
import shutil
import sys
from pathlib import Path
from zipfile import BadZipFile, ZipFile

directory = Path(sys.argv.pop(1))
modules = sys.argv.pop(1).split()
try:
    try:
        with ZipFile(directory / "tools.zip") as archive:
            for module in modules:
                (directory / module).write_bytes(archive.read("tools-main/network/" + module))
    except (BadZipFile, KeyError, OSError) as exc:
        sys.exit(f"错误 无法加载远程脚本文件：{exc}")
    sys.path.insert(0, str(directory))
    sys.argv[0] = str(directory / "net_tune.py")
    runpy.run_path(sys.argv[0], run_name="__main__")
finally:
    shutil.rmtree(directory, ignore_errors=True)
' "$temporary" "${modules[*]}" "$@"
