#!/bin/bash

echo "🧹 Début de la destruction de l'infrastructure StreamFlex..."

# ÉTAPE 0 : Vider le bucket S3 (Sinon CloudFormation plantera)
echo "🗑️  0/3 : Vidage du bucket S3 front-end..."
aws s3 rm s3://s3-projet-m1-infra-cloud-mbn --recursive || true

echo "1/3 : Suppression des conteneurs ECS..."
aws cloudformation delete-stack --stack-name StreamFlex-ECS --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name StreamFlex-ECS --region us-east-1

echo "2/3 : Suppression du Load Balancer..."
aws cloudformation delete-stack --stack-name StreamFlex-ALB --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name StreamFlex-ALB --region us-east-1

echo "3/3 : Suppression du Réseau (Cela peut prendre quelques minutes)..."
aws cloudformation delete-stack --stack-name StreamFlex-Network --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name StreamFlex-Network --region us-east-1

echo "✅ Destruction terminée ! Plus rien ne t'est facturé."