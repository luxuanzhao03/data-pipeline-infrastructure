#更新 docker-compose.yml，使得加入grafana和clickhouse
cd /opt/data-pipeline

cat > docker-compose.yml <<'EOF'
services:
  # --- 1. Kafka (消息队列) ---
  kafka:
    image: bitnami/kafka:3.6
    container_name: kafka
    restart: always
    ports:
      - "9092:9092"
    environment:
      - KAFKA_CFG_NODE_ID=0
      - KAFKA_CFG_PROCESS_ROLES=controller,broker
      - KAFKA_CFG_CONTROLLER_QUORUM_VOTERS=0@kafka:9093
      - KAFKA_CFG_LISTENERS=PLAINTEXT://:9092,CONTROLLER://:9093
      - KAFKA_CFG_ADVERTISED_LISTENERS=PLAINTEXT://kafka:9092
      - KAFKA_CFG_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
      - KAFKA_CFG_CONTROLLER_LISTENER_NAMES=CONTROLLER
    volumes:
      - kafka_data:/bitnami/kafka

  # --- 2. Vector (数据搬运工) ---
  vector:
    image: timberio/vector:0.34.0-debian
    container_name: vector
    restart: always
    volumes:
      - ./vector.toml:/etc/vector/vector.toml:ro
      - /var/log/nginx:/var/log/nginx:ro
      - vector_data:/var/lib/vector
    command: ["--config", "/etc/vector/vector.toml"]
    depends_on:
      - kafka
      - clickhouse

  # --- 3. ClickHouse (数据库) ---
  clickhouse:
    image: clickhouse/clickhouse-server:latest
    container_name: clickhouse
    restart: always
    ports:
      - "8123:8123"
      - "9000:9000"
    environment:
      - CLICKHOUSE_DB=logs
      - CLICKHOUSE_USER=default
      - CLICKHOUSE_PASSWORD=123456  # <--- 这里！我们要设置一个密码
      - CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1
    ulimits:
      nofile:
        soft: 262144
        hard: 262144
    volumes:
      - clickhouse_data:/var/lib/clickhouse

  # --- 4. Grafana (可视化大屏) ---
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: always
    ports:
      - "3000:3000" # 浏览器访问端口
    volumes:
      - grafana_data:/var/lib/grafana
    depends_on:
      - clickhouse

volumes:
  kafka_data:
  vector_data:
  clickhouse_data:
  grafana_data:
EOF


#更新vector.toml,使得打通kafka到clickhouse，配置采集和消费
cat > vector.toml <<'EOF'
data_dir = "/var/lib/vector"

# ==========================
# 链路 A: 采集 (Nginx -> Kafka)
# ==========================

[sources.nginx_file]
type = "file"
include = ["/var/log/nginx/access.log"]
read_from = "beginning"

[transforms.parse_json]
type = "remap"
inputs = ["nginx_file"]
source = '''
  . = parse_json!(.message)
  del(.message)
'''

[sinks.write_to_kafka]
type = "kafka"
inputs = ["parse_json"]
bootstrap_servers = "kafka:9092"
topic = "nginx-access-logs"
encoding.codec = "json"

# ==========================
# 链路 B: 入库 (Kafka -> ClickHouse)
# ==========================

# 1. 从 Kafka 读取
[sources.read_from_kafka]
type = "kafka"
bootstrap_servers = "kafka:9092"
group_id = "vector-clickhouse-consumer"
topics = ["nginx-access-logs"]

# 2. 解析 Kafka 里的 JSON
[transforms.parse_kafka_json]
type = "remap"
inputs = ["read_from_kafka"]
source = '''
  . = parse_json!(.message)
'''

# 3. 写入 ClickHouse
[sinks.write_to_clickhouse]
type = "clickhouse"
inputs = ["parse_kafka_json"]
endpoint = "http://clickhouse:8123"
database = "logs"
table = "nginx_access"
skip_unknown_fields = true
EOF

auth.strategy = "basic"
auth.user = "default"
auth.password = "123456" # 必须和 docker-compose 里的一致

#拉取镜像，clickhouse的和grafana的
docker compose up -d

#初始化clickhouse表结构，我们手动创建表
docker exec -i clickhouse clickhouse-client <<'EOF'
CREATE DATABASE IF NOT EXISTS logs;

CREATE TABLE IF NOT EXISTS logs.nginx_access (
    `time_local` String,
    `remote_addr` String,
    `request_method` String,
    `request_uri` String,
    `status` String,
    `body_bytes_sent` String,
    `http_referer` String,
    `http_user_agent` String,
    `request_time` String,
    `upstream_response_time` String,
    `_timestamp` DateTime DEFAULT now()
) ENGINE = MergeTree()
ORDER BY _timestamp;
EOF

#重启vector
docker compose restart vector
#制造流量
curl "http://127.0.0.1/?msg=visualization_test"
#确认数据已经入库，查数查一下，看看是不是0，密码要和设的一样
docker exec -i clickhouse clickhouse-client --password 123456 --query "SELECT count() FROM logs.nginx_access"



