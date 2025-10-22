#!/bin/bash
TOPIC=${1:-test-topic}
MESSAGE="Hello Kafka $(date +%s)"

echo "🚀 Producing message: '$MESSAGE'"
docker exec -i kafka-1 /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server kafka-1:9092 --topic "$TOPIC" <<< "$MESSAGE"

echo "📥 Consuming messages from $TOPIC (press Ctrl+C to stop)..."
docker exec kafka-2 /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server kafka-2:9092 --topic "$TOPIC" --from-beginning