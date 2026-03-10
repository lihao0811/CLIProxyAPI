# Railway 部署指南

## 快速部署

1. 在 Railway 创建新项目
2. 连接此 GitHub 仓库
3. Railway 会自动检测 Dockerfile 并开始构建
4. 部署完成后，Railway 会自动分配域名和端口

## 环境变量配置（可选）

在 Railway 项目设置中添加以下环境变量：

```
DEPLOY=cloud
```

Railway 会自动设置 `PORT` 环境变量，应用会自动使用该端口。

## 配置说明

- 默认端口：8317（Railway 会自动映射到分配的端口）
- 配置文件：使用 `config.example.yaml` 作为模板
- 认证目录：`/data/auth`

## 首次使用

部署成功后：

1. 访问 Railway 分配的域名
2. 使用管理 API 进行配置
3. 添加你的 API keys 和提供商配置

## 注意事项

- Railway 免费计划有使用限制
- 建议配置持久化存储（使用环境变量配置 Postgres/Git/Object Store）
- 生产环境建议设置 `MANAGEMENT_PASSWORD` 环境变量
