#!/bin/bash

echo "💾 Formatting Kafka storage directories..."

# Format storage for each node
for i in {1..4}; do
    echo "Formatting node $i..."
    docker run --rm -v $(pwd)/data/dev/node$i:/var/lib/kafka/data \
        -v $(pwd)/configs/dev/node$i/server.properties:/etc/kafka/server.properties \
        apache/kafka:latest /opt/kafka/bin/kafka-storage.sh format -t 4L6g3nShT-eMCtK--X86sw -c /etc/kafka/server.properties
done

echo "✅ Storage formatting complete!"
