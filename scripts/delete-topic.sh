#!/bin/bash
# Usage: ./delete-topic.sh [topic-name]
TOPIC=${1:-test-topic}

echo "🗑️ Deleting topic: $TOPIC..."
docker exec kafka-1 /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka-1:9092 \
  --delete --topic "$TOPIC" \
  || echo "⚠️ Topic may not exist or deletion pending."

echo "📋 Listing remaining topics..."
docker exec kafka-1 /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka-1:9092 --list