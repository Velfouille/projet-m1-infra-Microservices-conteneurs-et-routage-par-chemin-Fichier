#!/bin/bash
set -e

REGION_ACTIVE="us-east-1"
REGION_PASSIVE="us-west-2"
MASTER_STACK_NAME="StreamFlex-Master"

echo -n "Entrez vos initiales ou celles de votre equipe (ex: mbn, nox, team1) : "
read TEAM_PREFIX
TEAM_PREFIX=$(echo "$TEAM_PREFIX" | tr '[:upper:]' '[:lower:]')

TEMPLATE_BUCKET="s3-streamflex-templates-${TEAM_PREFIX}-${REGION_ACTIVE}"
FRONTEND_BUCKET_BASE="s3-projet-m1-infra-cloud-${TEAM_PREFIX}"

echo "1/4 - Remise de la region active en mode nominal (${REGION_ACTIVE})..."
aws cloudformation deploy \
  --template-file streamflex-master.yaml \
  --stack-name $MASTER_STACK_NAME \
  --region $REGION_ACTIVE \
  --parameter-overrides TemplateBucket=$TEMPLATE_BUCKET NbConteneurs=2 TeamPrefix=$TEAM_PREFIX \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset

echo "2/4 - Remise de la region passive en pilot light..."
aws cloudformation deploy \
  --template-file streamflex-master.yaml \
  --stack-name $MASTER_STACK_NAME \
  --region $REGION_PASSIVE \
  --parameter-overrides TemplateBucket=$TEMPLATE_BUCKET NbConteneurs=0 TeamPrefix=$TEAM_PREFIX \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset

echo "3/4 - Recuperation des URLs ALB..."
ALB_URL_ACTIVE=$(aws cloudformation describe-stacks \
  --stack-name $MASTER_STACK_NAME \
  --region $REGION_ACTIVE \
  --query "Stacks[0].Outputs[?OutputKey=='MasterALBUrl'].OutputValue" \
  --output text)

ALB_URL_PASSIVE=$(aws cloudformation describe-stacks \
  --stack-name $MASTER_STACK_NAME \
  --region $REGION_PASSIVE \
  --query "Stacks[0].Outputs[?OutputKey=='MasterALBUrl'].OutputValue" \
  --output text)

echo "4/4 - Publication du frontend en mode normal..."
sed \
  -e "s|{{ALB_URL}}|$ALB_URL_ACTIVE|g" \
  -e "s|{{ALB_URL_PASSIVE}}|$ALB_URL_PASSIVE|g" \
  -e "s/{{REGION_NAME}}/$REGION_ACTIVE (ACTIVE)/g" \
  ../index.html > index_active.html

sed \
  -e "s|{{ALB_URL}}|$ALB_URL_ACTIVE|g" \
  -e "s|{{ALB_URL_PASSIVE}}|$ALB_URL_PASSIVE|g" \
  -e "s/{{REGION_NAME}}/$REGION_PASSIVE (SECOURS)/g" \
  ../index.html > index_passive.html

aws s3 cp index_active.html s3://${FRONTEND_BUCKET_BASE}-${REGION_ACTIVE}/index.html \
  --cache-control "no-store, no-cache, must-revalidate, max-age=0"
aws s3 cp index_passive.html s3://${FRONTEND_BUCKET_BASE}-${REGION_PASSIVE}/index.html \
  --cache-control "no-store, no-cache, must-revalidate, max-age=0"
rm index_active.html index_passive.html

echo "------------------------------------------------------"
echo "Retour nominal termine."
echo "ALB active : http://$ALB_URL_ACTIVE"
echo "ALB passive : http://$ALB_URL_PASSIVE"
echo "------------------------------------------------------"
