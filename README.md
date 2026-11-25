# TP – Sécurisation d'un conteneur Docker (Quiz Docker)

Application : Quiz Docker (`dockerfile-exercice2`), construite avec Vite puis servie en statique.

| Fichier | Rôle |
|---|---|
| `Dockerfile.initial` | Dockerfile de l'exercice 2 (avant sécurisation) |
| `Dockerfile` | Dockerfile sécurisé (multi-stage, non-root) |
| `.dockerignore` | Fichiers exclus du contexte de build |
| `trivy-initial.txt` | Scan Trivy de `quiz-docker:initial` |
| `trivy-secure.txt` | Scan Trivy de `quiz-docker:secure` |

Image publiée : `TON_VRAI_ID_DOCKER/quiz-docker:secure` sur Docker Hub

Environnement : macOS (Apple Silicon, arm64), Docker 29.2.0, scans Trivy du 25/11/2026.

---

## Mission 1 – Audit de l'image initiale

### Dockerfile initial
```dockerfile
FROM node:18-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm install
COPY . .
RUN npm run build && npm install -g serve
EXPOSE 3000
CMD ["serve", "-s", "dist"]
```

### Commandes utilisées
```bash
docker build -t quiz-docker:initial -f Dockerfile.initial .
docker run -d --name quiz-initial -p 8091:3000 quiz-docker:initial
docker run --rm quiz-docker:initial cat /etc/os-release
docker exec quiz-initial id
docker images quiz-docker:initial
docker history quiz-docker:initial
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$PWD":/out \
  aquasec/trivy image --scanners vuln -f table -o /out/trivy-initial.txt quiz-docker:initial
```

### État initial et risques

| Critère | État initial | Risque |
|---|---|---|
| Image de base | `node:18-alpine` (Alpine 3.21.3, Node 18.20.8) | Node 18 en fin de vie, Alpine 3.21 plus maintenu : plus de correctifs de sécurité |
| Tag | `18-alpine` (tag flottant) | Build non reproductible |
| Utilisateur | root (uid 0), pas d'instruction `USER` | Si l'appli est compromise, l'attaquant est root dans le conteneur |
| Taille | 240 MB (59,5 MB compressée) | Plus de composants = surface d'attaque plus grande |
| Couches lourdes | Node (120 MB), `npm install` (28,8 MB), build + serve (16,4 MB) | Outils de build livrés en production |
| Outils présents | node, npm, npx, yarn, apk, wget, Vite, esbuild | Permettent d'installer ou d'exécuter des outils dans le conteneur |
| Fichiers inutiles | Sources, `node_modules`, Dockerfile et README copiés dans `/app` | Fuite d'informations, image plus lourde |
| `.dockerignore` | Absent | Risque de copier `.git`, `.env` ou des secrets dans l'image |
| Multi-stage | Non | Tout l'environnement de build reste dans l'image finale |
| Limites ressources / privilèges | Aucune | DoS possible (RAM, CPU, processus), capabilities Linux par défaut |
| Socket Docker | Non monté | OK |
| CVE (Trivy) | 264 : 5 critiques, 83 élevées, 130 moyennes, 45 faibles, 1 inconnue | Vulnérabilités connues exploitables |

### Questions
- **L'image est-elle adaptée à la production ?** Non. Node 18 et Alpine 3.21 ne sont plus maintenus, l'application tourne en root, l'image contient tous les outils de build et 88 CVE critiques ou élevées.
- **Quels composants sont nécessaires ?** Après `npm run build`, l'application n'est que du statique (`dist/` : HTML, CSS, JS). Node, npm et Vite servent uniquement à construire. Pour l'exécuter, un serveur web suffit.
- **Quels risques ?** Exécution en root, composants en fin de vie avec des CVE, surface d'attaque inutile (npm, apk, sources), pas de limites de ressources, tag non figé, pas de `.dockerignore`.
- **Améliorations prioritaires :** 1) multi-stage avec un runtime minimal, 2) utilisateur non-root, 3) image de base à jour avec un tag précis, 4) `.dockerignore`, 5) limites et restrictions au lancement, 6) scans réguliers.

---

## Mission 2 – Sécurisation

### Dockerfile sécurisé
```dockerfile
# ---------- Étape 1 : build ----------
FROM node:22.23.5-alpine3.24 AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN npm run build

# ---------- Étape 2 : runtime ----------
FROM nginxinc/nginx-unprivileged:1.30.6-alpine3.24
USER root
RUN apk upgrade --no-cache \
 && apk del --no-cache curl \
 && rm -f /sbin/apk \
 && rm -rf /var/cache/apk/*
COPY --from=build --chown=root:root --chmod=755 /app/dist /usr/share/nginx/html
USER 101
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -q --spider http://127.0.0.1:8080/ || exit 1
```

### Lancement du conteneur
```bash
docker build -t quiz-docker:secure .
docker run -d --name quiz-secure -p 8092:8080 \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop ALL --security-opt no-new-privileges:true \
  --memory 128m --cpus 0.5 --pids-limit 100 \
  --restart unless-stopped quiz-docker:secure
```

### Recommandations appliquées

| Recommandation | Mise en œuvre |
|---|---|
| Images de base minimales | Build : `node:22.23.5-alpine3.24`, runtime : `nginxinc/nginx-unprivileged:1.30.6-alpine3.24` |
| Pas de root | Image nginx-unprivileged, `USER 101` (nginx), port 8080 non privilégié |
| `.dockerignore` | Exclut `node_modules`, `dist`, `.git`, `.env*`, Dockerfile, README, logs, fichiers IDE/macOS |
| Tags précis | Versions de Node, nginx et Alpine figées |
| COPY plutôt que ADD | Aucun `ADD` |
| Limiter ressources et privilèges | `--memory 128m`, `--cpus 0.5`, `--pids-limit 100`, `--cap-drop ALL`, `no-new-privileges`, `--read-only` |
| Multi-stage | Étape `build` (Node + Vite), seul `dist/` est copié dans l'image finale |
| Socket Docker | Jamais monté dans le conteneur |
| Vérification | Scans Trivy + `HEALTHCHECK` |
| Durcissement en plus | `apk upgrade`, suppression de `curl` et du binaire `apk`, fichiers du site en lecture seule pour nginx |

Remarque : un premier essai supprimait aussi `/lib/apk`. Trivy ne voyait alors plus aucun paquet et affichait 0 CVE, ce qui était faux. La base des paquets est donc conservée pour que l'image reste auditable.

---

## Mission 3 – Comparaison

### Vérifications
```bash
docker exec quiz-secure id                       # uid=101(nginx)
docker exec quiz-secure sh -c 'which node npm apk curl; echo fin'   # rien trouvé
docker inspect quiz-secure --format '{{.State.Health.Status}}'      # healthy
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$PWD":/out \
  aquasec/trivy image --scanners vuln -f table -o /out/trivy-secure.txt quiz-docker:secure
docker tag quiz-docker:secure TON_VRAI_ID_DOCKER/quiz-docker:secure
docker push TON_VRAI_ID_DOCKER/quiz-docker:secure
```

### Tableau comparatif

| Critère | `quiz-docker:initial` | `quiz-docker:secure` |
|---|---|---|
| Image de base | `node:18-alpine` (Alpine 3.21.3) | `nginx-unprivileged:1.30.6-alpine3.24` (Alpine 3.24.2) |
| Tag précis | Non | Oui |
| Taille disque | 240 MB | 109 MB (-55 %) |
| Taille compressée | 59,5 MB | 31,3 MB (-47 %) |
| Utilisateur | root (uid 0) | nginx (uid 101) |
| Outils de dev (node, npm, yarn, Vite) | Présents | Absents |
| Gestionnaire de paquets / curl | apk présent | Supprimés |
| Code source dans l'image | Oui | Non (seulement `dist/`) |
| Serveur | `serve` (Node) | nginx |
| `.dockerignore` | Non | Oui |
| Multi-stage build | Non | Oui |
| Limitation des ressources | Non | 128 MB RAM, 0,5 CPU, 100 processus |
| Restriction des privilèges | Non | cap-drop ALL, no-new-privileges, système de fichiers en lecture seule |
| Accès socket Docker | Non | Non |
| Healthcheck | Non | Oui (healthy) |
| CVE critiques | 5 | 4 |
| CVE élevées | 83 | 2 |
| CVE moyennes | 130 | 3 |
| CVE faibles | 45 | 0 |
| **Total CVE** | **264** | **9 (-97 %)** |

### Questions d'analyse
- **Modifications les plus significatives :** le multi-stage avec un runtime nginx Alpine à jour. On ne livre plus Node, npm ni les dépendances de build, ce qui fait passer de 264 à 9 CVE. Ensuite, le passage en non-root.
- **La taille a-t-elle diminué ? Pourquoi ?** Oui, de 240 MB à 109 MB. L'image finale ne contient plus Node (120 MB), les `node_modules` ni les sources : seulement nginx, Alpine et les fichiers statiques de `dist/`.
- **Dockerfile ou exécution ?**
  - Dans le Dockerfile : image minimale, tags précis, `USER` non-root, `.dockerignore`, `COPY` au lieu de `ADD`, multi-stage, suppression des outils inutiles.
  - À l'exécution : `--memory`, `--cpus`, `--pids-limit`, `--cap-drop`, `no-new-privileges`, `--read-only`, ne pas monter le socket Docker.
  - Les deux : vérifier régulièrement la sécurité avec des scans.
- **L'image est-elle totalement sécurisée ?** Non. Il reste 9 CVE, dont 4 critiques, dans des paquets de l'image de base. Certaines n'ont pas encore de correctif, ce qui explique qu'elles restent malgré `apk upgrade`. De nouvelles CVE sortent tous les jours, et la sécurité dépend aussi de l'hôte, du réseau et des options de lancement : sans les options de `docker run`, une partie du durcissement disparaît.
- **Mesures complémentaires pour la production :** scan automatique dans la CI avec blocage sur les CVE critiques ou élevées, rebuild régulier pour récupérer les correctifs, épinglage des images par digest, signature des images (Cosign), génération d'un SBOM, Hadolint et Dockle sur le Dockerfile, HTTPS via un reverse proxy, réseau Docker dédié, Docker rootless ou user namespaces, profils seccomp/AppArmor, logs centralisés et supervision, Docker Bench for Security sur l'hôte, ou passage à une Docker Hardened Image (mission 4).

---

## Mission 4 – Docker Hardened Image

À compléter après le lab : https://docs.docker.com/guides/lab-dhi-node/
