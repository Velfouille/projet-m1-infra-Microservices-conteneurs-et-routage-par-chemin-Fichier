# StreamFlex APIs Docker

Ce projet contient 2 microservices prêts à être buildés et poussés sur Docker Hub.

- `catalog-api` : répond sur le port `8080`, endpoint `/catalog`
- `user-api` : répond sur le port `5000`, endpoint `/user`

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

## Export vers Docker Hub

Remplace `<dockerhub_username>` par ton identifiant Docker Hub.

```bash
docker login

cd catalog-api
docker build -t <dockerhub_username>/streamflex-catalog-api:latest .
docker push <dockerhub_username>/streamflex-catalog-api:latest

cd ../user-api
docker build -t <dockerhub_username>/streamflex-user-api:latest .
docker push <dockerhub_username>/streamflex-user-api:latest
```

## Images à mettre dans ECS

```text
<dockerhub_username>/streamflex-catalog-api:latest
<dockerhub_username>/streamflex-user-api:latest
```
