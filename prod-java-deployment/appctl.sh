#!/bin/bash
#===============================================================================
# 生产环境 Java 应用启动脚本
# 版本: 2.0
# 功能: 支持优雅启停、健康检查、日志轮转、配置外部化
#===============================================================================

set -euo pipefail

#===============================================================================
# 配置区 - 建议通过环境变量或外部配置文件注入，避免硬编码
#===============================================================================

# 基础配置
APP_NAME="${APP_NAME:-demo}"
APP_PORT="${APP_PORT:-9181}"
JAR_NAME="${JAR_NAME:-demo.jar}"

# 路径配置
APP_HOME="${APP_HOME:-/opt/apps/${APP_NAME}}"
LOG_DIR="${LOG_DIR:-/var/log/${APP_NAME}}"
PID_FILE="${PID_FILE:-/var/run/${APP_NAME}.pid}"
HEAP_DUMP_DIR="${HEAP_DUMP_DIR:-${LOG_DIR}/heapdump}"
GC_LOG_DIR="${GC_LOG_DIR:-${LOG_DIR}/gc}"

# Java 配置
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk}"
JAVA_BIN="${JAVA_HOME}/bin/java"

# JVM 内存配置
JVM_XMS="${JVM_XMS:-4g}"
JVM_XMX="${JVM_XMX:-4g}"
JVM_METASPACE_SIZE="${JVM_METASPACE_SIZE:-256m}"
JVM_MAX_METASPACE_SIZE="${JVM_MAX_METASPACE_SIZE:-512m}"
JVM_XSS="${JVM_XSS:-256k}"

# GC 配置
JVM_GC_TYPE="${JVM_GC_TYPE:-G1}"  # 可选: G1, ZGC, Shenandoah
JVM_MAX_GC_PAUSE="${JVM_MAX_GC_PAUSE:-200}"

# 其他配置
JVM_OTHER_OPTS="${JVM_OTHER_OPTS:-}"
SPRING_PROFILES="${SPRING_PROFILES:-prod}"

# 健康检查配置
HEALTH_CHECK_URL="${HEALTH_CHECK_URL:-http://localhost:${APP_PORT}/actuator/health}"
HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-120}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-2}"

# 优雅停机配置
GRACEFUL_SHUTDOWN_TIMEOUT="${GRACEFUL_SHUTDOWN_TIMEOUT:-60}"

#===============================================================================
# 颜色输出定义
#===============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#===============================================================================
# 日志函数
#===============================================================================
log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
    fi
}

#===============================================================================
# 环境检查函数
#===============================================================================

# 检查 Java 环境
check_java() {
    log_info "检查 Java 环境..."

    if [[ ! -x "${JAVA_BIN}" ]]; then
        log_error "Java 可执行文件不存在: ${JAVA_BIN}"
        exit 1
    fi

    local java_version
    java_version=$(${JAVA_BIN} -version 2>&1 | head -n 1)
    log_info "Java 版本: ${java_version}"

    # 检查是否为 LTS 版本 (8, 11, 17, 21)
    if ! echo "${java_version}" | grep -qE "(1\.8|11\.|17\.|21\.)"; then
        log_warn "当前 Java 版本不是推荐的 LTS 版本 (8/11/17/21)"
    fi
}

# 检查目录权限
check_directories() {
    log_info "检查目录权限..."

    local dirs=("${APP_HOME}" "${LOG_DIR}" "${HEAP_DUMP_DIR}" "${GC_LOG_DIR}")

    for dir in "${dirs[@]}"; do
        if [[ ! -d "${dir}" ]]; then
            log_info "创建目录: ${dir}"
            mkdir -p "${dir}" || {
                log_error "无法创建目录: ${dir}"
                exit 1
            }
        fi

        if [[ ! -w "${dir}" ]]; then
            log_error "目录无写权限: ${dir}"
            exit 1
        fi
    done
}

# 检查端口占用
check_port() {
    log_info "检查端口 ${APP_PORT} 占用情况..."

    if command -v ss &> /dev/null; then
        local port_pid
        port_pid=$(ss -tlnp | grep ":${APP_PORT} " | awk '{print $7}' | cut -d',' -f2 | cut -d'=' -f2 | head -n1)
    elif command -v netstat &> /dev/null; then
        local port_pid
        port_pid=$(netstat -tlnp 2>/dev/null | grep ":${APP_PORT} " | awk '{print $7}' | cut -d'/' -f1 | head -n1)
    else
        log_warn "未找到 ss 或 netstat 命令，跳过端口检查"
        return 0
    fi

    if [[ -n "${port_pid}" && "${port_pid}" != "-" ]]; then
        log_error "端口 ${APP_PORT} 已被进程 ${port_pid} 占用"
        exit 1
    fi

    log_info "端口 ${APP_PORT} 可用"
}

# 检查磁盘空间
check_disk_space() {
    log_info "检查磁盘空间..."

    local min_space_mb=1024
    local available_mb
    available_mb=$(df -m "${LOG_DIR}" | tail -1 | awk '{print $4}')

    if [[ "${available_mb}" -lt "${min_space_mb}" ]]; then
        log_error "磁盘空间不足: ${available_mb}MB < ${min_space_mb}MB"
        exit 1
    fi

    log_info "磁盘空间充足: ${available_mb}MB"
}

# 检查 JAR 文件
check_jar() {
    local jar_path="${APP_HOME}/${JAR_NAME}"

    if [[ ! -f "${jar_path}" ]]; then
        log_error "JAR 文件不存在: ${jar_path}"
        exit 1
    fi

    log_info "JAR 文件: ${jar_path}"
}

#===============================================================================
# JVM 参数构建
#===============================================================================
build_jvm_opts() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)

    # 基础内存参数
    local opts="-Xms${JVM_XMS} -Xmx${JVM_XMX}"

    # 元空间 (Java 8+)
    opts="${opts} -XX:MetaspaceSize=${JVM_METASPACE_SIZE}"
    opts="${opts} -XX:MaxMetaspaceSize=${JVM_MAX_METASPACE_SIZE}"

    # 线程栈
    opts="${opts} -Xss${JVM_XSS}"

    # GC 配置
    case "${JVM_GC_TYPE}" in
        G1)
            opts="${opts} -XX:+UseG1GC"
            opts="${opts} -XX:MaxGCPauseMillis=${JVM_MAX_GC_PAUSE}"
            ;;
        ZGC)
            opts="${opts} -XX:+UseZGC"
            ;;
        Shenandoah)
            opts="${opts} -XX:+UseShenandoahGC"
            ;;
        *)
            log_warn "未知的 GC 类型: ${JVM_GC_TYPE}, 使用默认 GC"
            ;;
    esac

    # OOM 时堆转储
    opts="${opts} -XX:+HeapDumpOnOutOfMemoryError"
    opts="${opts} -XX:HeapDumpPath=${HEAP_DUMP_DIR}/heapdump_${timestamp}.hprof"

    # GC 日志 (JDK 9+)
    opts="${opts} -Xlog:gc*:file=${GC_LOG_DIR}/gc_${timestamp}.log:time,uptime:filecount=10,filesize=100m"

    # 容器感知 (如果运行在容器中)
    opts="${opts} -XX:+UseContainerSupport"
    opts="${opts} -XX:MaxRAMPercentage=75.0"

    # 编码设置
    opts="${opts} -Dfile.encoding=UTF-8"
    opts="${opts} -Dsun.jnu.encoding=UTF-8"

    # 时区设置
    opts="${opts} -Duser.timezone=Asia/Shanghai"

    # Spring 配置
    opts="${opts} -Dspring.profiles.active=${SPRING_PROFILES}"

    # 应用名称和端口
    opts="${opts} -Dapp.name=${APP_NAME}"
    opts="${opts} -Dserver.port=${APP_PORT}"

    # 其他自定义参数
    if [[ -n "${JVM_OTHER_OPTS}" ]]; then
        opts="${opts} ${JVM_OTHER_OPTS}"
    fi

    echo "${opts}"
}

#===============================================================================
# 进程管理函数
#===============================================================================

# 获取进程 PID
get_pid() {
    if [[ -f "${PID_FILE}" ]]; then
        local pid
        pid=$(cat "${PID_FILE}" 2>/dev/null)
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            echo "${pid}"
            return 0
        fi
    fi

    # 通过端口查找
    if command -v ss &> /dev/null; then
        ss -tlnp | grep ":${APP_PORT} " | awk '{print $7}' | cut -d',' -f2 | cut -d'=' -f2 | head -n1
    elif command -v netstat &> /dev/null; then
        netstat -tlnp 2>/dev/null | grep ":${APP_PORT} " | awk '{print $7}' | cut -d'/' -f1 | head -n1
    fi
}

# 检查应用是否运行
is_running() {
    local pid
    pid=$(get_pid)
    [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

#===============================================================================
# 启动函数
#===============================================================================
do_start() {
    log_info "========== 开始启动 ${APP_NAME} =========="

    # 前置检查
    check_java
    check_directories
    check_port
    check_disk_space
    check_jar

    # 检查是否已运行
    if is_running; then
        log_warn "${APP_NAME} 已经在运行中 (PID: $(get_pid))"
        exit 0
    fi

    # 构建 JVM 参数
    local jvm_opts
    jvm_opts=$(build_jvm_opts)

    log_info "JVM 参数: ${jvm_opts}"

    # 设置环境变量
    export JAVA_HOME="${JAVA_HOME}"
    export PATH="${JAVA_HOME}/bin:${PATH}"

    # 构建启动命令
    local jar_path="${APP_HOME}/${JAR_NAME}"
    local log_file="${LOG_DIR}/app_${APP_NAME}_${APP_PORT}.log"

    local cmd="${JAVA_BIN} ${jvm_opts} -jar ${jar_path}"

    log_info "启动命令: ${cmd}"
    log_info "日志文件: ${log_file}"

    # 启动应用
    nohup ${cmd} >> "${log_file}" 2>&1 &
    local new_pid=$!

    # 写入 PID 文件
    echo "${new_pid}" > "${PID_FILE}"

    log_info "进程已启动, PID: ${new_pid}"

    # 等待应用就绪
    log_info "等待应用健康检查..."
    local elapsed=0
    local health_ok=false

    while [[ ${elapsed} -lt ${HEALTH_CHECK_TIMEOUT} ]]; do
        sleep ${HEALTH_CHECK_INTERVAL}
        elapsed=$((elapsed + HEALTH_CHECK_INTERVAL))

        # 检查进程是否还在
        if ! kill -0 "${new_pid}" 2>/dev/null; then
            log_error "进程已退出，启动失败"
            rm -f "${PID_FILE}"
            exit 1
        fi

        # 健康检查
        if curl -sf "${HEALTH_CHECK_URL}" &>/dev/null; then
            health_ok=true
            break
        fi

        log_debug "健康检查中... (${elapsed}/${HEALTH_CHECK_TIMEOUT}s)"
    done

    if [[ "${health_ok}" == "true" ]]; then
        log_info "✅ ${APP_NAME} 启动成功! (PID: ${new_pid}, 耗时: ${elapsed}s)"

        # 显示进程信息
        log_info "进程信息:"
        ps -p "${new_pid}" -o pid,ppid,cmd,pcpu,pmem,etime --no-headers | \
            awk '{printf "  PID: %s | PPID: %s | CPU: %s%% | MEM: %s%% | 运行时间: %s\n", $1, $2, $5, $6, $7}'
    else
        log_error "❌ 健康检查超时，启动可能失败"
        log_info "查看日志: tail -n 50 ${log_file}"
        exit 1
    fi
}

#===============================================================================
# 停止函数 (优雅停机)
#===============================================================================
do_stop() {
    log_info "========== 开始停止 ${APP_NAME} =========="

    local pid
    pid=$(get_pid)

    if [[ -z "${pid}" ]]; then
        log_warn "${APP_NAME} 未运行"
        rm -f "${PID_FILE}"
        return 0
    fi

    log_info "找到进程 PID: ${pid}"

    # 生成诊断文件
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local thread_dump="${LOG_DIR}/threaddump_${timestamp}.txt"

    log_info "生成线程 Dump: ${thread_dump}"
    ${JAVA_HOME}/bin/jstack -l "${pid}" > "${thread_dump}" 2>/dev/null || log_warn "生成线程 Dump 失败"

    # 发送 SIGTERM 信号
    log_info "发送 SIGTERM 信号 (优雅停机)..."
    kill "${pid}"

    # 等待进程退出
    local elapsed=0
    while [[ ${elapsed} -lt ${GRACEFUL_SHUTDOWN_TIMEOUT} ]]; do
        sleep 1
        elapsed=$((elapsed + 1))

        if ! kill -0 "${pid}" 2>/dev/null; then
            log_info "✅ ${APP_NAME} 已优雅停止 (耗时: ${elapsed}s)"
            rm -f "${PID_FILE}"
            return 0
        fi

        if [[ $((elapsed % 5)) -eq 0 ]]; then
            log_info "等待进程退出... (${elapsed}/${GRACEFUL_SHUTDOWN_TIMEOUT}s)"
        fi
    done

    # 超时后强制终止
    log_warn "优雅停机超时，强制终止进程..."
    kill -9 "${pid}" 2>/dev/null || true
    sleep 1

    if ! kill -0 "${pid}" 2>/dev/null; then
        log_info "✅ 进程已强制终止"
    else
        log_error "❌ 无法终止进程 ${pid}"
        exit 1
    fi

    rm -f "${PID_FILE}"
}

#===============================================================================
# 重启函数
#===============================================================================
do_restart() {
    log_info "========== 重启 ${APP_NAME} =========="
    do_stop
    sleep 2
    do_start
}

#===============================================================================
# 状态检查函数
#===============================================================================
do_status() {
    local pid
    pid=$(get_pid)

    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
        log_info "✅ ${APP_NAME} 运行中 (PID: ${pid})"

        # 显示进程详情
        ps -p "${pid}" -o pid,ppid,cmd,pcpu,pmem,etime --no-headers | \
            awk '{printf "  PID: %s | PPID: %s | CPU: %s%% | MEM: %s%% | 运行时间: %s\n", $1, $2, $5, $6, $7}'

        # 尝试健康检查
        if curl -sf "${HEALTH_CHECK_URL}" &>/dev/null; then
            log_info "健康检查: 正常"
        else
            log_warn "健康检查: 未响应"
        fi
    else
        log_info "❌ ${APP_NAME} 未运行"
        rm -f "${PID_FILE}" 2>/dev/null || true
    fi
}

#===============================================================================
# 日志查看函数
#===============================================================================
do_logs() {
    local log_file="${LOG_DIR}/app_${APP_NAME}_${APP_PORT}.log"
    local lines="${1:-100}"

    if [[ -f "${log_file}" ]]; then
        tail -n "${lines}" "${log_file}"
    else
        log_error "日志文件不存在: ${log_file}"
        exit 1
    fi
}

#===============================================================================
# 诊断函数
#===============================================================================
do_diagnose() {
    log_info "========== ${APP_NAME} 诊断信息 =========="

    local pid
    pid=$(get_pid)

    if [[ -z "${pid}" ]]; then
        log_error "应用未运行"
        exit 1
    fi

    log_info "进程 PID: ${pid}"

    # 线程信息
    log_info "--- 线程统计 ---"
    ${JAVA_HOME}/bin/jstack "${pid}" 2>/dev/null | grep -E "^\"" | wc -l | xargs -I {} echo "总线程数: {}"

    # 内存信息
    log_info "--- 内存使用 ---"
    ${JAVA_HOME}/bin/jstat -gc "${pid}" 2>/dev/null | tail -n 1 | awk '
    {
        printf "  S0C: %s | S1C: %s | S0U: %s | S1U: %s\n", $1, $2, $3, $4
        printf "  EC: %s | EU: %s | OC: %s | OU: %s\n", $5, $6, $7, $8
        printf "  MC: %s | MU: %s | CCSC: %s | CCSU: %s\n", $9, $10, $11, $12
    }'

    # GC 统计
    log_info "--- GC 统计 ---"
    ${JAVA_HOME}/bin/jstat -gcutil "${pid}" 2>/dev/null | tail -n 1 | awk '
    {
        printf "  S0: %s%% | S1: %s%% | E: %s%% | O: %s%% | M: %s%% | CCS: %s%%\n", $1, $2, $3, $4, $5, $6
        printf "  YGC: %s | YGCT: %s | FGC: %s | FGCT: %s | GCT: %s\n", $7, $8, $9, $10, $11
    }'

    # 打开文件数
    log_info "--- 文件描述符 ---"
    local fd_count
    fd_count=$(ls /proc/${pid}/fd 2>/dev/null | wc -l)
    local fd_limit
    fd_limit=$(cat /proc/${pid}/limits 2>/dev/null | grep "Max open files" | awk '{print $5}')
    echo "  已打开: ${fd_count} / 限制: ${fd_limit}"

    # 连接数
    log_info "--- 网络连接 ---"
    if command -v ss &> /dev/null; then
        ss -ant | grep -c "${APP_PORT}" | xargs -I {} echo "  端口 ${APP_PORT} 连接数: {}"
    fi
}

#===============================================================================
# 帮助信息
#===============================================================================
show_help() {
    cat << 'EOF'
生产环境 Java 应用管理脚本

用法: $0 {start|stop|restart|status|logs|diagnose|help}

命令:
    start       启动应用 (包含健康检查)
    stop        优雅停止应用
    restart     重启应用
    status      查看应用状态
    logs [N]    查看最后 N 行日志 (默认 100)
    diagnose    诊断应用运行状态
    help        显示帮助信息

环境变量配置:
    APP_NAME            应用名称 (默认: demo)
    APP_PORT            应用端口 (默认: 9181)
    JAR_NAME            JAR 文件名 (默认: demo.jar)
    APP_HOME            应用主目录 (默认: /opt/apps/${APP_NAME})
    LOG_DIR             日志目录 (默认: /var/log/${APP_NAME})
    JAVA_HOME           Java 安装路径
    JVM_XMS             初始堆大小 (默认: 4g)
    JVM_XMX             最大堆大小 (默认: 4g)
    JVM_GC_TYPE         GC 类型: G1|ZGC|Shenandoah (默认: G1)
    SPRING_PROFILES     Spring Profile (默认: prod)
    DEBUG               启用调试输出: true|false (默认: false)

示例:
    # 使用默认配置启动
    ./appctl.sh start

    # 指定配置启动
    APP_NAME=myapp APP_PORT=8080 JVM_XMS=2g JVM_XMX=2g ./appctl.sh start

    # 查看最后 200 行日志
    ./appctl.sh logs 200

EOF
}

#===============================================================================
# 主入口
#===============================================================================
main() {
    case "${1:-help}" in
        start)
            do_start
            ;;
        stop)
            do_stop
            ;;
        restart)
            do_restart
            ;;
        status)
            do_status
            ;;
        logs)
            do_logs "${2:-100}"
            ;;
        diagnose)
            do_diagnose
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "未知命令: ${1}"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
