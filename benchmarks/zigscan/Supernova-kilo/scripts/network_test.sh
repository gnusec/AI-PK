#!/bin/bash

# 司马迁端口扫描器网络测试验证脚本
# 使用真实外网IP进行网络相关测试以验证真实环境下的稳定性

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# 测试目标配置
# 已知开放某些端口的真实外网IP
declare -A TEST_TARGETS=(
    ["103.235.46.115"]="已知开放80,443端口的目标"
    ["8.8.8.8"]="Google公共DNS"
    ["1.1.1.1"]="Cloudflare公共DNS"
    ["208.67.222.222"]="OpenDNS"
)

# 端口测试配置
declare -A PORT_TESTS=(
    ["基础端口"]="21,22,23,25,53,80,110,135,139,143,443,445,993,995,1723,3306,3389,5900,8080"
    ["Web端口"]="80,443,8080,8443"
    ["常见端口"]="1-100"
    ["扩展端口"]="1-1000"
    ["全端口"]="1-65535"
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

log_test() {
    echo -e "${PURPLE}[TEST]${NC} $*"
}

# 检查依赖
check_dependencies() {
    log_info "检查测试依赖..."

    if ! command -v zig &> /dev/null; then
        log_error "未找到zig编译器"
        exit 1
    fi

    if ! command -v timeout &> /dev/null; then
        log_error "未找到timeout命令，请安装coreutils"
        exit 1
    fi

    if ! command -v ping &> /dev/null; then
        log_warning "未找到ping命令，跳过连通性测试"
    fi

    # 检查可执行文件是否存在
    if [[ ! -f "zig-out/bin/simaqian" ]]; then
        log_error "未找到编译好的可执行文件，请先运行编译脚本"
        exit 1
    fi
}

# 测试网络连通性
test_connectivity() {
    local target=$1
    local description=$2

    log_test "测试网络连通性: $target ($description)"

    if command -v ping &> /dev/null; then
        if timeout 10s ping -c 3 "$target" > /dev/null 2>&1; then
            log_success "网络连通性正常"
            return 0
        else
            log_warning "网络连通性测试失败"
            return 1
        fi
    else
        # 如果没有ping，使用简单的端口测试来验证连通性
        if timeout 5s zig-out/bin/simaqian -p "53" -t 1 --timeout 2000 --format txt "$target" > /dev/null 2>&1; then
            log_success "网络连通性正常"
            return 0
        else
            log_warning "网络连通性测试失败"
            return 1
        fi
    fi
}

# 测试单个端口配置
test_port_config() {
    local target=$1
    local ports=$2
    local description=$3
    local concurrency=${4:-50}
    local timeout_ms=${5:-3000}

    log_test "测试端口配置: $description (端口: $ports)"

    local start_time=$(date +%s)

    # 使用严格的超时控制
    if timeout 60s zig-out/bin/simaqian \
        -p "$ports" \
        -t "$concurrency" \
        --timeout "$timeout_ms" \
        --format txt \
        "$target" > /tmp/simaqian_test_$$.out 2>&1; then

        local end_time=$(date +%s)
        local duration=$((end_time - start_time))

        local open_ports=$(wc -l < /tmp/simaqian_test_$$.out)
        log_success "端口测试完成，耗时: ${duration}秒，发现开放端口: $open_ports"

        # 显示发现的端口
        if [[ $open_ports -gt 0 ]]; then
            log_info "开放端口列表:"
            cat /tmp/simaqian_test_$$.out | while read -r port; do
                if [[ $port =~ ^[0-9]+$ ]]; then
                    log_info "  端口 $port 开放"
                fi
            done
        fi

        return 0
    else
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_warning "端口测试超时或失败，耗时: ${duration}秒"
        return 1
    fi
}

# 测试并发性能
test_concurrency_performance() {
    local target=$1
    local ports="80,443"
    local concurrency_values=(10 50 100 200 500)

    log_test "测试并发性能: $target"

    for concurrency in "${concurrency_values[@]}"; do
        log_info "测试并发数: $concurrency"

        local start_time=$(date +%s)

        if timeout 30s zig-out/bin/simaqian \
            -p "$ports" \
            -t "$concurrency" \
            --timeout 2000 \
            --format txt \
            "$target" > /dev/null 2>&1; then

            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            log_success "并发数 $concurrency 测试通过，耗时: ${duration}秒"
        else
            log_warning "并发数 $concurrency 测试失败或超时"
        fi
    done
}

# 测试超时机制
test_timeout_mechanism() {
    local target=$1
    local ports="1-100"
    local timeout_values=(500 1000 2000 5000)

    log_test "测试超时机制: $target"

    for timeout_ms in "${timeout_values[@]}"; do
        log_info "测试超时时间: ${timeout_ms}ms"

        local start_time=$(date +%s)

        if timeout 45s zig-out/bin/simaqian \
            -r "$ports" \
            -t 50 \
            --timeout "$timeout_ms" \
            --format txt \
            "$target" > /dev/null 2>&1; then

            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            log_success "超时 ${timeout_ms}ms 测试通过，耗时: ${duration}秒"
        else
            log_warning "超时 ${timeout_ms}ms 测试失败或超时"
        fi
    done
}

# 测试输出格式
test_output_formats() {
    local target=$1
    local ports="80,443"
    local formats=("normal" "json" "txt")

    log_test "测试输出格式: $target"

    for format in "${formats[@]}"; do
        log_info "测试输出格式: $format"

        if timeout 15s zig-out/bin/simaqian \
            -p "$ports" \
            -t 20 \
            --timeout 2000 \
            --format "$format" \
            "$target" > /tmp/simaqian_${format}_$$.out 2>&1; then

            log_success "输出格式 $format 测试通过"

            # 验证输出文件
            if [[ -s "/tmp/simaqian_${format}_$$.out" ]]; then
                log_info "输出格式 $format 生成内容正常"
            else
                log_warning "输出格式 $format 输出内容为空"
            fi
        else
            log_warning "输出格式 $format 测试失败"
        fi
    done
}

# 测试资源使用情况
test_resource_usage() {
    local target=$1
    local ports="1-100"

    log_test "测试资源使用情况: $target"

    # 使用time命令监控资源使用
    if command -v time &> /dev/null; then
        local start_time=$(date +%s%N)

        if timeout 30s bash -c "
            time zig-out/bin/simaqian \
                -r '$ports' \
                -t 100 \
                --timeout 2000 \
                --format txt \
                '$target' > /dev/null 2>&1
        " 2> /tmp/simaqian_time_$$.out; then

            local end_time=$(date +%s%N)
            local duration_ms=$(( (end_time - start_time) / 1000000 ))

            log_success "资源使用测试完成，总耗时: ${duration_ms}ms"

            # 显示时间统计
            if [[ -f "/tmp/simaqian_time_$$.out" ]]; then
                log_info "时间统计:"
                cat /tmp/simaqian_time_$$.out
            fi
        else
            log_warning "资源使用测试失败或超时"
        fi
    else
        log_warning "未找到time命令，跳过资源使用测试"
    fi
}

# 生成网络测试报告
generate_network_report() {
    log_info "生成网络测试报告..."

    local report_file="network_test_report_$(date +%Y%m%d_%H%M%S).log"

    {
        echo "========================================"
        echo "司马迁端口扫描器网络测试报告"
        echo "生成时间: $(date)"
        echo "测试环境: $(uname -a)"
        echo "========================================"
        echo ""

        echo "测试目标:"
        for target in "${!TEST_TARGETS[@]}"; do
            echo "  $target - ${TEST_TARGETS[$target]}"
        done
        echo ""

        echo "测试配置:"
        echo "  最大超时时间: 60秒"
        echo "  最大并发数: 500"
        echo "  测试端口范围: 1-65535"
        echo ""

        echo "测试完成时间: $(date)"
        echo "========================================"

    } > "$report_file"

    log_success "网络测试报告已生成: $report_file"
}

# 主测试流程
main() {
    log_info "开始网络测试验证流程..."

    check_dependencies

    local success_count=0
    local total_count=0

    # 对每个测试目标进行全面测试
    for target in "${!TEST_TARGETS[@]}"; do
        log_info "开始测试目标: $target"
        local target_success=0
        local target_total=0

        # 网络连通性测试
        ((total_count++))
        if test_connectivity "$target" "${TEST_TARGETS[$target]}"; then
            ((success_count++))
            ((target_success++))
        fi
        ((target_total++))

        # 端口测试
        for port_desc in "${!PORT_TESTS[@]}"; do
            ((total_count++))
            ((target_total++))

            if test_port_config "$target" "${PORT_TESTS[$port_desc]}" "$port_desc" 50 3000; then
                ((success_count++))
                ((target_success++))
            fi
        done

        # 并发性能测试
        ((total_count++))
        ((target_total++))
        if test_concurrency_performance "$target"; then
            ((success_count++))
            ((target_success++))
        fi

        # 超时机制测试
        ((total_count++))
        ((target_total++))
        if test_timeout_mechanism "$target"; then
            ((success_count++))
            ((target_success++))
        fi

        # 输出格式测试
        ((total_count++))
        ((target_total++))
        if test_output_formats "$target"; then
            ((success_count++))
            ((target_success++))
        fi

        # 资源使用测试
        ((total_count++))
        ((target_total++))
        if test_resource_usage "$target"; then
            ((success_count++))
            ((target_success++))
        fi

        log_info "目标 $target 测试完成: $target_success/$target_total 通过"
    done

    # 清理临时文件
    rm -f /tmp/simaqian_*_$$.out

    generate_network_report

    # 输出最终结果
    log_success "网络测试完成！"
    log_info "总测试数: $total_count"
    log_info "通过测试: $success_count"
    log_info "成功率: $(echo "scale=2; $success_count * 100 / $total_count" | bc -l)%"

    if [[ $success_count -eq $total_count ]]; then
        log_success "所有测试通过！端口扫描器在真实网络环境下工作正常。"
    else
        log_warning "部分测试失败，请检查网络环境和防火墙设置。"
    fi

    log_info "可执行文件位于: zig-out/bin/simaqian"
    log_info "使用示例:"
    echo "  zig-out/bin/simaqian -p '80,443' 103.235.46.115"
    echo "  zig-out/bin/simaqian -r '1-1000' -t 100 example.com"
    echo "  zig-out/bin/simaqian --format json example.com"
}

# 运行主函数
main "$@"