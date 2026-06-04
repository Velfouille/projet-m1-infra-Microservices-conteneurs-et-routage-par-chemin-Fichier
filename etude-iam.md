# Étude de l'utilisation d'AWS IAM dans le projet StreamFlex

## Contexte

Dans le cadre du projet **StreamFlex**, une plateforme de streaming est déployée sur AWS selon une architecture haute disponibilité répartie sur deux régions :

- **Région principale : us-east-1**
- **Région secondaire (failover) : us-west-2**

L'infrastructure repose sur :

- Amazon ECS Fargate pour les microservices
- Amazon RDS pour la gestion des utilisateurs
- Amazon DynamoDB pour le catalogue de contenus
- Amazon S3 pour l'hébergement du frontend et des fichiers CloudFormation
- Application Load Balancer (ALB)
- NAT Gateway
- Architecture multi-AZ et multi-région

L'objectif de cette étude est de proposer une stratégie de gestion des identités et des accès (IAM) garantissant la sécurité de l'infrastructure tout en respectant le principe du moindre privilège.

---

# Objectifs d'IAM

AWS Identity and Access Management (IAM) permet :

- de contrôler l'accès aux ressources AWS ;
- d'authentifier les utilisateurs et services ;
- d'appliquer le principe du moindre privilège ;
- de limiter les risques de compromission ;
- de sécuriser les opérations de déploiement et d'exploitation.

Chaque utilisateur ou service doit disposer uniquement des permissions nécessaires à son fonctionnement.

---

# Gestion des accès humains

## Administrateurs Cloud

Les administrateurs sont responsables de la gestion globale de l'infrastructure AWS.

### Permissions

- Gestion des VPC
- Gestion ECS/Fargate
- Gestion des bases de données
- Gestion des buckets S3
- Gestion CloudFront
- Consultation des logs CloudWatch
- Consultation des audits CloudTrail

### Mesures de sécurité

- MFA obligatoire
- Interdiction d'utiliser le compte root au quotidien
- Utilisation d'un rôle IAM dédié

### Rôle proposé

```text
StreamFlexAdminRole
```

---

## Équipe DevOps

Les DevOps assurent les déploiements et la maintenance applicative.

### Permissions

- Déploiement des services ECS
- Accès aux images Docker dans ECR
- Lecture des logs CloudWatch
- Gestion des stacks CloudFormation

### Restrictions

Les DevOps ne doivent pas :

- modifier les politiques IAM sensibles ;
- accéder directement aux données utilisateurs ;
- gérer les secrets de production.

### Rôle proposé

```text
StreamFlexDevOpsRole
```

---

# Gestion des accès applicatifs

## Service Catalog

Le microservice Catalog est déployé sur ECS Fargate.

### Besoins

- Lecture du catalogue vidéo
- Mise à jour des informations du catalogue
- Écriture des logs applicatifs

### Ressources concernées

- DynamoDB Catalog
- CloudWatch Logs

### Permissions recommandées

```json
{
  "Effect": "Allow",
  "Action": [
    "dynamodb:GetItem",
    "dynamodb:PutItem",
    "dynamodb:UpdateItem",
    "dynamodb:Query",
    "dynamodb:Scan"
  ],
  "Resource": "arn:aws:dynamodb:*:*:table/Catalog"
}
```

### Rôle proposé

```text
StreamFlexFargateCatalogRole
```

---

## Service User

Le microservice User est déployé sur ECS Fargate.

### Besoins

- Gestion des comptes utilisateurs
- Accès à la base de données relationnelle
- Lecture des secrets de connexion

### Ressources concernées

- Amazon RDS User
- AWS Secrets Manager
- CloudWatch Logs

### Permissions recommandées

```json
{
  "Effect": "Allow",
  "Action": [
    "secretsmanager:GetSecretValue"
  ],
  "Resource": "*"
}
```

### Rôle proposé

```text
StreamFlexFargateUserRole
```

---

# Gestion des accès S3

## Bucket Frontend

Le frontend est stocké dans un bucket S3.

### Bonnes pratiques

- Interdire l'accès public direct au bucket
- Utiliser CloudFront comme point d'entrée unique
- Activer le chiffrement côté serveur
- Limiter les permissions de lecture à CloudFront

### Accès autorisés

| Service | Permission |
|----------|-----------|
| CloudFront | Lecture |
| Administrateurs | Lecture / Écriture |
| DevOps | Déploiement |

---

## Bucket CloudFormation

Le bucket contenant les templates CloudFormation doit rester privé.

### Accès autorisés

| Service | Permission |
|----------|-----------|
| DevOps | Lecture / Écriture |
| Administrateurs | Lecture / Écriture |
| Services applicatifs | Aucun accès |

---

# Gestion des secrets

Les identifiants de connexion aux bases de données ne doivent jamais être stockés :

- dans le code source ;
- dans les images Docker ;
- dans les variables d'environnement non sécurisées.

## Solution recommandée

Utilisation de :

- AWS Secrets Manager
- AWS KMS pour le chiffrement

### Exemple

```text
Secret :
streamflex/rds/user-db
```

Accessible uniquement par :

```text
StreamFlexFargateUserRole
```

---

# Gestion du failover multi-région

L'architecture prévoit une bascule de :

```text
us-east-1 → us-west-2
```

en cas d'indisponibilité de la région principale.

Un rôle spécifique doit être créé afin de contrôler les opérations de reprise d'activité.

## Permissions du rôle

- Consultation des métriques CloudWatch
- Activation des ressources de secours
- Mise à jour des configurations réseau
- Gestion du routage DNS
- Déclenchement des procédures de failover

### Rôle proposé

```text
StreamFlexFailoverRole
```

---

# Surveillance et audit

## AWS CloudTrail

CloudTrail permet de :

- tracer toutes les actions IAM ;
- identifier les modifications de configuration ;
- faciliter les audits de sécurité.

---

## AWS CloudWatch

CloudWatch permet :

- la surveillance des accès ;
- la détection d'activités anormales ;
- le suivi des erreurs applicatives.

---

## IAM Access Analyzer

IAM Access Analyzer permet :

- d'identifier les ressources exposées ;
- de détecter les permissions excessives ;
- d'améliorer la conformité de sécurité.

---

# Récapitulatif des rôles IAM

| Rôle IAM | Utilisation |
|-----------|-------------|
| StreamFlexAdminRole | Administration complète de l'infrastructure |
| StreamFlexDevOpsRole | Déploiement et maintenance |
| StreamFlexFargateCatalogRole | Accès DynamoDB Catalog |
| StreamFlexFargateUserRole | Accès DynamoDB User |
| StreamFlexFailoverRole | Gestion de la reprise d'activité |
| CloudFront Access Role | Lecture sécurisée du frontend S3 |

---

# Bonnes pratiques de sécurité

- Utilisation systématique du MFA
- Interdiction d'utiliser le compte root pour les opérations courantes
- Principe du moindre privilège
- Utilisation de rôles IAM plutôt que de clés d'accès permanentes
- Chiffrement des données avec AWS KMS
- Stockage des secrets dans Secrets Manager
- Journalisation des actions via CloudTrail
- Surveillance continue via CloudWatch
- Audit régulier avec IAM Access Analyzer

---

# Conclusion

Dans l'architecture StreamFlex, IAM joue un rôle central dans la sécurisation des ressources AWS et dans la gestion des accès humains comme applicatifs.

L'utilisation de rôles IAM dédiés pour chaque service ECS Fargate, associée à une gestion stricte des permissions, permet de limiter la surface d'attaque tout en garantissant le bon fonctionnement de l'application.

Cette approche est particulièrement adaptée à une architecture multi-région avec mécanisme de failover, où la maîtrise des accès et la traçabilité des actions constituent des éléments essentiels de la résilience et de la sécurité de la plateforme.
