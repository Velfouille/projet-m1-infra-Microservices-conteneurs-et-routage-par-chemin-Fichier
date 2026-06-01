#!/bin/bash
set -e

# Configuration des noms de stack
NET_STACK="StreamFlex-Network"
ALB_STACK="StreamFlex-ALB"
ECS_STACK="StreamFlex-ECS"
REGION="us-east-1"

echo "🚀 Démarrage du déploiement synchronisé StreamFlex..."

# 1. RÉSEAU
echo "📦 [1/3] Déploiement du réseau (VPC, Subnets, NAT)..."
aws cloudformation deploy \
  --template-file streamflex-infra.yaml \
  --stack-name $NET_STACK \
  --region $REGION \
  --no-fail-on-empty-changeset

# 2. ALB (Sécurité & Routage)
echo "🚦 [2/3] Déploiement de l'ALB et des Security Groups..."
aws cloudformation deploy \
  --template-file streamflex-alb.yaml \
  --stack-name $ALB_STACK \
  --region $REGION \
  --no-fail-on-empty-changeset

# 3. ECS (Conteneurs)
echo "🐳 [3/3] Déploiement des services Fargate..."
aws cloudformation deploy \
  --template-file streamflex-ecs.yaml \
  --stack-name $ECS_STACK \
  --region $REGION \
  --no-fail-on-empty-changeset

echo "✅ BRAVO ! L'infrastructure est en ligne."
echo "------------------------------------------------------"

# 4. Récupération de l'URL publique
echo "🔍 Récupération du point d'entrée réseau..."
ALB_URL=$(aws cloudformation describe-stacks \
  --stack-name $ALB_STACK \
  --region $REGION \
  --query "Stacks[0].Outputs[?OutputKey=='ALBUrl'].OutputValue" \
  --output text)

echo "🌍 Tes microservices sont accessibles ici :"
echo "➡️  Catalogue : http://$ALB_URL/catalog"
echo "➡️  Utilisateurs : http://$ALB_URL/user"
echo "------------------------------------------------------"