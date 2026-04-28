# 生产环境配置文件管理

本项目用于统一管理生产环境的各类配置文件，提供标准化的部署配置模板和运维脚本。

## 项目结构

```
├── Metrics_Server/         # 指标服务配置
│   └── components.yaml     # 组件配置
├── k8s-nacos/              # Nacos Kubernetes 部署配置
│   ├── nacos-deploy.yaml   # Nacos 部署文件
│   ├── nacos-mysql.yaml    # MySQL 数据库配置
│   └── nacos_devtest.sql   # 初始化 SQL 脚本
├── prod-java-deployment/   # Java 应用生产环境部署配置
│   ├── README.md           # 详细部署说明
│   ├── app.env.example     # 环境变量配置示例
│   ├── appctl.sh           # 应用管理脚本
│   └── rbvm.service        # systemd 服务配置
├── push.sh                 # 配置推送脚本
└── README.md               # 项目说明文档
```

## 目录说明

### 1. Metrics_Server/

指标服务相关配置文件，用于监控和度量数据收集。

### 2. k8s-nacos/

Kubernetes 环境下 Nacos 服务的部署配置：

- **nacos-deploy.yaml** - Nacos 服务部署配置
- **nacos-mysql.yaml** - Nacos 依赖的 MySQL 数据库配置
- **nacos_devtest.sql** - Nacos 初始化数据脚本

### 3. prod-java-deployment/

Java 应用生产环境部署配置，包含完整的应用生命周期管理能力：

- **app.env.example** - 环境变量配置示例（JVM 参数、端口、路径等）
- **appctl.sh** - 应用管理脚本（支持 start/stop/restart/status/logs/diagnose）
- **rbvm.service** - systemd 服务配置

详细说明请参考 [prod-java-deployment/README.md](prod-java-deployment/README.md)

### 4. push.sh

配置文件推送脚本，用于将配置同步到目标环境。

## 配置管理规范

### 1. 环境变量管理

所有敏感配置和环境相关配置应通过环境变量注入，禁止硬编码：

- 开发环境：`.env.dev`
- 测试环境：`.env.test`
- 生产环境：`.env.prod`

### 2. 配置文件版本控制

- 配置文件应纳入版本控制
- 敏感信息（密码、密钥等）不应提交到仓库
- 使用 `.env.example` 作为配置模板

### 3. 部署流程

```bash
# 1. 克隆仓库
git clone <repository-url>
cd trae_projects

# 2. 根据环境复制配置模板
cp prod-java-deployment/app.env.example .env.prod

# 3. 修改配置
vi .env.prod

# 4. 加载配置并部署
source .env.prod
bash prod-java-deployment/appctl.sh start
```

## 运维命令速查

### Java 应用管理

```bash
# 启动应用
cd prod-java-deployment
source .env
./appctl.sh start

# 停止应用
./appctl.sh stop

# 查看状态
./appctl.sh status

# 查看日志
./appctl.sh logs 200

# 诊断应用
./appctl.sh diagnose
```

### Nacos 部署（Kubernetes）

```bash
# 部署 MySQL
kubectl apply -f k8s-nacos/nacos-mysql.yaml

# 部署 Nacos
kubectl apply -f k8s-nacos/nacos-deploy.yaml

# 查看状态
kubectl get pods -n nacos
```

## 安全注意事项

1. **敏感信息保护**：数据库密码、API 密钥等敏感信息应通过密钥管理服务（如 Vault、Kubernetes Secrets）管理，禁止明文存储
2. **权限控制**：配置文件应设置合理的文件权限（建议 600）
3. **加密传输**：配置传输过程应使用 HTTPS 或 SSH
4. **审计日志**：记录配置变更历史，便于追溯

## 维护说明

- 定期更新配置模板，保持与生产环境同步
- 配置变更应经过代码审查
- 重要配置变更应在低峰期进行，并做好回滚准备

## 联系信息

如有问题或建议，请联系运维团队。