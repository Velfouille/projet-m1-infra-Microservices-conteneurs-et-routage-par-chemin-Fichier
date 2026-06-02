#!/bin/bash
set -e

### DEBUT MODIFICATION (AVEC NOÉ) ###
REGION_ACTIVE="us-east-1"
REGION_PASSIVE="us-west-2"
MASTER_STACK_NAME="StreamFlex-Master"
TEMPLATE_BUCKET="s3-streamflex-templates-mbn" 
FRONTEND_BUCKET_BASE="s3-projet-m1-infra-cloud-mbn"
### FIN MODIFICATION (AVEC NOÉ) ###

echo "🧹 Début de la destruction de l'infrastructure globale Multi-Région..."

### DEBUT MODIFICATION (AVEC NOÉ) ###
echo "🗑️  0/2 : Vidage des buckets S3 pour autoriser la suppression..."
# Vidage des deux buckets Front (Actif et Passif)
aws s3 rm s3://${FRONTEND_BUCKET_BASE}-${REGION_ACTIVE} --recursive || true
aws s3 rm s3://${FRONTEND_BUCKET_BASE}-${REGION_PASSIVE} --recursive || true
aws s3 rm s3://$TEMPLATE_BUCKET --recursive || true

echo "🔥 1/2 : Suppression des Master Stacks (ECS, ALB, Réseau) en parallèle..."
# Le petit '&' à la fin permet de lancer la suppression des deux régions en même temps
aws cloudformation delete-stack --stack-name $MASTER_STACK_NAME --region $REGION_PASSIVE &
aws cloudformation delete-stack --stack-name $MASTER_STACK_NAME --region $REGION_ACTIVE &

echo "⏳ Attente de la destruction (cela peut prendre environ 5 à 10 minutes)..."
aws cloudformation wait stack-delete-complete --stack-name $MASTER_STACK_NAME --region $REGION_PASSIVE
aws cloudformation wait stack-delete-complete --stack-name $MASTER_STACK_NAME --region $REGION_ACTIVE
### FIN MODIFICATION (AVEC NOÉ) ###

echo "📦 2/2 : Suppression du bucket technique S3..."
aws s3 rb s3://$TEMPLATE_BUCKET --force || true

echo "------------------------------------------------------"
echo "✅ Destruction multi-région terminée avec succès !"
echo "Plus aucune ressource n'est active, ta facturation est à zéro."
echo "------------------------------------------------------"