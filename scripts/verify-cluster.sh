#!/bin/bash
echo "🔍 Verifying Kafka Cluster..."

./scripts/check-metadata.sh
./scripts/list-topics.sh
./scripts/create-describe-topic.sh
./scripts/test-produce-consume.sh
./scripts/delete-topic
./scripts/check-health.sh

echo "✅ Cluster verification complete!"
echo "🎉 Your Kafka cluster is running successfully!"
