#!/bin/bash
echo "💚 Checking log directories (cluster health)..."

docker exec kafka-1 /opt/kafka/bin/kafka-log-dirs.sh \
  --bootstrap-server kafka-1:9092 --describe