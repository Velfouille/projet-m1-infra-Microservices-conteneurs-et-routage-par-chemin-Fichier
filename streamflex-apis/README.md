# StreamFlex APIs Docker

Ce projet contient 2 microservices à builder et pusher vers leurs registres respectifs.

- **Catalog API** : port `8080`, endpoint `/catalog` → **Docker Hub** (public)
- **User API** : port `5000`, endpoint `/user` → **Amazon ECR** (privé)

## Catalog API (Docker Hub)

```bash
cd catalog-api
docker build -t <dockerhub_username>/streamflex-api:catalog .
docker push <dockerhub_username>/streamflex-api:catalog
```

Puis mettre à jour `Image:` dans `streamflex-ecs.yaml` (CatalogTaskDefinition).

## User API (ECR)

```bash
cd user-api

# Authentification ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <account_id>.dkr.ecr.us-east-1.amazonaws.com

# Créer le repo (si pas déjà fait)
aws ecr create-repository --repository-name streamflex-user-api --region us-east-1 || true

# Build & Push
docker build -t streamflex-user-api .
docker tag streamflex-user-api:latest <account_id>.dkr.ecr.us-east-1.amazonaws.com/streamflex-user-api:latest
docker push <account_id>.dkr.ecr.us-east-1.amazonaws.com/streamflex-user-api:latest
```

Répéter pour us-west-2 si nécessaire. L'image est référencée automatiquement dans `streamflex-ecs.yaml` via `!Sub "${AWS::AccountId}.dkr.ecr.${AWS::Region}.amazonaws.com/streamflex-user-api:latest"`.

## Test local

```bash
cd catalog-api
docker build -t streamflex-catalog-api .
docker run --rm -p 8080:8080 streamflex-catalog-api
curl http://localhost:8080/catalog
```

```bash
cd user-api
docker build -t streamflex-user-api .
docker run --rm -p 5000:5000 streamflex-user-api
curl http://localhost:5000/user
```
