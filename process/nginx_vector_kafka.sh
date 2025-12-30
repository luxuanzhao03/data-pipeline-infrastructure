!/bin/bash
set -e  # 遇到错误立即退出
set -u  # 遇到未定义的变量立即退出

#安装工具包
yum install -y yum-utils

#设置docker的阿里云镜像
yum-config-manager \
    --add-repo \
    https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo

#修正，因为我用的是阿里云，它与centos的版号对不上的，不然会报错，如果用的是centos不用修正
sed -i 's/$releasever/8/g' /etc/yum.repos.d/docker-ce.repo

#正式安装docker
yum install -y docker-ce docker-ce-cli containerd.io

#启动并设置开机自启动
systemctl start docker
systemctl enable docker

#验证，看版号是否显示
docker --version

#检查是否有版号，按理说比较新的docker是内置的
docker compose version


#安装Nginx
yum install -y nginx

#养成原有配置备份的好习惯
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak

#新的配置，用vim，nano，写入都可以，或者直接抄以下bash
cat > /etc/nginx/nginx.conf <<'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

# 加载动态模块
include /usr/share/nginx/modules/*.conf;

events {
    worker_connections 1024;
}

http {
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    # --- 核心配置：定义 JSON 格式日志 ---
    log_format json_analytics escape=json '{'
        '"time_local": "$time_local",'
        '"remote_addr": "$remote_addr",'
        '"request_method": "$request_method",'
        '"request_uri": "$request_uri",'
        '"status": "$status",'
        '"body_bytes_sent": "$body_bytes_sent",'
        '"http_referer": "$http_referer",'
        '"http_user_agent": "$http_user_agent",'
        '"request_time": "$request_time",'
        '"upstream_response_time": "$upstream_response_time"'
    '}';
    # --------------------------------

    # 让 access.log 使用上面的 JSON 格式
    access_log  /var/log/nginx/access.log  json_analytics;

    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    types_hash_max_size 2048;

    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;

    # 加载子配置
    include /etc/nginx/conf.d/*.conf;

    # 默认服务器
    server {
        listen       80 default_server;
        listen       [::]:80 default_server;
        server_name  _;
        root         /usr/share/nginx/html;

        include /etc/nginx/default.d/*.conf;

        location / {
        }

        error_page 404 /404.html;
            location = /40x.html {
        }

        error_page 500 502 503 504 /50x.html;
            location = /50x.html {
        }
    }
}
EOF

#启动nginx
systemctl enable nginx
systemctl start nginx

#自己访问自己
curl "http://127.0.0.1/?test_log=true"

#查看日志，是不是json格式
tail -n 1 /var/log/nginx/access.log

#接下来下载kafka核vector
#用这个docker镜像源，可能能下不一定
mkdir -p /etc/docker

tee /etc/docker/daemon.json <<-'EOF'
{
  "registry-mirrors": [
    "https://docker.1panel.live",
    "https://hub.rat.dev",
    "https://docker.anyhub.us.kg",
    "https://docker.chenby.cn"
  ]
}
EOF

#重启docker生效
systemctl daemon-reload
systemctl restart docker

#配置vector配置文件

cd /opt/data-pipeline

cat > vector.toml <<'EOF'
# --- 全局配置 ---
data_dir = "/var/lib/vector"  # 注意：这里不能用方括号包起来

# --- 1. 输入源 ---
[sources.nginx_logs]
type = "file"
include = ["/var/log/nginx/access.log"]
read_from = "beginning"

# --- 2. 转换层 ---
[transforms.parse_json]
type = "remap"
inputs = ["nginx_logs"]
source = '''
  . = parse_json!(.message)
  del(.message)
'''

# --- 3. 输出层 ---
[sinks.to_kafka]
type = "kafka"
inputs = ["parse_json"]
bootstrap_servers = "kafka:9092"
topic = "nginx-access-logs"
encoding.codec = "json"

# 批处理缓冲
[sinks.to_kafka.batch]
max_events = 500
timeout_secs = 1
EOF


#配置docker compose配置文件

cat > docker-compose.yml <<'EOF'
services:
  # --- Kafka (单节点 KRaft 模式) ---
  kafka:
    image: bitnami/kafka:3.6
    container_name: kafka
    restart: always
    ports:
      - "9092:9092"
    environment:
      # KRaft 角色配置
      - KAFKA_CFG_NODE_ID=0
      - KAFKA_CFG_PROCESS_ROLES=controller,broker
      - KAFKA_CFG_CONTROLLER_QUORUM_VOTERS=0@kafka:9093
      # 监听器配置 (容器内用 PLAINTEXT，控制器用 CONTROLLER)
      - KAFKA_CFG_LISTENERS=PLAINTEXT://:9092,CONTROLLER://:9093
      - KAFKA_CFG_ADVERTISED_LISTENERS=PLAINTEXT://kafka:9092
      - KAFKA_CFG_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
      - KAFKA_CFG_CONTROLLER_LISTENER_NAMES=CONTROLLER
    volumes:
      - kafka_data:/bitnami/kafka # 数据持久化卷

  # --- Vector (日志采集器) ---
  vector:
    image: timberio/vector:0.34.0-debian
    container_name: vector
    restart: always
    volumes:
      - ./vector.toml:/etc/vector/vector.toml:ro  # 挂载配置文件
      - /var/log/nginx:/var/log/nginx:ro          # 关键：挂载宿主机的日志目录
      - vector_data:/var/lib/vector               # 持久化 Vector 进度
    command: ["--config", "/etc/vector/vector.toml"]
    depends_on:
      - kafka

volumes:
  kafka_data:
  vector_data:
EOF

#启动docker compose自动下载
cd /opt/data-pipeline
docker compose up -d


#重启容器
docker compose restart vector

#看看vector日志有没有报错，Healthcheck: passed这就是好了
docker logs -f vector

#产生新数据测试以下链路
curl "http://127.0.0.1/?msg=fix_config_test"

#查看kafka，有没有出现json数据
docker exec -it kafka /opt/bitnami/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic nginx-access-logs \
  --from-beginning




















