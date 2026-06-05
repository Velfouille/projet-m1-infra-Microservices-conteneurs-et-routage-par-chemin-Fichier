# DSv4 — Rétrospective OpenCode : StreamFlex Multi-Region

## Objectif

Déployer une infrastructure AWS multi-région (us-east-1 active, us-west-2 Pilot Light) pour l'application StreamFlex avec :
- 2 microservices (Catalog DynamoDB, User Aurora MySQL)
- Auto-failover automatique (Route53 + CloudWatch + Lambda)
- Réplication cross-région des données

## Contrainte principale

Environnement **AWS Learner Lab** : seul le rôle `LabRole` est disponible. Pas de création de rôles IAM personnalisés.

---

## Problèmes rencontrés et solutions

### 1. Dépendance cyclique RDSSecurityGroup

**Problème :** `RDSSecurityGroup` créé avant `MainVPC` → échec CloudFormation.

**Solution :** Réordonner les ressources dans `streamflex-infra.yaml` : VPC/subnets avant RDS. Ajouter `DependsOn: MainVPC` sur le SG.

### 2. Classe d'instance RDS indisponible

**Problème :** `db.t3.small` non disponible → `UserDBInstance` en échec.

**Solution :** Passer à `db.t3.medium`.

### 3. Aurora Global Database impossible avec LabRole

**Problème :** `AWS::RDS::GlobalCluster` créé mais `AWS::RDS::DBInstance` échoue quand le cluster fait partie d'un Global Database (LabRole insuffisant).

**Solution :** Abandonner Global Database. Implémenter une réplication **application-level** (dual-write dans server.js).

### 4. Base de données `streamflex` inexistante

**Problème :** Le paramètre `DatabaseName` absent du `AWS::RDS::DBCluster` → l'API User échoue car la base `streamflex` n'existe pas. L'ajout ultérieur cause un replacement impossible (nom personnalisé).

**Solution :** Modifier `server.js` pour créer automatiquement la base via `CREATE DATABASE IF NOT EXISTS` au démarrage. Image Docker buildée et pushée vers ECR.

### 5. Cross-region RDS : connexion impossible (ETIMEDOUT)

**Problème :** Le cluster west est dans des subnets privés. Même avec `PubliclyAccessible=true`, le subnet n'a pas de route vers l'Internet Gateway → connexions depuis east ECS timeout.

**Solution documentée :** Utiliser une Lambda VPC-enabled dans west comme proxy d'écriture. Non implémenté faute de temps (contournement Learner Lab).

### 6. Health check ALM-04 (Route53)

**Problème :** Le Route53 Health Check ciblait `/health` qui n'existe pas comme règle ALB → retournait 404 → alarme en ALARM permanente.

**Solution :** Ajouter une route `/user/health` dans `server.js`, mettre à jour le health check et le frontend JS pour utiliser `/user/health`.

---

## Sécurité appliquée

| Mesure | Détail |
|---|---|
| **RDS SG** | Restreint aux subnets privés (10.0.2.0/24 + 10.0.3.0/24) au lieu de tout le VPC |
| **ECS** | `AssignPublicIp: DISABLED`, trafic entrant UNIQUEMENT depuis l'ALB SG |
| **ALB** | HTTP(80) depuis 0.0.0.0/0 (point d'entrée unique) |
| **Chiffrement** | Aurora/DynamoDB/S3 chiffrés par défaut (AES-256) |
| **Documentation** | Section 9 README : schéma des flux SG, tableaux, isolation réseau, IAM, limitations |
| **Bucket templates** | Privé (par défaut) |
| **Bucket frontend** | Public (volontaire, simule un site web) |

---

## Architecture finale

```
us-east-1 (ACTIVE)                         us-west-2 (SECOURS)
  ALB (internet-facing)                     ALB (internet-facing)
  ├── /catalog* → ECS Fargate × 2           ├── /catalog* → ECS Fargate × 0
  └── /user*    → ECS Fargate × 2           └── /user*    → ECS Fargate × 0
        │  SG: 8080/5000 depuis ALB               │  (Pilot Light)
        ▼                                        ▼
  DynamoDB Catalog            (réplication Stream → Lambda → west)
  Aurora MySQL User           (SG: 3306 subnets privés)
                               └── West: +0.0.0.0/0 (PublicRDS)

  Route53 Health Check ←→ CloudWatch Alarm → SNS → Lambda Auto-Failover
```

---

## État final

| Composant | Statut |
|---|---|
| `deploy.sh` | Automatise tout le déploiement multi-région |
| User API | ✅ CRUD + health check OK |
| Catalog API | ✅ Lecture OK |
| Frontend S3 | ✅ HTTP 200, détection client-side |
| Auto-failover | ✅ Route53 + Lambda + CloudWatch Alarm OK |
| Pilot Light west | ✅ 0 conteneurs, RDS prêt |
| Réplication DynamoDB | ✅ Stream + Lambda |
| Réplication RDS (User) | ⚠️ Code prêt, blocage réseau Learner Lab |
| Sécurité (SG, doc, IAM) | ✅ Documenté et déployé |

## Commandes utiles après déploiement

```bash
# Lister les utilisateurs
curl http://<alb-east>/user

# Créer un utilisateur
curl -X POST http://<alb-east>/user \
  -H "Content-Type: application/json" \
  -d '{"userId":"u1","username":"alice","plan":"premium"}'

# Vérifier la santé
curl http://<alb-east>/user/health

# Vérifier l'alarme
aws cloudwatch describe-alarms --alarm-names streamflex-autofailover-alarm --region us-east-1
```
