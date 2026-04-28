# demo Java 应用部署配置

本项目包含 demo 生产环境 Java 应用的部署配置文件，提供完整的应用生命周期管理能力，遵循生产环境最佳实践。

## 项目结构

```
├── app.env.example    # 环境变量配置示例
├── appctl.sh          # 应用管理脚本 (v2.0)
├── demo.service       # systemd 服务配置
└── README.md          # 项目说明文档
```

## 文件说明

### 1. app.env.example

生产环境 Java 应用配置示例文件，包含以下配置项：
- **基础配置**：应用名称、端口、JAR 文件名
- **路径配置**：应用目录、日志目录、PID 文件路径
- **Java 配置**：JDK 路径
- **JVM 配置**：堆内存、元空间、线程栈大小
- **GC 配置**：GC 类型（G1/ZGC/Shenandoah）、最大 GC 停顿时间
- **Spring 配置**：Profile 配置
- **健康检查配置**：健康检查 URL、超时时间、检查间隔
- **优雅停机配置**：停机超时时间

### 2. appctl.sh

生产环境 Java 应用启动脚本，支持以下功能：

| 命令 | 功能 |
|------|------|
| `start` | 启动应用（包含健康检查） |
| `stop` | 优雅停止应用 |
| `restart` | 重启应用 |
| `status` | 查看应用状态 |
| `logs [N]` | 查看最后 N 行日志（默认 100） |
| `diagnose` | 诊断应用运行状态（线程数、内存使用、GC 统计等） |
| `help` | 显示帮助信息 |

**脚本特性**：
- 环境变量外部化配置
- 启动前环境检查（Java、目录权限、端口占用、磁盘空间）
- 完整的 JVM 参数构建（内存、GC、OOM 堆转储、GC 日志）
- 健康检查机制
- 优雅停机支持（SIGTERM → 等待 → SIGKILL 兜底）
- 线程 Dump 生成
- 彩色日志输出

### 3. demo.service

Systemd 服务配置文件，用于将应用注册为系统服务：
- 运行用户：`appuser`
- 依赖网络服务启动
- 配置重启策略和资源限制
- 日志输出到 journal

## 快速开始

### 1. 环境准备

```bash
# 创建运行用户
sudo useradd -r -s /sbin/nologin appuser
sudo groupadd -r appgroup
sudo usermod -aG appgroup appuser

# 创建应用目录
sudo mkdir -p /opt/apps/demo
sudo mkdir -p /var/log/demo
sudo chown -R appuser:appgroup /opt/apps/demo /var/log/demo
```

### 2. 部署应用

```bash
# 将 JAR 包上传到应用目录
cp demo.jar /opt/apps/demo/

# 复制配置文件
cp appctl.sh /opt/apps/demo/
cp app.env.example /opt/apps/demo/.env
chmod +x /opt/apps/demo/appctl.sh

# 复制 systemd 服务配置
cp demo.service /etc/systemd/system/
sudo systemctl daemon-reload
```

### 3. 配置环境变量

```bash
# 编辑环境变量配置
vi /opt/apps/demo/.env

# 加载环境变量
source /opt/apps/demo/.env
```

### 4. 启动应用

**方式一：使用脚本启动**
```bash
cd /opt/apps/demo
source .env
./appctl.sh start
```

**方式二：使用 systemd 启动**
```bash
sudo systemctl start demo
sudo systemctl enable demo  # 设置开机自启
```

### 5. 管理应用

```bash
# 查看状态
./appctl.sh status
# 或
sudo systemctl status demo

# 查看日志
./appctl.sh logs 200
# 或
journalctl -u demo -f

# 停止应用
./appctl.sh stop
# 或
sudo systemctl stop demo

# 诊断应用
./appctl.sh diagnose
```

## 环境变量配置说明

| 变量名 | 默认值 | 说明 |
|--------|--------|------|
| `APP_NAME` | demo | 应用名称 |
| `APP_PORT` | 9181 | 应用端口 |
| `JAR_NAME` | demo.jar | JAR 文件名 |
| `APP_HOME` | /opt/apps/${APP_NAME} | 应用主目录 |
| `LOG_DIR` | /var/log/${APP_NAME} | 日志目录 |
| `JAVA_HOME` | /usr/lib/jvm/java-17-openjdk | Java 安装路径 |
| `JVM_XMS` | 4g | 初始堆大小 |
| `JVM_XMX` | 4g | 最大堆大小 |
| `JVM_METASPACE_SIZE` | 256m | 初始元空间大小 |
| `JVM_MAX_METASPACE_SIZE` | 512m | 最大元空间大小 |
| `JVM_XSS` | 256k | 线程栈大小 |
| `JVM_GC_TYPE` | G1 | GC 类型（G1/ZGC/Shenandoah） |
| `JVM_MAX_GC_PAUSE` | 200 | 最大 GC 停顿时间（毫秒） |
| `SPRING_PROFILES` | prod | Spring Profile |
| `HEALTH_CHECK_TIMEOUT` | 120 | 健康检查超时（秒） |
| `HEALTH_CHECK_INTERVAL` | 2 | 健康检查间隔（秒） |
| `GRACEFUL_SHUTDOWN_TIMEOUT` | 60 | 优雅停机超时（秒） |

## JVM 参数配置：生产环境黄金法则

### 堆内存配置

生产环境最核心的原则是：**初始堆大小等于最大堆大小**（`-Xms = -Xmx`）。

```bash
JVM_XMS=4g
JVM_XMX=4g
```

**建议规则**：
- 堆内存总量不超过物理内存的 **50%~70%**，需为操作系统、堆外内存、线程栈、元空间及系统缓存预留足够空间。
- 若容器化部署，JVM 堆大小应基于容器内存限制动态计算。

### GC 算法选型

| GC 算法 | 适用场景 | 推荐参数 |
|---------|----------|----------|
| **G1GC** | 大内存（≥2GB）、低延迟要求的 Web 服务 | `-XX:+UseG1GC -XX:MaxGCPauseMillis=200` |
| **ZGC** | JDK 17+，超大堆（TB 级）、亚毫秒级停顿 | `-XX:+UseZGC` |
| **Shenandoah** | 低延迟，与 ZGC 类似 | `-XX:+UseShenandoahGC` |

### 容器环境配置

脚本已内置容器感知支持：
- `-XX:+UseContainerSupport`
- `-XX:MaxRAMPercentage=75.0`

## 日志说明

日志文件结构：
```
/var/log/demo/
├── app_rbvm_9181.log    # 应用日志
├── gc/                  # GC 日志目录
│   └── gc_YYYYMMDD_HHMMSS.log
├── heapdump/            # OOM 堆转储目录
│   └── heapdump_YYYYMMDD_HHMMSS.hprof
└── threaddump_YYYYMMDD_HHMMSS.txt  # 线程 Dump（停止时生成）
```

GC 日志配置了自动轮转：保留 10 个文件，每个 100MB。

## 健康检查

应用需提供健康检查端点：`http://localhost:${APP_PORT}/actuator/health`

启动时会自动进行健康检查，超时时间可通过 `HEALTH_CHECK_TIMEOUT` 配置。

Spring Boot 应用建议启用 `actuator/health` 端点，配合 `management.endpoint.health.probes.enabled=true` 提供 Kubernetes 原生的 Liveness 和 Readiness 探针。

## 优雅停机

停止应用时：
1. 生成线程 Dump
2. 发送 SIGTERM 信号
3. 等待进程退出（可配置超时时间）
4. 超时后强制终止（SIGKILL）

Spring Boot 2.3+ 内置了优雅停机支持，可通过以下参数启用：
```
server.shutdown=graceful
spring.lifecycle.timeout-per-shutdown-phase=30s
```

## 监控与可观测性

### JMX 远程监控

开启 JMX 以便接入 Prometheus JMX Exporter 或 VisualVM 进行实时监控：
```
-Dcom.sun.management.jmxremote
-Dcom.sun.management.jmxremote.port=9010
-Dcom.sun.management.jmxremote.authenticate=true
-Dcom.sun.management.jmxremote.ssl=true
```

**注意**：生产环境必须启用认证和 SSL，禁止明文暴露 JMX 端口。

### 指标采集（Metrics）

推荐通过 **Micrometer + Prometheus** 暴露以下核心指标：
- JVM 内存使用（堆、非堆、元空间、直接内存）
- GC 次数与停顿时间
- 线程数与线程状态
- HTTP 请求 QPS、延迟、错误率
- 数据库连接池状态

### 链路追踪与日志

- 接入 **OpenTelemetry** 或 **SkyWalking** 实现分布式链路追踪
- 日志采用结构化格式（JSON），统一收集至 ELK / Loki
- 关键日志字段必须包含：`traceId`、`spanId`、`timestamp`、`serviceName`

## 容器化部署建议

现代生产环境强烈建议使用容器化部署：

- **基础镜像**：使用 `eclipse-temurin:17-jre-alpine` 等精简 JRE 镜像
- **多阶段构建**：构建阶段使用 JDK，运行阶段仅保留 JRE 和可执行 JAR
- **非 root 用户**：容器内以非特权用户运行 Java 进程
- **资源限制**：为容器设置合理的 `memory limit` 和 `cpu limit`

## 发布策略

生产环境变更必须遵循可控的发布策略：

| 策略 | 说明 | 适用场景 |
|------|------|----------|
| **滚动更新** | 逐批次替换实例，零停机 | 常规迭代 |
| **蓝绿部署** | 两套环境并行，一键切换流量 | 核心系统大版本发布 |
| **金丝雀发布** | 小流量验证，逐步扩大 | 风险较高的功能上线 |

## 生产环境启动检查清单

| 检查项 | 要求 |
|--------|------|
| JVM 版本 | 使用 LTS 版本（JDK 17/21），避免已停止维护的版本 |
| 堆内存 | `-Xms = -Xmx`，不超过物理内存 70% |
| GC 算法 | 明确指定 G1GC 或 ZGC，开启 GC 日志 |
| OOM 处理 | 开启 `HeapDumpOnOutOfMemoryError`，指定转储路径 |
| 元空间 | 使用 `-XX:MaxMetaspaceSize` 限制上限 |
| 启动校验 | 启动后验证健康检查接口，确认服务可用 |
| 停止策略 | 使用 SIGTERM 优雅停机，超时后再 SIGKILL 兜底 |
| 进程守护 | 使用 systemd / Kubernetes，崩溃后自动重启 |
| 监控接入 | JMX + Prometheus + 链路追踪 + 结构化日志 |
| 配置管理 | 环境变量或配置中心，禁止脚本硬编码 |
| 发布策略 | 滚动更新 / 蓝绿 / 金丝雀，具备快速回滚能力 |

## 常见误区

| 错误做法 | 潜在风险 | 正确做法 |
|----------|----------|----------|
| `kill -9 $pid` 强制终止 | 无法触发 ShutdownHook，可能导致数据丢失 | SIGTERM 优雅停机，超时后 SIGKILL 兜底 |
| 使用 `-XX:PermSize/MaxPermSize` | Java 8+ 已移除 PermGen，参数无效 | 使用 `-XX:MetaspaceSize/MaxMetaspaceSize` |
| `-Xss512k` 过大线程栈 | 高并发下可能触发 `OutOfMemoryError` | 根据应用特点设置为 256k~512k |
| 无启动成功校验 | 故障发现滞后 | 启动后验证健康检查接口 |
| `nohup ... &` 无守护 | 崩溃后无法自动恢复 | 使用 systemd 或容器编排平台 |
| 路径与参数全硬编码 | 环境迁移困难，配置管理混乱 | 通过环境变量注入配置 |

## 系统要求

- Linux 操作系统（支持 systemd）
- Java 8/11/17/21（推荐 LTS 版本）
- curl（用于健康检查）
- jstack/jstat（用于诊断）