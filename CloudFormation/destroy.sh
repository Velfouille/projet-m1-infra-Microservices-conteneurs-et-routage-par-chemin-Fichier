#!/bin/bash
set -e

REGION="us-east-1"
MASTER_STACK_NAME="StreamFlex-Master"
TEMPLATE_BUCKET="s3-streamflex-templates-mbn" 
FRONTEND_BUCKET="s3-projet-m1-infra-cloud-mbn"

echo "🧹 Début de la destruction de l'infrastructure globale StreamFlex..."

# ÉTAPE 0 : Vider les deux buckets S3 (Front-end et Templates)
echo "🗑️  0/2 : Vidage des buckets S3 pour autoriser la suppression..."
aws s3 rm s3://$FRONTEND_BUCKET --recursive || true
aws s3 rm s3://$TEMPLATE_BUCKET --recursive || true

# ÉTAPE 1 : Suppression de la Master Stack (qui détruit automatiquement les 3 autres)
echo "🔥 1/2 : Suppression de la Master Stack (ECS, ALB, Réseau)..."
aws cloudformation delete-stack --stack-name $MASTER_STACK_NAME --region $REGION

# On dit au terminal de patienter jusqu'à la fin de la destruction
aws cloudformation wait stack-delete-complete --stack-name $MASTER_STACK_NAME --region $REGION

# ÉTAPE 2 : Suppression du bucket de templates (créé manuellement au déploiement)
echo "📦 2/2 : Suppression du bucket technique S3..."
aws s3 rb s3://$TEMPLATE_BUCKET --force || true

echo "------------------------------------------------------"
echo "✅ Destruction terminée avec succès !"
echo "Plus aucune ressource n'est active, ta facturation est à zéro."
echo "------------------------------------------------------"