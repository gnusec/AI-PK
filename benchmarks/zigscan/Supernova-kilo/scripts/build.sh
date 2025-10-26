#!/bin/bash

# 司马迁端口扫描器编译脚本
# 支持多种编译模式和平台

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 编译目标配置
TARGETS=(
    "x86_64-linux-gnu"
    "aarch64-linux-gnu"
    "x86_64-windows-gnu"
    "x86_64-macos-none"
)

# 优化模式
OPTIMIZATIONS=(
    "Debug"
    "ReleaseSafe"
    "ReleaseFast"
    "ReleaseSmall"
)

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# 显示帮助信息
show_help() {
    cat << EOF
司马迁端口扫描器编译脚本

用法: $0 [选项]

选项:
  -h, --help              显示此帮助信息
  -t, --target <目标>     指定编译目标 (默认: 当前平台)
  -o, --optimize <模式>   指定优化模式 (默认: ReleaseFast)
      --debug             编译调试版本
      --release           编译发布版本
      --static            编译静态链接版本
      --cross <目标>     交叉编译到指定目标
  -v, --verbose           启用详细输出
      --clean             清理构建缓存
      --test              编译后运行测试
      --install           安装到系统

示例:
  $0                      # 编译当前平台的发布版本
  $0 --debug              # 编译调试版本
  $0 --cross x86_64-windows-gnu  # 交叉编译到Windows
  $0 --test               # 编译并运行测试
  $0 --static             # 编译静态链接版本

支持的目标平台:
  x86_64-linux-gnu        Linux x86_64
  aarch64-linux-gnu       Linux ARM64
  x86_64-windows-gnu      Windows x86_64
  x86_64-macos-none       macOS x86_64

优化模式:
  Debug                   调试模式 (默认开启安全检查)
  ReleaseSafe            发布安全模式 (开启优化和安全检查)
  ReleaseFast            发布快速模式 (最大化性能)
  ReleaseSmall           发布小体积模式 (最小化大小)

EOF
}

# 解析命令行参数
TARGET=""
OPTIMIZE="ReleaseFast"
VERBOSE=false
DEBUG=false
RELEASE=false
STATIC=false
CLEAN=false
RUN_TESTS=false
INSTALL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -t|--target)
            TARGET="$2"
            shift 2
            ;;
        -o|--optimize)
            OPTIMIZE="$2"
            shift 2
            ;;
        --debug)
            DEBUG=true
            OPTIMIZE="Debug"
            shift
            ;;
        --release)
            RELEASE=true
            OPTIMIZE="ReleaseFast"
            shift
            ;;
        --static)
            STATIC=true
            shift
            ;;
        --cross)
            TARGET="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        --test)
            RUN_TESTS=true
            shift
            ;;
        --install)
            INSTALL=true
            shift
            ;;
        *)
            log_error "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
done

# 检查依赖
check_dependencies() {
    log_info "检查编译依赖..."

    if ! command -v zig &> /dev/null; then
        log_error "未找到zig编译器，请确保已安装Zig 0.15.1或更高版本"
        exit 1
    fi

    local zig_version=$(zig version)
    log_info "Zig版本: $zig_version"

    # 检查是否为支持的版本
    if [[ "$zig_version" < "0.15.0" ]]; then
        log_warning "建议使用Zig 0.15.0或更高版本，当前版本可能存在兼容性问题"
    fi
}

# 清理构建缓存
clean_build() {
    if [[ "$CLEAN" == "true" ]]; then
        log_info "清理构建缓存..."
        rm -rf zig-out
        rm -rf .zig-cache
        log_success "清理完成"
    fi
}

# 编译项目
build_project() {
    local build_args=()

    # 添加目标平台
    if [[ -n "$TARGET" ]]; then
        build_args+=("-target" "$TARGET")
        log_info "编译目标: $TARGET"
    fi

    # 添加优化模式
    build_args+=("-Doptimize=$OPTIMIZE")
    log_info "优化模式: $OPTIMIZE"

    # 静态链接
    if [[ "$STATIC" == "true" ]]; then
        build_args+=("-static")
        log_info "启用静态链接"
    fi

    # 详细输出
    if [[ "$VERBOSE" == "true" ]]; then
        build_args+=("--verbose")
    fi

    # 执行编译
    log_info "开始编译..."
    local start_time=$(date +%s)

    if timeout 300 zig build "${build_args[@]}"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_success "编译成功，耗时: ${duration}秒"

        # 显示编译产物信息
        if [[ -f "zig-out/bin/simaqian" ]]; then
            local size=$(du -h "zig-out/bin/simaqian" | cut -f1)
            log_info "可执行文件大小: $size"
        fi
    else
        log_error "编译失败"
        exit 1
    fi
}

# 运行测试
run_tests() {
    if [[ "$RUN_TESTS" == "true" ]]; then
        log_info "运行测试套件..."

        if timeout 300 zig build test; then
            log_success "所有测试通过"
        else
            log_error "测试失败"
            exit 1
        fi
    fi
}

# 安装到系统
install_binary() {
    if [[ "$INSTALL" == "true" ]]; then
        log_info "安装到系统..."

        if [[ -f "zig-out/bin/simaqian" ]]; then
            # 安装到系统路径
            if sudo cp "zig-out/bin/simaqian" "/usr/local/bin/"; then
                sudo chmod +x "/usr/local/bin/simaqian"
                log_success "已安装到 /usr/local/bin/simaqian"

                # 创建符号链接
                if [[ ! -f "/usr/local/bin/smq" ]]; then
                    sudo ln -s "/usr/local/bin/simaqian" "/usr/local/bin/smq"
                    log_info "创建快捷命令: smq"
                fi
            else
                log_error "安装失败，请检查权限"
                exit 1
            fi
        else
            log_error "未找到可执行文件"
            exit 1
        fi
    fi
}

# 交叉编译处理
handle_cross_compilation() {
    if [[ -n "$TARGET" ]]; then
        case "$TARGET" in
            *windows*)
                log_info "检测到Windows交叉编译"
                # Windows交叉编译不需要特殊处理
                ;;
            *macos*)
                log_info "检测到macOS交叉编译"
                # macOS交叉编译不需要特殊处理
                ;;
            *linux*)
                log_info "检测到Linux交叉编译"
                # Linux交叉编译不需要特殊处理
                ;;
            *)
                log_warning "未知的编译目标: $TARGET"
                ;;
        esac
    fi
}

# 生成编译报告
generate_build_report() {
    local report_file="build_report_$(date +%Y%m%d_%H%M%S).log"

    {
        echo "========================================"
        echo "司马迁端口扫描器编译报告"
        echo "生成时间: $(date)"
        echo "========================================"
        echo ""

        echo "编译配置:"
        echo "  编译目标: ${TARGET:-当前平台}"
        echo "  优化模式: $OPTIMIZE"
        echo "  静态链接: $STATIC"
        echo "  详细输出: $VERBOSE"
        echo "  运行测试: $RUN_TESTS"
        echo "  安装程序: $INSTALL"
        echo ""

        echo "编译环境:"
        echo "  Zig版本: $(zig version)"
        echo "  系统信息: $(uname -a)"
        echo "  CPU核心数: $(nproc 2>/dev/null || echo '未知')"
        echo ""

        if [[ -f "zig-out/bin/simaqian" ]]; then
            echo "编译产物:"
            echo "  可执行文件: zig-out/bin/simaqian"
            echo "  文件大小: $(du -h "zig-out/bin/simaqian" | cut -f1)"
            echo "  文件权限: $(stat -c '%A' "zig-out/bin/simaqian")"
            echo ""
        fi

        echo "编译完成时间: $(date)"
        echo "========================================"

    } > "$report_file"

    log_success "编译报告已生成: $report_file"
}

# 主编译流程
main() {
    log_info "开始编译流程..."

    check_dependencies
    clean_build
    handle_cross_compilation
    build_project
    run_tests
    install_binary
    generate_build_report

    log_success "编译流程完成！"

    # 显示使用提示
    echo ""
    log_info "使用提示:"
    echo "  查看帮助:     zig-out/bin/simaqian --help"
    echo "  基本使用:     zig-out/bin/simaqian -p '80,443' example.com"
    echo "  范围扫描:     zig-out/bin/simaqian -r '1-1000' example.com"
    echo "  高并发扫描:   zig-out/bin/simaqian -t 1000 example.com"
    echo "  JSON输出:     zig-out/bin/simaqian --format json example.com"

    if [[ "$INSTALL" == "true" ]]; then
        echo "  系统安装:     simaqian --help"
        echo "  快捷命令:     smq --help"
    fi
}

# 运行主函数
main "$@"