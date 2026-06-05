# StreamFlex — Présentation Orale (3 parties)

> **Vue d'ensemble** : Plateforme de streaming fictive en microservices multi-région sur AWS, avec basculement automatique entre us-east-1 (active) et us-west-2 (secours) en modèle Pilot Light.

---

## Partie 1 — Architecture réseau & microservices

### VPC & sous-réseaux

Chaque région a son propre VPC `10.0.0.0/16` découpé en **4 subnets** :

| Subnet | CIDR | Rôle |
|---|---|---|
| Public AZ1 | `10.0.0.0/24` | ALB (internet-facing) |
| Public AZ2 | `10.0.1.0/24` | ALB (haute disponibilité) |
| Privé AZ1 | `10.0.2.0/24` | ECS Fargate + RDS |
| Privé AZ2 | `10.0.3.0/24` | ECS Fargate + RDS |

- Les conteneurs **n'ont pas d'IP publique** (`AssignPublicIp: DISABLED`)
- L'accès Internet sortant passe par **2 NAT Gateways** (une par AZ)
- **L'ALB est le seul point d'entrée public** → tout le trafic est filtré à un seul endroit

### Les deux microservices

L'ALB route par chemin :

```
/ → frontend S3 (statique)
/catalog* → API Catalog (port 8080)
/user*    → API User (port 5000)
```

**API Catalogue — DynamoDB** (table `streamflex-catalog-db`, clé `id`)
- Données clé-valeur (fiches produit : titre, catégorie, description)
- Pas de relations entre entités → **NoSQL** adapté
- Streams intégrés utilisés pour la réplication cross-région

**API Utilisateurs — Aurora MySQL** (cluster `streamflex-user-cluster`)
- Données relationnelles (compte lié à abonnement, historique, préférences)
- Besoin d'ACID → **Aurora MySQL** adapté
- Migré depuis DynamoDB en cours de projet (contrainte LabRole levée)

### Conteneurisation

- **Node.js 20** (Express) sur **alpine**, déployé sur **ECS Fargate**
- Images hébergées sur **Docker Hub** (public)
- 2 conteneurs par service en région active, 0 en région passive (Pilot Light)

---

## Partie 2 — Réplication cross-région & sécurité

### Réplication DynamoDB (Catalogue)

```
us-east-1                          us-west-2
DynamoDB Table                     DynamoDB Table
  ↓ Stream (NEW_AND_OLD_IMAGES)
  ↓ Lambda (Python, boto3)
  └──────────────→ DynamoDB API ──→ put_item / delete_item
```

- Stream activé sur la table source → capture chaque INSERT / MODIFY / REMOVE
- Lambda `streamflex-dynamodb-sync-stream` lit les événements et les réplique vers west
- **Event-driven**, sans surcharge applicative

### Réplication Aurora MySQL (Utilisateurs)

Mécanisme : **Lambda VPC-enabled** invoquée cross-région :

```
POST /user → east RDS (write local)
          → Lambda.invoke(west, InvocationType='Event')
          → Lambda VPC-enabled (subnets privés west)
          → west RDS (write privé)
```

- La Lambda utilise **pymysql** (via une Lambda layer buildée au déploiement)
- Elle est **VPC-enabled** dans le VPC west → accès direct au RDS west en subnet privé
- Plus besoin de rendre le RDS west public

### Sécurité — 3 cercles de confiance

| Security Group | Règles entrantes |
|---|---|
| **ALB SG** | HTTP (80) depuis `0.0.0.0/0` |
| **ECS SG** | 8080, 5000 depuis ALB SG **uniquement** |
| **RDS SG** | 3306 depuis subnets privés **uniquement** |

- Mots de passe en `NoEcho` dans CloudFormation
- Chiffrement AES-256 par défaut (Aurora, DynamoDB, S3)
- Aucune exposition directe des conteneurs ou de la base à Internet

---

## Partie 3 — Auto-failover & déploiement

### Pilot Light

La région west a toute l'infrastructure prête (VPC, ALB, RDS, ECS cluster) mais **0 conteneur en marche** → coût quasi nul.

### Chaîne d'auto-failover

```
Route53 Health Check (/user/health, toutes les 30s)
  ↓ 3 échecs consécutifs (~90s)
CloudWatch Alarm (streamflex-autofailover-alarm)
  ↓ ALARM
SNS Topic
  ↓
Lambda Auto-Failover (Python, boto3)
  ↓
ECS west : desiredCount 0 → 2 (scale up)
  ↓
Trafic basculé vers west
```

- **Failback symétrique** : quand east revient, alarme → OK → Lambda remet west à 0
- **Runbook manuel** : scripts `failover.sh` / `failback.sh` en cas de panne de l'auto-failover
- **Frontend JS** : détection client-side avec polling toutes les 30s

### Infrastructure as Code — 6 templates CloudFormation

```
streamflex-master.yaml          ← Stack maître (orchestre)
├── streamflex-infra.yaml       ← VPC, NAT, DynamoDB, Aurora, Lambda réplication
├── streamflex-alb.yaml         ← ALB, Target Groups, SG
├── streamflex-ecs.yaml         ← ECS Fargate, services, frontend S3
└── streamflex-autofailover.yaml ← Lambda, SNS, CloudWatch, Route53 Health Check
```

- **Pourquoi CloudFormation plutôt que Terraform ?** Natif AWS, rollback automatique, pas d'état à gérer, pas de permission IAM implicite (problématique avec Learner Lab)
- **Déploiement parallélisé** : east + west se déploient en simultané (~30% plus rapide)

### Scripts de déploiement

| Script | Rôle |
|---|---|
| `deploy.sh` | Build layer, upload templates, déploie east + west en parallèle, publie le frontend, déploie l'auto-failover |
| `destroy.sh` | Vide S3, nettoie ECS, supprime les stacks east + west en parallèle |

### Synthèse des choix techniques

| Contrainte | Solution retenue |
|---|---|
| Multi-région sans surcoût compute | Pilot Light (0 conteneurs en west) |
| Réplication catalogue | DynamoDB Stream + Lambda |
| Réplication utilisateurs | Lambda VPC-enabled cross-région avec pymysql |
| Pas de création de rôles IAM | Utilisation de `LabRole` (contrainte Learner Lab) |
| Basculement automatique | Route53 + CloudWatch + SNS + Lambda |
| Hébergement API | ECS Fargate (sans gestion de serveurs) |
