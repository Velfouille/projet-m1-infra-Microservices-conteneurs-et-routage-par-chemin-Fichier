# StreamFlex APIs Docker

Ce projet contient 2 microservices. Les deux images sont hébergées sur **Docker Hub** (public).

- **Catalog API** : port `8080`, endpoint `/catalog`
- **User API** : port `5000`, endpoint `/user`

## Build & Push (Catalog API)

```bash
cd catalog-api
docker build -t <dockerhub_username>/streamflex-api:catalog-rds .
docker push <dockerhub_username>/streamflex-api:catalog-rds
```

Puis mettre à jour `Image:` dans `streamflex-ecs.yaml` (CatalogTaskDefinition).

## Build & Push (User API)

```bash
cd user-api
docker build -t <dockerhub_username>/streamflex-api:user-rds .
docker push <dockerhub_username>/streamflex-api:user-rds
```

Puis mettre à jour `Image:` dans `streamflex-ecs.yaml` (UserTaskDefinition).

## Images actuelles

| Service | Image Docker Hub |
|---|---|
| Catalog API | `velfouille/streamflex-api:catalog-rds` |
| User API | `velfouille/streamflex-api:user-rds` |
