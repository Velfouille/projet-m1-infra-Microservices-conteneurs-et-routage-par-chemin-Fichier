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

# 4. Récupération des points d'entrée
echo "🔍 Récupération des points d'entrée..."

ALB_URL=$(aws cloudformation describe-stacks \
  --stack-name $ALB_STACK \
  --region $REGION \
  --query "Stacks[0].Outputs[?OutputKey=='ALBUrl'].OutputValue" \
  --output text)

FRONTEND_URL="http://s3-projet-m1-infra-cloud-mbn.s3-website-us-east-1.amazonaws.com"

echo "🌐 Envoi du fichier index.html vers S3..."
aws s3 cp ../index.html s3://s3-projet-m1-infra-cloud-mbn/

echo "------------------------------------------------------"
echo "🎉 PROJET TERMINÉ ! Voici tes liens :"
echo "💻 Portail Web (Front-End) : $FRONTEND_URL"
echo "⚙️  API Catalogue directe : http://$ALB_URL/catalog"
echo "⚙️  API Utilisateurs directe : http://$ALB_URL/user"
echo "------------------------------------------------------"