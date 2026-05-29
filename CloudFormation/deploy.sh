#!/bin/bash

echo "🚀 Début du déploiement StreamFlex sur us-east-1..."

# 1. Déploiement du Réseau
echo "1/3 : Création du réseau (VPC, Subnets, NAT)..."
aws cloudformation deploy \
  --template-file streamflex-network.yaml \
  --stack-name StreamFlex-Network \
  --region us-east-1

# 2. Déploiement de la Sécurité et du Load Balancer
echo "2/3 : Création de l'ALB et des Security Groups..."
aws cloudformation deploy \
  --template-file streamflex-alb.yaml \
  --stack-name StreamFlex-ALB \
  --region us-east-1

# 3. Déploiement du Cluster ECS
echo "3/3 : Lancement des conteneurs Fargate..."
aws cloudformation deploy \
  --template-file streamflex-ecs.yaml \
  --stack-name StreamFlex-ECS \
  --region us-east-1

echo "✅ Déploiement terminé ! L'infrastructure est prête."