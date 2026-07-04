#!/bin/bash
echo "=== LocalStack Init: Criando recursos AWS ==="

# Criar fila SQS
awslocal sqs create-queue --queue-name my-queue --region us-east-1
echo "✅ Fila SQS 'my-queue' criada"

# Criar tabela DynamoDB
awslocal dynamodb create-table \
  --table-name analytics-events \
  --attribute-definitions AttributeName=event_id,AttributeType=S \
  --key-schema AttributeName=event_id,KeyType=HASH \
  --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
  --region us-east-1
echo "✅ Tabela DynamoDB 'analytics-events' criada"

echo "=== Init concluído ==="
