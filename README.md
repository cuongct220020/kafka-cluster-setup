# Kafka Cluster Setup

Docker Compose configuration for a 4-node Apache Kafka cluster in KRaft mode (no ZooKeeper).

## Architecture

- **kafka-1, kafka-2, kafka-3**: Controller + Broker nodes
- **kafka-4**: Broker-only node
- **Cluster ID**: `4L6g3nShT-eMCtK--X86sw`
- **Default**: 3 partitions, replication factor 3

## Prerequisites

- Docker & Docker Compose
- Bash shell

## Quick Start

**1. Clone repository**
```bash
git clone https://github.com/cuongct220020/kafka-cluster-setup.git kafka-cluster
cd kafka-cluster
```

**2. Initialize cluster**
```bash
./scripts/init-cluster.sh
```

**3. Format storage (first time only)**
```bash
./scripts/format-storage.sh
```
⚠️ Only run on fresh setup or after complete reset. This will erase all data.

**4. Start cluster**
```bash
docker compose -f docker-compose.kafka.yml up -d
```

**5. Verify cluster is ready (30-60s)**
```bash
docker ps --format "table {{.Names}}	{{.Status}}	{{.Ports}}"
```
All containers should show "Up (healthy)".

## Testing & Verification

Run these scripts in order to test your cluster:

```bash
# 1. Check cluster metadata and brokers
./scripts/check-metadata.sh

# 2. List existing topics
./scripts/list-topics.sh

# 3. Create test topic and view details
./scripts/create-describe-topic.sh

# 4. Test message produce and consume
./scripts/test-produce-consume.sh

# 5. Delete test topic
./scripts/delete-topic.sh

# 6. Check cluster health
./scripts/check-health.sh
```

## Connection Details

| Node | External Port | Internal Port | Role |
|------|---------------|---------------|------|
| kafka-1 | 29092 | 19092 | Controller + Broker |
| kafka-2 | 39092 | 19092 | Controller + Broker |
| kafka-3 | 49092 | 19092 | Controller + Broker |
| kafka-4 | 59092 | 19092 | Broker Only |

**Bootstrap Servers:**
- Internal: `kafka-1:19092,kafka-2:19092,kafka-3:19092,kafka-4:19092`
- External: `localhost:29092,localhost:39092,localhost:49092,localhost:59092`

## Common Operations

**List topics**
```bash
docker exec kafka-1 kafka-topics.sh --bootstrap-server kafka-1:19092 --list
```

**Create topic**
```bash
docker exec kafka-1 kafka-topics.sh --bootstrap-server kafka-1:19092 \
  --create --topic my-topic --partitions 3 --replication-factor 3
```

**Describe topic**
```bash
docker exec kafka-1 kafka-topics.sh --bootstrap-server kafka-1:19092 \
  --describe --topic my-topic
```

**Produce messages (interactive)**
```bash
docker exec -it kafka-1 kafka-console-producer.sh \
  --bootstrap-server kafka-1:19092 --topic my-topic
```

**Consume messages**
```bash
docker exec kafka-1 kafka-console-consumer.sh \
  --bootstrap-server kafka-1:19092 --topic my-topic --from-beginning
```

**Delete topic**
```bash
docker exec kafka-1 kafka-topics.sh --bootstrap-server kafka-1:19092 \
  --delete --topic my-topic
```

## Management

**View logs**
```bash
docker compose -f docker-compose.kafka.yml logs kafka-1      # specific node
docker compose -f docker-compose.kafka.yml logs -f           # follow all
```

**Stop cluster**
```bash
docker compose -f docker-compose.kafka.yml down              # stop only
docker compose -f docker-compose.kafka.yml down -v           # stop + remove data
```

**Reset cluster completely**
```bash
docker compose -f docker-compose.kafka.yml down -v
rm -rf data/dev/node*/*
./scripts/init-cluster.sh
./scripts/format-storage.sh
docker compose -f docker-compose.kafka.yml up -d
```

## Troubleshooting

**Check ports in use**
```bash
netstat -tulpn | grep -E '29092|39092|49092|59092'
```

**View container status**
```bash
docker ps
```

**Check logs for errors**
```bash
docker compose -f docker-compose.kafka.yml logs
```

**Test broker connectivity**
```bash
docker exec kafka-1 kafka-broker-api-versions.sh --bootstrap-server kafka-1:19092
```

## Configuration

- **Compose file**: `docker-compose.kafka.yml`
- **Environment**: `.env`
- **Node configs**: `configs/dev/node*/server.properties`
- **Scripts**: `scripts/`

## Key Settings

- Retention: 7 days
- Segment size: 1GB
- KRaft mode (no ZooKeeper)
- Health checks enabled
- Data persistence via volumes