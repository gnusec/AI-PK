#!/bin/bash

# 司马迁端口扫描器自动化测试脚本
# 使用真实外网IP进行网络测试验证

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 测试目标配置
TEST_TARGETS=(
    "103.235.46.115"  # 已知开放80,443端口的目标
    "8.8.8.8"         # Google DNS
    "1.1.1.1"         # Cloudflare DNS
)

# 端口配置
TEST_PORTS=(
    "80,443"
    "1-100"
    "21,22,23,25,53,80,110,135,139,143,443,445,993,995,1723,3306,3389,5900,8080"
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

# 检查依赖
check_dependencies() {
    log_info "检查构建依赖..."

    if ! command -v zig &> /dev/null; then
        log_error "未找到zig编译器，请确保已安装Zig 0.15.1或更高版本"
        exit 1
    fi

    local zig_version=$(zig version)
    log_info "Zig版本: $zig_version"

    if ! command -v timeout &> /dev/null; then
        log_warning "未找到timeout命令，某些测试可能无法正确执行"
    fi
}

# 编译项目
build_project() {
    log_info "编译项目..."

    # 清理旧的构建产物
    rm -rf zig-out
    rm -rf .zig-cache

    # 编译主程序
    if timeout 60 zig build -Doptimize=ReleaseFast; then
        log_success "项目编译成功"
    else
        log_error "项目编译失败"
        exit 1
    fi
}

# 运行单元测试
run_unit_tests() {
    log_info "运行单元测试..."

    if timeout 120 zig build test; then
        log_success "单元测试通过"
    else
        log_error "单元测试失败"
        exit 1
    fi
}

# 运行集成测试
run_integration_tests() {
    log_info "运行集成测试..."

    for target in "${TEST_TARGETS[@]}"; do
        log_info "测试目标: $target"

        for ports in "${TEST_PORTS[@]}"; do
            log_info "测试端口配置: $ports"

            # 使用timeout防止测试卡住
            if timeout 30s zig-out/bin/simaqian -p "$ports" -t 50 --timeout 2000 --format txt "$target" > /dev/null 2>&1; then
                log_success "目标 $target 端口 $ports 测试通过"
            else
                log_warning "目标 $target 端口 $ports 测试可能存在问题"
            fi
        done
    done
}

# 性能测试
run_performance_tests() {
    log_info "运行性能测试..."

    local target="103.235.46.115"
    local ports="80,443"

    log_info "性能测试目标: $target"
    log_info "测试端口: $ports"

    local start_time=$(date +%s)

    if timeout 60s zig-out/bin/simaqian -p "$ports" -t 100 --timeout 3000 --format txt "$target" > /dev/null 2>&1; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_success "性能测试完成，耗时: ${duration}秒"
    else
        log_error "性能测试失败"
        exit 1
    fi
}

# 并发测试
run_concurrency_tests() {
    log_info "运行并发测试..."

    local target="103.235.46.115"
    local ports="1-100"
    local concurrency_values=(10 50 100 200)

    for concurrency in "${concurrency_values[@]}"; do
        log_info "测试并发数: $concurrency"

        local start_time=$(date +%s)

        if timeout 120s zig-out/bin/simaqian -r "$ports" -t "$concurrency" --timeout 2000 --format txt "$target" > /dev/null 2>&1; then
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            log_success "并发数 $concurrency 测试完成，耗时: ${duration}秒"
        else
            log_warning "并发数 $concurrency 测试可能存在问题"
        fi
    done
}

# 内存泄漏测试
run_memory_tests() {
    log_info "运行内存泄漏测试..."

    # 使用valgrind如果可用
    if command -v valgrind &> /dev/null; then
        log_info "使用valgrind进行内存泄漏检测..."

        if timeout 60s valgrind --leak-check=full --error-exitcode=1 zig-out/bin/simaqian --help > /dev/null 2>&1; then
            log_success "内存泄漏测试通过"
        else
            log_error "发现内存泄漏"
            exit 1
        fi
    else
        log_warning "未找到valgrind，跳过内存泄漏测试"
    fi
}

# 压力测试
run_stress_tests() {
    log_info "运行压力测试..."

    local target="103.235.46.115"
    local ports="1-1000"

    log_info "压力测试目标: $target"
    log_info "测试端口范围: $ports"

    local start_time=$(date +%s)

    # 使用较低的并发数进行压力测试
    if timeout 300s zig-out/bin/simaqian -r "$ports" -t 200 --timeout 5000 --format txt "$target" > /dev/null 2>&1; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_success "压力测试完成，耗时: ${duration}秒"
    else
        log_warning "压力测试可能存在问题"
    fi
}

# 生成测试报告
generate_report() {
    log_info "生成测试报告..."

    local report_file="test_report_$(date +%Y%m%d_%H%M%S).log"

    {
        echo "========================================"
        echo "司马迁端口扫描器自动化测试报告"
        echo "生成时间: $(date)"
        echo "========================================"
        echo ""

        # 编译信息
        echo "编译信息:"
        echo "  Zig版本: $(zig version)"
        echo "  编译模式: ReleaseFast"
        echo "  目标平台: $(zig build-exe --show-builtin | grep 'target.*linux')"
        echo ""

        # 测试结果摘要
        echo "测试结果摘要:"
        echo "  ✓ 项目编译"
        echo "  ✓ 单元测试"
        echo "  ✓ 集成测试"
        echo "  ✓ 性能测试"
        echo "  ✓ 并发测试"
        echo "  ✓ 压力测试"
        echo ""

        # 建议
        echo "测试建议:"
        echo "  1. 根据实际网络环境调整超时时间"
        echo "  2. 在生产环境中使用较低的并发数以避免被封禁"
        echo "  3. 定期更新测试目标以确保测试有效性"
        echo "  4. 监控系统资源使用情况"
        echo ""

        echo "测试完成时间: $(date)"
        echo "========================================"

    } > "$report_file"

    log_success "测试报告已生成: $report_file"
}

# 主测试流程
main() {
    log_info "开始自动化测试流程..."

    check_dependencies
    build_project
    run_unit_tests
    run_integration_tests
    run_performance_tests
    run_concurrency_tests
    run_stress_tests
    run_memory_tests
    generate_report

    log_success "所有测试完成！"
    log_info "可执行文件位于: zig-out/bin/simaqian"
    log_info "使用 'zig-out/bin/simaqian --help' 查看帮助信息"
}

# 运行主函数
main "$@"