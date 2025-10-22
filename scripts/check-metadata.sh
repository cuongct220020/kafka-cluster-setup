#!/bin/bash
echo "📊 Checking broker metadata..."

for node in 1 2 3 4; do
  echo "➡️  kafka-$node:"
  docker exec kafka-$node /opt/kafka/bin/kafka-broker-api-versions.sh \
    --bootstrap-server kafka-$node:9092
  echo ""
done