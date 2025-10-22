#!/bin/bash
echo "📋 Listing topics on each node..."

for node in 1 2 3 4; do
  echo "➡️  kafka-$node:"
  docker exec kafka-$node /opt/kafka/bin/kafka-topics.sh \
    --bootstrap-server kafka-$node:9092 --list
  echo ""
done