#!/bin/bash
set -e

### DEBUT MODIFICATION ( NOÉ) ###
# Ajout des variables pour piloter les deux régions
REGION_ACTIVE="us-east-1"
REGION_PASSIVE="us-west-2"
MASTER_STACK_NAME="StreamFlex-Master"
TEMPLATE_BUCKET="s3-streamflex-templates-mbn" 
# On garde juste le préfixe du bucket front-end (la région sera ajoutée dynamiquement)
FRONTEND_BUCKET_BASE="s3-projet-m1-infra-cloud-mbn"
### FIN MODIFICATION ( NOÉ) ###

echo "🚀 Démarrage du déploiement Multi-Région StreamFlex..."

echo "🪣  0/4 : Création du bucket de templates global..."
if aws s3api head-bucket --bucket "$TEMPLATE_BUCKET" 2>/dev/null; then
    echo "Le bucket $TEMPLATE_BUCKET existe déjà."
else
    aws s3 mb s3://$TEMPLATE_BUCKET --region $REGION_ACTIVE
fi

echo "📁 1/4 : Upload des templates YAML vers S3..."
aws s3 cp streamflex-infra.yaml s3://$TEMPLATE_BUCKET/
aws s3 cp streamflex-alb.yaml s3://$TEMPLATE_BUCKET/
aws s3 cp streamflex-ecs.yaml s3://$TEMPLATE_BUCKET/
aws s3 cp streamflex-master.yaml s3://$TEMPLATE_BUCKET/

### DEBUT MODIFICATION ( NOÉ) ###
# Déploiement en 2 temps (Actif  2 conteneurs, Passif  0 conteneur)
echo "🏗️  2/4 : Déploiement de la région ACTIVE ($REGION_ACTIVE)..."
aws cloudformation deploy \
  --template-file streamflex-master.yaml \
  --stack-name $MASTER_STACK_NAME \
  --region $REGION_ACTIVE \
  --parameter-overrides TemplateBucket=$TEMPLATE_BUCKET NbConteneurs=2 \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset

echo "🏗️  3/4 : Déploiement de la région PASSIVE ($REGION_PASSIVE - Pilot Light)..."
aws cloudformation deploy \
  --template-file streamflex-master.yaml \
  --stack-name $MASTER_STACK_NAME \
  --region $REGION_PASSIVE \
  --parameter-overrides TemplateBucket=$TEMPLATE_BUCKET NbConteneurs=0 \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset

echo "🌐 4/4 : Envoi du fichier index.html vers S3 sur les deux régions..."
aws s3 cp ../index.html s3://${FRONTEND_BUCKET_BASE}-${REGION_ACTIVE}/
aws s3 cp ../index.html s3://${FRONTEND_BUCKET_BASE}-${REGION_PASSIVE}/

# Récupération des URLs pour les DEUX régions
ALB_URL_ACTIVE=$(aws cloudformation describe-stacks --stack-name StreamFlex-ALB --region $REGION_ACTIVE --query "Stacks[0].Outputs[?OutputKey=='ALBUrl'].OutputValue" --output text || echo "ALB_ACTIF_NON_TROUVE")
ALB_URL_PASSIVE=$(aws cloudformation describe-stacks --stack-name StreamFlex-ALB --region $REGION_PASSIVE --query "Stacks[0].Outputs[?OutputKey=='ALBUrl'].OutputValue" --output text || echo "ALB_PASSIF_NON_TROUVE")

echo "------------------------------------------------------"
echo "🎉 PROJET MULTI-RÉGION TERMINÉ ! Voici tes liens :"
echo "🌍 PORTAIL FRONT-END :"
echo " - Principal : http://${FRONTEND_BUCKET_BASE}-${REGION_ACTIVE}.s3-website-${REGION_ACTIVE}.amazonaws.com"
echo " - Secours   : http://${FRONTEND_BUCKET_BASE}-${REGION_PASSIVE}.s3-website-${REGION_PASSIVE}.amazonaws.com"
echo "⚙️  ALB (APIs) :"
echo " - Active  : http://$ALB_URL_ACTIVE"
echo " - Passive : http://$ALB_URL_PASSIVE (Attention, 0 conteneur démarré !)"
echo "------------------------------------------------------"
### FIN MODIFICATION ( NOÉ) ###