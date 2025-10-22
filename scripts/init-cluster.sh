#!/bin/bash

# Initialize Kafka Cluster Script
echo "🚀 Initializing Kafka Cluster..."

# Check if Docker is running
if ! docker info >/dev/null 2>&1; then
    echo "❌ Docker is not running. Please start Docker Desktop first."
    echo "   You can start it by running: open -a Docker"
    exit 1
fi

echo "✅ Docker is running!"

# Create data directories if they don't exist
echo "📁 Creating data directories..."
mkdir -p data/dev/node1 data/dev/node2 data/dev/node3 data/dev/node4

# Set proper permissions
echo "🔐 Setting permissions..."
chmod -R 755 data/

echo "✅ Data directories created successfully!"
echo "🎯 You can now run: docker compose -f docker-compose.kafka.yml up -d"
echo "💡 Note: Storage formatting will happen automatically when the containers start."
