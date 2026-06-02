#!/bin/bash
set -e

REGION="us-east-1"
MASTER_STACK_NAME="StreamFlex-Master"
# Un nouveau bucket dédié et strictement privé pour ton code d'infrastructure
TEMPLATE_BUCKET="s3-streamflex-templates-mbn" 
FRONTEND_BUCKET="s3-projet-m1-infra-cloud-mbn"

echo "🚀 Démarrage du déploiement Master StreamFlex..."

# 0. Création automatique du bucket de templates s'il n'existe pas
echo "🪣  0/3 : Vérification du bucket de templates..."
if aws s3api head-bucket --bucket "$TEMPLATE_BUCKET" 2>/dev/null; then
    echo "Le bucket $TEMPLATE_BUCKET existe déjà."
else
    echo "Création du bucket privé $TEMPLATE_BUCKET..."
    aws s3 mb s3://$TEMPLATE_BUCKET --region $REGION
fi

# 1. Envoi des sous-templates sur le bucket privé
echo "📁 1/3 : Upload des templates YAML vers S3..."
aws s3 cp streamflex-infra.yaml s3://$TEMPLATE_BUCKET/
aws s3 cp streamflex-alb.yaml s3://$TEMPLATE_BUCKET/
aws s3 cp streamflex-ecs.yaml s3://$TEMPLATE_BUCKET/

# 2. Déploiement de la Master Stack
echo "🏗️  2/3 : Déploiement de l'infrastructure globale..."
aws cloudformation deploy \
  --template-file streamflex-master.yaml \
  --stack-name $MASTER_STACK_NAME \
  --region $REGION \
  --parameter-overrides TemplateBucket=$TEMPLATE_BUCKET \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset

# 3. Récupération de l'URL de l'ALB
echo "🔍 Récupération du point d'entrée ALB..."
# L'ALB est dynamique, on interroge AWS pour trouver l'URL générée
# Note : on utilise --query sur les Exports globaux si la stack enfant change de nom
ALB_URL=$(aws cloudformation describe-stacks \
  --stack-name StreamFlex-ALB \
  --region $REGION \
  --query "Stacks[0].Outputs[?OutputKey=='ALBUrl'].OutputValue" \
  --output text || echo "ALB_NON_TROUVE")

# Le S3 est statique (car tu as imposé le nom du bucket), on le déclare en dur !
FRONTEND_URL="http://${FRONTEND_BUCKET}.s3-website-${REGION}.amazonaws.com"

# 4. Déploiement du site web sur S3
echo "🌐 3/3 : Envoi du fichier index.html vers S3..."
aws s3 cp ../index.html s3://$FRONTEND_BUCKET/

echo "------------------------------------------------------"
echo "🎉 PROJET TERMINÉ ! Voici tes liens :"
echo "💻 Portail Web (Front-End) : $FRONTEND_URL"
echo "⚙️  API Catalogue directe : http://$ALB_URL/catalog"
echo "⚙️  API Utilisateurs directe : http://$ALB_URL/user"
echo "------------------------------------------------------"