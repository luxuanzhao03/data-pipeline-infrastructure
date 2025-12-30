# Nginx 实时日志分析平台 (Log Analytics Pipeline)

这是一个基于 **Shell + Docker** 构建的轻量级 ELT 数据管道。它能够实时采集 Nginx 访问日志，通过消息队列缓冲，最终存入列式数据库以供分析和可视化。

## 🏗 架构设计 (Architecture)

数据流向如下：
**Nginx (JSON Logs)** -> **Vector (采集)** -> **Kafka (缓冲)** -> **Vector (消费)** -> **ClickHouse (存储)** -> **Grafana (展示)**

```mermaid
graph LR
    A[Nginx Access Log] -->|File Watch| B(Vector Agent)
    B -->|JSON Payload| C{Kafka Topic: nginx-access-logs}
    C -->|Consumer Group| B
    B -->|Batch Write| D[(ClickHouse)]
    D -->|Query| E[Grafana Dashboard]
