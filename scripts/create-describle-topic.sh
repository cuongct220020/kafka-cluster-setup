#!/bin/bash
# Usage: ./create-describe-topic.sh [topic-name]
TOPIC=${1:-test-topic}  # default topic là "test-topic"

echo "🧪 Creating topic: $TOPIC..."
docker exec kafka-1 /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka-1:9092 \
  --create --topic "$TOPIC" \
  --partitions 3 --replication-factor 3 \
  || echo "⚠️ Topic may already exist."

echo "📝 Describing topic: $TOPIC..."
docker exec kafka-1 /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka-1:9092 \
  --describe --topic "$TOPIC"