# Cahier des charges — Invoice Clear

**Collecteur de factures open source, local-first, pour macOS**


|                     |                                                                                                       |
| ------------------- | ----------------------------------------------------------------------------------------------------- |
| Nom de travail      | Invoice Clear (à arbitrer — cf. §12)                                                                  |
| Version du document | 0.1 — 28 août 2026                                                                                    |
| Auteur              | Clément de Louvencourt                                                                                |
| Statut              | Brouillon pour discussion                                                                             |
| Référence marché    | Invoice Radar (propriétaire, Autriche), invoicefetcher® (Allemagne), GetMyInvoices, Invoice Collector |


---

## 1. Contexte et objectifs

### 1.1 Le problème

Une part croissante des factures fournisseurs n'arrive jamais par mail : elle reste derrière un login sur un portail (AWS, Google Ads, Meta, OVH, Free Pro, URSSAF, Amazon Business…). Chaque mois, l'utilisateur — ou son cabinet — répète le même parcours manuel : se connecter, passer la 2FA, trouver l'historique de facturation, télécharger, renommer, classer, transmettre. Le temps consommé croît linéairement avec le nombre de fournisseurs et avec le nombre de dossiers pour un cabinet.

La réforme française de la facturation électronique ne résout ce problème que partiellement : elle couvre le B2B domestique assujetti, pas les éditeurs internationaux (SaaS, cloud, régies publicitaires), pas le B2C, pas les flux exclus du périmètre. Le stock de factures « hors e-facture » restera à collecter manuellement. *(Le calendrier exact de la réforme est à revérifier au moment du cadrage — il a déjà été décalé plusieurs fois.)*

### 1.2 Objectif du produit

Une application macOS qui, sur la machine de l'utilisateur, se connecte à ses comptes fournisseurs, télécharge les factures nouvelles depuis la dernière exécution, en extrait les métadonnées (date, numéro, montant, devise, TVA), les nomme selon une convention, et les dépose là où l'utilisateur les attend (dossier, GED, comptable, webhook).

### 1.3 Ce qui différencie ce projet des solutions existantes


| Axe                   | Concurrence                                            | Ce projet                                                               |
| --------------------- | ------------------------------------------------------ | ----------------------------------------------------------------------- |
| Code de l'application | Fermé (Invoice Radar ouvre ses *plugins*, pas son app) | Intégralement open source                                               |
| Modèle                | SaaS ou licence payante                                | Auto-hébergé / local, gratuit                                           |
| Traitement            | Local pour Invoice Radar, cloud pour GetMyInvoices     | Local, sans backend obligatoire                                         |
| Extraction IA         | API cloud propriétaire                                 | Optionnelle, débrayable, modèle local possible                          |
| Écosystème            | Plugins communautaires sur GitHub                      | Idem, mais licence libre sur toute la chaîne                            |
| Ancrage               | DE / AT                                                | FR / UE en priorité (fournisseurs FR sous-couverts par les concurrents) |


**Le vrai différenciateur exploitable n'est pas technique mais éditorial** : la couverture des fournisseurs français et européens (Free Pro, OVH, Scaleway, Qonto, Shine, URSSAF, Chorus, SFR Business, Boulanger Pro, Leroy Merlin Pro, Metro…) est aujourd'hui médiocre chez les acteurs germanophones. C'est là que la communauté peut créer de la valeur vite.

### 1.4 Objectifs mesurables


| Objectif                     | Indicateur                                   | Cible v1.0                                      |
| ---------------------------- | -------------------------------------------- | ----------------------------------------------- |
| Réduire le temps de collecte | Minutes pour 30 factures / 10 sources        | &lt; 6 min contre ~70 min manuellement          |
| Fiabilité                    | Taux d'exécutions réussies par source active | &gt; 90 % sur 30 jours glissants                |
| Écosystème                   | Plugins fusionnés dans le dépôt public       | 60 à la sortie, dont 25 fournisseurs FR         |
| Effort de contribution       | Temps médian pour écrire un plugin simple    | &lt; 30 min avec le mode développeur            |
| Confiance                    | Aucune donnée sortante par défaut            | 0 requête réseau hors domaines des fournisseurs |


---

## 2. Périmètre

### 2.1 Dans le périmètre v1.0

- Application macOS native (Apple Silicon + Intel), signée et notarisée.
- Moteur d'automatisation navigateur exécutant des plugins déclaratifs.
- Coffre-fort d'identifiants adossé au Trousseau macOS, avec support TOTP.
- Collecte depuis boîtes mail (IMAP, Gmail OAuth, Microsoft Graph).
- Import manuel de PDF par glisser-déposer.
- Bibliothèque de documents locale avec déduplication et recherche.
- Extraction des métadonnées : règles du plugin d'abord, OCR/heuristiques ensuite, LLM en dernier recours et sur option explicite.
- Exports : dossier local, Paperless-ngx, webhook, e-mail, CSV/JSON.
- Planification (exécution mensuelle, hebdomadaire, manuelle) et notifications.
- Dépôt public de plugins avec validation automatique par CI.
- Mode développeur de plugin (éditeur, exécution pas-à-pas, inspecteur DOM).

### 2.2 Hors périmètre v1.0, prévu ensuite

- Windows et Linux (l'architecture doit le permettre sans réécriture — cf. §6).
- Synchronisation multi-appareils et mode équipe.
- Application mobile de scan de reçus papier.
- Multi-dossiers pour cabinets comptables (gestion de N clients cloisonnés).
- Génération Factur-X à partir d'un PDF nu.
- Connecteurs comptables FR (Pennylane, Tiime, Sage, Cegid, Qonto).

### 2.3 Explicitement exclu

- Tout backend obligatoire, tout compte utilisateur, toute télémétrie activée par défaut.
- Le stockage des identifiants ou des documents sur un serveur tiers.
- La facturation *sortante* (émission de factures) : c'est un autre produit, déjà bien servi.
- Le contournement actif de protections anti-bot (captcha solving, empreintes falsifiées) — cf. §8.4.

---

## 3. Utilisateurs et cas d'usage

### 3.1 Personas

**P1 — Le freelance / dirigeant de TPE.** 15 à 40 fournisseurs, majoritairement SaaS. Veut un dossier propre à envoyer à son comptable le 5 du mois. Sensible au prix et à la confidentialité. Compétence technique moyenne à élevée.

**P2 — Le contributeur technique.** Utilise le produit et écrit des plugins pour ses propres fournisseurs manquants. C'est le moteur de l'écosystème : tout doit être optimisé pour qu'il réussisse son premier plugin en moins d'une heure.

**P3 — Le collaborateur de cabinet comptable.** N dossiers clients, contraintes de traçabilité et de cloisonnement fortes. Cible v2, mais l'architecture ne doit pas l'interdire (notion d'espace/entité dès le modèle de données).

### 3.2 Cas d'usage principaux


| ID    | Cas d'usage                                                  | Acteur  |
| ----- | ------------------------------------------------------------ | ------- |
| UC-01 | Ajouter une source depuis le catalogue et s'y authentifier   | P1      |
| UC-02 | Lancer une collecte sur toutes les sources actives           | P1      |
| UC-03 | Reprendre une source en échec (session expirée, 2FA)         | P1      |
| UC-04 | Consulter, filtrer, corriger les métadonnées d'un document   | P1      |
| UC-05 | Exporter la période vers un dossier / une GED / le comptable | P1, P3  |
| UC-06 | Écrire, tester et soumettre un plugin                        | P2      |
| UC-07 | Installer un plugin non officiel depuis un dossier local     | P2      |
| UC-08 | Importer des PDF existants pour compléter les archives       | P1      |
| UC-09 | Programmer une collecte mensuelle automatique                | P1      |
| UC-10 | Cloisonner plusieurs entités juridiques                      | P3 (v2) |


---

## 4. Exigences fonctionnelles

Priorités : **M** = must (v1.0), **S** = should (v1.x), **C** = could (v2).

### F1 — Gestion des sources


| ID   | Exigence                                                                                             | Prio |
| ---- | ---------------------------------------------------------------------------------------------------- | ---- |
| F1.1 | Catalogue des plugins disponibles, recherche par nom et par pays                                     | M    |
| F1.2 | Ajout d'une source = choix du plugin + saisie de la configuration déclarée par son `configSchema`    | M    |
| F1.3 | Activation / désactivation / suppression d'une source, avec purge optionnelle des identifiants       | M    |
| F1.4 | État par source : dernière exécution, résultat, nombre de documents, prochaine exécution             | M    |
| F1.5 | Plusieurs instances d'un même plugin (deux comptes AWS, par exemple)                                 | M    |
| F1.6 | Signalement en un clic d'un plugin cassé, pré-remplissant une issue GitHub sans données personnelles | S    |


### F2 — Moteur d'exécution


| ID   | Exigence                                                                                                                | Prio |
| ---- | ----------------------------------------------------------------------------------------------------------------------- | ---- |
| F2.1 | Exécution d'un plugin déclaratif dans un contexte navigateur isolé par source                                           | M    |
| F2.2 | Persistance des cookies et du stockage local par source, pour éviter de rejouer la 2FA à chaque fois                    | M    |
| F2.3 | Mode visible (authentification interactive) et mode invisible (collecte)                                                | M    |
| F2.4 | Exécution parallèle bornée (par défaut 2 sources simultanées, configurable)                                             | S    |
| F2.5 | Reprise incrémentale : ne retélécharger que les documents postérieurs au dernier succès                                 | M    |
| F2.6 | Délai d'expiration par étape et par exécution, avec arrêt propre                                                        | M    |
| F2.7 | Journal d'exécution horodaté, consultable, exportable, expurgé des secrets                                              | M    |
| F2.8 | Capture d'écran automatique au moment de l'échec, stockée localement, jamais transmise                                  | S    |
| F2.9 | Politique de nouvelle tentative : 2 essais, backoff exponentiel, pas de nouvelle tentative sur échec d'authentification | M    |


### F3 — Authentification et 2FA


| ID   | Exigence                                                                                                                  | Prio |
| ---- | ------------------------------------------------------------------------------------------------------------------------- | ---- |
| F3.1 | Authentification interactive : le navigateur s'affiche, l'utilisateur se connecte lui-même, l'app détecte l'état connecté | M    |
| F3.2 | Remplissage automatique optionnel des champs identifiant / mot de passe, configurable par plugin                          | M    |
| F3.3 | Génération de codes TOTP depuis un secret stocké dans le coffre                                                           | M    |
| F3.4 | Détection de session expirée et demande de réauthentification, sans faire échouer les autres sources                      | M    |
| F3.5 | Choix par source : mémoriser les identifiants, ou les demander à chaque exécution                                         | M    |
| F3.6 | Support OAuth pour les fournisseurs qui l'exposent (Google, Microsoft), à préférer au scraping                            | S    |
| F3.7 | Aucun secret n'est jamais écrit dans les journaux, les captures d'écran ou les rapports d'anomalie                        | M    |


### F4 — Coffre-fort d'identifiants


| ID   | Exigence                                                                                           | Prio |
| ---- | -------------------------------------------------------------------------------------------------- | ---- |
| F4.1 | Stockage des secrets dans le Trousseau macOS, un item par source                                   | M    |
| F4.2 | Accès aux secrets conditionné au déverrouillage de la session ; option Touch ID à chaque exécution | S    |
| F4.3 | Les secrets ne transitent jamais en clair hors du processus qui en a besoin                        | M    |
| F4.4 | Suppression d'une source = suppression des secrets associés, sans résidu                           | M    |
| F4.5 | Export chiffré / import du coffre pour migration de machine                                        | C    |


### F5 — Collecte e-mail


| ID   | Exigence                                                                                         | Prio |
| ---- | ------------------------------------------------------------------------------------------------ | ---- |
| F5.1 | Connexion IMAP (mot de passe d'application), Gmail via OAuth, Outlook via Graph                  | M    |
| F5.2 | Analyse des pièces jointes PDF et détection heuristique des factures                             | M    |
| F5.3 | Détection des liens « voir votre facture » et récupération du document derrière                  | S    |
| F5.4 | Filtres configurables : dossiers, expéditeurs, plage de dates, mots-clés                         | M    |
| F5.5 | Ne jamais modifier la boîte source (lecture seule stricte, pas de suppression ni de déplacement) | M    |


### F6 — Extraction des métadonnées


| ID   | Exigence                                                                                                                                  | Prio |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------- | ---- |
| F6.1 | Priorité aux valeurs déclarées par le plugin (les plus fiables)                                                                           | M    |
| F6.2 | Repli sur extraction du texte du PDF + expressions régulières multilingues (FR/EN/DE)                                                     | M    |
| F6.3 | OCR pour les PDF image (Vision framework macOS, sans dépendance externe)                                                                  | S    |
| F6.4 | Repli LLM optionnel, désactivé par défaut, avec choix explicite du fournisseur (API ou modèle local) et affichage de ce qui sera transmis | S    |
| F6.5 | Champs extraits : émetteur, numéro, date, montant TTC, montant HT, TVA, devise, numéro de TVA intracom                                    | M    |
| F6.6 | Édition manuelle de tout champ, avec marquage de la valeur comme vérifiée par l'humain                                                    | M    |
| F6.7 | Indicateur de confiance par champ et signalement visuel des extractions douteuses                                                         | S    |


### F7 — Bibliothèque de documents


| ID   | Exigence                                                                                           | Prio |
| ---- | -------------------------------------------------------------------------------------------------- | ---- |
| F7.1 | Stockage des fichiers dans un dossier choisi par l'utilisateur, structure lisible sans l'app       | M    |
| F7.2 | Base d'index SQLite séparée des fichiers, reconstructible par re-scan du dossier                   | M    |
| F7.3 | Déduplication par empreinte SHA-256 du contenu **et** par couple (source, identifiant de document) | M    |
| F7.4 | Convention de nommage paramétrable par gabarit : `{date}_{fournisseur}_{numero}_{montant}.pdf`     | M    |
| F7.5 | Recherche plein texte sur les métadonnées et sur le texte extrait                                  | S    |
| F7.6 | Filtres par période, source, type, statut d'export                                                 | M    |
| F7.7 | Aucune suppression de fichier sans confirmation explicite ; pas de suppression automatique         | M    |


### F8 — Exports


| ID   | Exigence                                                                         | Prio |
| ---- | -------------------------------------------------------------------------------- | ---- |
| F8.1 | Export dossier avec arborescence paramétrable (`{annee}/{mois}/`)                | M    |
| F8.2 | Webhook HTTP POST avec charge utile JSON documentée et fichier en pièce jointe   | M    |
| F8.3 | Envoi par e-mail (lot mensuel au comptable)                                      | M    |
| F8.4 | Paperless-ngx via son API                                                        | S    |
| F8.5 | Export CSV / JSON du registre pour rapprochement                                 | M    |
| F8.6 | Connecteurs comptables FR via la même interface d'export                         | C    |
| F8.7 | Idempotence : un document déjà exporté n'est pas renvoyé, sauf demande explicite | M    |


### F9 — Planification et notifications


| ID   | Exigence                                                                             | Prio |
| ---- | ------------------------------------------------------------------------------------ | ---- |
| F9.1 | Déclenchement manuel, quotidien, hebdomadaire ou mensuel, par source ou global       | M    |
| F9.2 | Exécution en arrière-plan si l'app est ouverte ; pas de démon système en v1          | M    |
| F9.3 | Notification macOS de fin d'exécution : n documents récupérés, m sources en échec    | M    |
| F9.4 | Rapport d'exécution consultable, avec accès direct aux sources en échec              | M    |
| F9.5 | Aucune exécution automatique tant que l'utilisateur ne l'a pas activée explicitement | M    |


### F10 — Écosystème de plugins


| ID    | Exigence                                                                                                                  | Prio |
| ----- | ------------------------------------------------------------------------------------------------------------------------- | ---- |
| F10.1 | Plugins déclaratifs en JSON validés par un JSON Schema publié                                                             | M    |
| F10.2 | Chargement des plugins officiels depuis un index signé, mis à jour sans réinstaller l'app                                 | M    |
| F10.3 | Installation d'un plugin local depuis un dossier, pour le développement                                                   | M    |
| F10.4 | Versionnage sémantique par plugin ; l'app refuse un plugin exigeant une version de moteur supérieure à la sienne          | M    |
| F10.5 | Mode développeur : éditeur avec autocomplétion issue du schéma, exécution pas-à-pas, inspection du DOM, rejeu d'une étape | M    |
| F10.6 | Bandeau d'avertissement à l'installation d'un plugin non officiel, expliquant ce que le plugin peut faire                 | M    |
| F10.7 | Restriction des domaines : un plugin ne peut naviguer que vers les domaines qu'il déclare                                 | M    |
| F10.8 | Chaque plugin déclare s'il utilise du JavaScript arbitraire ; l'interface le signale                                      | M    |


---

## 5. Spécification du format de plugin

### 5.1 Principe

Un plugin est un **document JSON déclaratif**, pas du code. C'est le choix structurant du projet : il rend la revue de contribution possible pour un mainteneur non expert, il permet la validation automatique, et il limite la surface d'attaque. Le format d'Invoice Radar est une base de départ éprouvée et son schéma est public — s'en inspirer est légitime, le copier ne l'est pas nécessairement selon la licence du dépôt : **à vérifier avant de démarrer** (le README ne porte pas de licence explicite au moment de la rédaction de ce document).

### 5.2 Structure

```jsonc
{
  "$schema": "https://<domaine>/schema/v1.json",
  "id": "ovh",                    // unique, minuscules, stable dans le temps
  "name": "OVHcloud",
  "description": "Factures OVHcloud (particuliers et pro).",
  "homepage": "https://ovh.com",
  "country": ["FR", "EU"],        // ajout par rapport à Invoice Radar : facilite le tri par marché
  "engine": ">=1.0.0",            // version minimale du moteur
  "allowedDomains": ["ovh.com", "*.ovh.com"],  // ajout : bac à sable réseau
  "configSchema": { },            // champs demandés à l'utilisateur
  "autofill": true,               // ou objet de personnalisation par champ
  "checkAuth":  [ /* étapes */ ], // se termine par une étape de vérification
  "startAuth":  [ /* étapes */ ],
  "getConfigOptions": [ /* optionnel */ ],
  "getDocuments":   [ /* étapes */ ]
}

```

### 5.3 Vocabulaire d'étapes minimal (v1)


| Famille       | Actions                                                                               |
| ------------- | ------------------------------------------------------------------------------------- |
| Navigation    | `navigate`, `waitForURL`, `waitForElement`, `waitForNavigation`, `waitForNetworkIdle` |
| Interaction   | `click`, `type`, `dropdownSelect`, `runJs`                                            |
| Vérification  | `checkElementExists`, `checkURL`, `runJs`                                             |
| Extraction    | `extract`, `extractAll` (avec `forEach`), `extractNetworkResponse`                    |
| Document      | `downloadPdf`, `waitForPdfDownload`, `printPdf`, `downloadBase64Pdf`                  |
| Logique       | `if` / `then` / `else`, `sleep`                                                       |
| Configuration | `exposeOption`                                                                        |


Substitution de variables par `{{variable.champ}}`. Objet `document` normalisé : `id` et `date` obligatoires, `total` recommandé, `type` et `metadata` optionnels.

### 5.4 Écarts assumés par rapport au modèle Invoice Radar

1. `allowedDomains` **obligatoire.** Sans lui, un plugin communautaire peut naviguer n'importe où avec les cookies de session de l'utilisateur. C'est le point de sécurité le plus important du projet.
2. `runJs` **sous drapeau.** Tout plugin en contenant est marqué comme « nécessitant une revue humaine renforcée » et ne peut pas être fusionné par la CI seule.
3. `country` **et** `tags` pour rendre le catalogue navigable par marché.
4. **Tests d'accompagnement.** Chaque plugin peut fournir un jeu de captures HTML anonymisées permettant à la CI de vérifier que les sélecteurs d'extraction fonctionnent encore, sans compte réel.

### 5.5 Cycle de vie d'un plugin

```
Rédaction locale → test en mode dev → PR sur le dépôt
   → CI : validation schéma + lint + vérif domaines + détection de secrets
   → revue humaine (obligatoire si runJs)
   → merge → publication dans l'index signé → disponible dans l'app sous 24 h

```

Un plugin en échec chez plusieurs utilisateurs est marqué **dégradé** dans le catalogue. Un plugin sans mainteneur et cassé depuis 90 jours passe en **archivé** et n'est plus proposé à l'installation.

---

## 6. Architecture technique

### 6.1 Contrainte dimensionnante

Le produit a besoin d'un **moteur de navigateur pilotable, avec sessions persistantes, capable de rendre des portails modernes et d'imprimer en PDF**. C'est ce choix qui détermine tout le reste.


| Option                                       | Avantages                                                                  | Inconvénients                                                                                         | Verdict                                         |
| -------------------------------------------- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| Swift natif + `WKWebView`                    | App légère (~20 Mo), intégration macOS parfaite, Trousseau natif           | Pilotage limité, pas d'interception réseau propre, portage Windows/Linux impossible                   | Rejeté : le portage futur serait une réécriture |
| Electron + Playwright/Chromium embarqué      | Contrôle total, écosystème mature, multiplateforme immédiat                | Binaire de 200 à 400 Mo, empreinte mémoire élevée, notarisation plus lourde                           | Repli acceptable                                |
| **Tauri (Rust) + Chromium embarqué via CDP** | Interface légère, cœur Rust, contrôle total du navigateur, multiplateforme | Deux moteurs de rendu à embarquer (WebView pour l'UI, Chromium pour le scraping), complexité de build | **Recommandé**                                  |


Le point à trancher tôt : embarquer Chromium ou réutiliser un Chrome/Chromium déjà installé. Embarquer garantit la reproductibilité (les sélecteurs des plugins dépendent du rendu), au prix de la taille du binaire. **Recommandation : embarquer, avec téléchargement du runtime au premier lancement plutôt que dans le paquet.**

### 6.2 Composants

```
┌──────────────────────────────────────────────────┐
│  Interface (Tauri WebView)                       │
│  Catalogue · Sources · Bibliothèque · Réglages   │
└────────────────────┬─────────────────────────────┘
                     │ IPC typé
┌────────────────────▼─────────────────────────────┐
│  Cœur (Rust)                                     │
│  ┌────────────┐ ┌─────────────┐ ┌──────────────┐ │
│  │Ordonnanceur│ │Moteur plugin│ │ Coffre-fort  │ │
│  │  (jobs)    │ │ (interprète)│ │ (Trousseau)  │ │
│  └────────────┘ └──────┬──────┘ └──────────────┘ │
│  ┌────────────┐ ┌──────▼──────┐ ┌──────────────┐ │
│  │ Extracteur │ │ Pilote CDP  │ │ Exportateurs │ │
│  │ (regex/OCR │ │ + filtre de │ │ (dossier,    │ │
│  │  /LLM opt.)│ │  domaines   │ │  webhook, …) │ │
│  └────────────┘ └──────┬──────┘ └──────────────┘ │
└────────────────────────┼─────────────────────────┘
          ┌──────────────▼──────────────┐
          │ Chromium (profil par source)│
          └─────────────────────────────┘
                     │
   SQLite (index) · Dossier documents · Trousseau (secrets)

```

### 6.3 Modèle de données (esquisse)

`entity` (v2, cloisonnement) → `source` (instance de plugin) → `run` (exécution) → `document` → `export_record`.

Champs clés de `document` : `id`, `source_id`, `plugin_document_id`, `sha256`, `path`, `issuer`, `number`, `issued_on`, `total_cents`, `currency`, `vat_cents`, `type`, `confidence`, `verified_by_human`, `created_at`.

Contrainte d'unicité : `(source_id, plugin_document_id)` et index sur `sha256`.

### 6.4 Choix techniques secondaires

- **Base** : SQLite via `sqlx`. Chiffrement au repos non nécessaire si le dossier est dans un volume FileVault ; option SQLCipher en réglage avancé.
- **PDF** : `pdfium` ou `lopdf` pour l'extraction de texte ; Vision framework pour l'OCR sur macOS.
- **Journaux** : `tracing`, rotation locale, expurgation systématique des valeurs issues du coffre.
- **Mises à jour** : Sparkle ou l'updater Tauri, avec vérification de signature.

---

## 7. Exigences non fonctionnelles


| Domaine              | Exigence                                                                                         |
| -------------------- | ------------------------------------------------------------------------------------------------ |
| Performance          | Une source à 12 factures traitée en moins de 90 s en conditions réseau normales                  |
| Empreinte            | &lt; 400 Mo installé, &lt; 500 Mo de RAM en collecte sur 2 sources parallèles                    |
| Robustesse           | L'échec d'une source n'interrompt jamais les autres ; aucun état corrompu après arrêt brutal     |
| Reprise              | Une exécution interrompue reprend sans retélécharger ce qui est déjà en base                     |
| Hors ligne           | La bibliothèque, la recherche et les exports fichiers fonctionnent sans réseau                   |
| Internationalisation | Interface FR et EN à la v1 ; formats de date et de montant localisés ; DE ensuite                |
| Accessibilité        | Navigation clavier complète, VoiceOver sur les écrans principaux, contrastes AA                  |
| Observabilité        | Journal lisible par l'utilisateur, export d'un rapport d'anomalie anonymisé sur action explicite |
| Compatibilité        | macOS 14 et ultérieur, Apple Silicon et Intel                                                    |


---

## 8. Sécurité, confidentialité, conformité

### 8.1 Modèle de menace

L'application détient les identifiants de tous les fournisseurs de l'utilisateur et exécute du contenu venant de la communauté. C'est la combinaison la plus dangereuse possible. Les menaces à traiter, par ordre de gravité :


| #   | Menace                                                              | Parade                                                                                                                                                    |
| --- | ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| M1  | Plugin malveillant exfiltrant cookies ou identifiants               | `allowedDomains` appliqué au niveau du pilote, pas du plugin ; `runJs` marqué et revu ; index signé ; avertissement explicite pour les plugins hors index |
| M2  | Plugin légitime compromis par un contributeur ultérieur             | Revue obligatoire de chaque PR touchant un plugin existant ; CODEOWNERS ; historique signé ; pas de merge automatique sur modification                    |
| M3  | Fuite de secrets dans les journaux, captures ou rapports d'anomalie | Expurgation centralisée en sortie de journalisation, testée ; captures d'écran jamais transmises automatiquement                                          |
| M4  | Exfiltration via le repli LLM                                       | Désactivé par défaut ; affichage de ce qui sera transmis ; option modèle local                                                                            |
| M5  | Vol du poste                                                        | Secrets dans le Trousseau, jamais dans SQLite ni en fichier de configuration ; FileVault recommandé                                                       |
| M6  | Chaîne d'approvisionnement (dépendances)                            | `cargo audit` et `npm audit` en CI, verrouillage des versions, SBOM publié à chaque release                                                               |


### 8.2 Confidentialité par conception

- Aucun compte, aucun serveur, aucune télémétrie par défaut. Si une télémétrie est ajoutée un jour, elle sera en opt-in explicite avec le contenu exact des événements documenté.
- Les seules connexions réseau sont : les domaines des fournisseurs, l'index des plugins, le canal de mise à jour. Cette liste est vérifiable et doit être testée.

### 8.3 Conformité

- RGPD : l'éditeur n'étant pas destinataire des données, il n'est pas responsable de traitement pour l'usage nominal. À documenter noir sur blanc dans la politique de confidentialité, avec le cas particulier du repli LLM (l'utilisateur devient alors responsable du transfert vers son fournisseur).
- Conservation des pièces : le produit n'est pas un coffre-fort probatoire au sens fiscal. Ne pas le prétendre. L'archivage à valeur probante reste la responsabilité de l'utilisateur ou de sa GED.
- Apple : hardened runtime, notarisation, distribution hors Mac App Store (le bac à sable App Store est incompatible avec le pilotage d'un navigateur embarqué).

### 8.4 Position juridique sur l'automatisation

Automatiser la récupération de ses propres factures avec ses propres identifiants est légitime, mais contrevient aux CGU de nombreux portails, qui interdisent l'accès automatisé. Trois règles à graver dans le projet :

1. Ne jamais contourner de mesure technique de protection (captcha, détection d'automatisation, empreinte navigateur). Si un portail bloque, le plugin échoue et demande une intervention manuelle.
2. Limiter le rythme des requêtes au niveau d'un usage humain.
3. Ne rien collecter au-delà des documents de l'utilisateur lui-même.

Ces règles vont dans le [`CONTRIBUTING.md`](http://CONTRIBUTING.md) et sont vérifiées en revue de PR. Elles limitent la couverture fonctionnelle, et c'est délibéré.

---

## 9. Gouvernance open source

### 9.1 Licence


| Composant     | Licence proposée | Raison                                                                                                                                   |
| ------------- | ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Application   | **AGPL-3.0**     | Empêche qu'un concurrent en fasse un SaaS fermé sans rendre ses modifications ; cohérent avec la promesse « tout est ouvert »            |
| Plugins       | **MIT** ou CC0   | Un plugin est une description d'un portail public ; une licence virale y découragerait la contribution et compliquerait la réutilisation |
| Schéma et SDK | **Apache-2.0**   | Clause de brevet, favorise l'adoption par des tiers                                                                                      |


Point à trancher : l'AGPL ferme la porte à une éventuelle édition commerciale par des tiers, mais aussi à certains usages en entreprise. Si un modèle économique est envisagé un jour (support, version cloud), l'AGPL avec cession des droits par DCO/CLA est le montage classique. **À décider avant la première ligne de code — changer de licence après coup exige l'accord de tous les contributeurs.**

### 9.2 Organisation des dépôts


| Dépôt     | Contenu                                                   |
| --------- | --------------------------------------------------------- |
| `app`     | Application, moteur, schéma de plugin, documentation      |
| `plugins` | Plugins communautaires, JSON uniquement, CI de validation |
| `docs`    | Site de documentation et manuel du contributeur           |


Séparer l'app et les plugins est délibéré : le rythme de contribution des plugins est dix fois supérieur, et la barrière à l'entrée doit y être minimale (une PR d'un seul fichier JSON, sans compilation).

### 9.3 CI du dépôt de plugins

1. Validation contre le JSON Schema.
2. Vérification de l'unicité de l'`id` et de la cohérence du versionnage.
3. Interdiction de toute chaîne ressemblant à un secret (regex + `gitleaks`).
4. Vérification que tous les domaines navigués sont couverts par `allowedDomains`.
5. Marquage automatique des PR contenant `runJs` pour revue humaine.
6. Exécution des tests sur captures HTML si le contributeur en a fourni.
7. Formatage automatique (`prettier`) et commentaire de bienvenue sur les premières contributions.

### 9.4 Documents de gouvernance

[`README.md`](http://README.md), [`CONTRIBUTING.md`](http://CONTRIBUTING.md) (avec les règles de §8.4), `CODE_OF_[CONDUCT.md](http://CONDUCT.md)`, [`SECURITY.md`](http://SECURITY.md) (divulgation responsable, délai de réponse annoncé), [`MAINTAINERS.md`](http://MAINTAINERS.md), [`CHANGELOG.md`](http://CHANGELOG.md). Releases signées, notes générées, publication d'un SBOM.

---

## 10. Risques


| #   | Risque                                                                                                      | Probabilité | Impact   | Parade                                                                                                                                                                                    |
| --- | ----------------------------------------------------------------------------------------------------------- | ----------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| R1  | **Coût de maintenance des plugins.** Les portails changent en permanence ; 60 plugins = 60 sources de casse | Élevée      | Critique | Format déclaratif à faible coût de correction ; signalement en un clic ; catalogue affichant l'état de santé ; accepter une couverture plus faible mais fiable plutôt que large et cassée |
| R2  | **Blocage anti-bot** (Cloudflare, empreintes) sur les gros portails                                         | Élevée      | Élevé    | Navigateur réel avec profil persistant ; rythme humain ; échec explicite plutôt que contournement                                                                                         |
| R3  | **La communauté ne se forme pas** et le projet repose sur une personne                                      | Moyenne     | Critique | Optimiser sans relâche le parcours du contributeur ; démarrer avec 25 plugins FR déjà faits pour prouver la valeur ; documentation et mode dev soignés dès le jour 1                      |
| R4  | **Réaction d'un fournisseur** (mise en demeure sur les CGU)                                                 | Faible      | Élevé    | Règles de §8.4 ; retrait rapide d'un plugin sur demande ; pas de marque tierce dans le nom du produit                                                                                     |
| R5  | **Concurrence gratuite** : Invoice Radar ouvre son app ou baisse son prix                                   | Faible      | Moyen    | Le différenciateur est la couverture FR et l'absence de dépendance à un éditeur, pas le prix                                                                                              |
| R6  | **Dérive du périmètre** vers une GED complète ou un logiciel comptable                                      | Moyenne     | Moyen    | Périmètre §2.3 tenu fermement ; exporter vers les outils existants plutôt que les remplacer                                                                                               |
| R7  | **Sécurité** : un plugin malveillant fusionné                                                               | Faible      | Critique | §8.1 ; en cas d'incident, révocation de l'index, avis de sécurité, mise à jour forcée                                                                                                     |


---

## 11. Lots et jalons


| Lot                                     | Contenu                                                                      | Critère d'acceptation                                                        |
| --------------------------------------- | ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| **L0 — Socle** (4 sem.)                 | Coquille Tauri, pilote Chromium, profils persistants, SQLite, Trousseau      | Un plugin écrit en dur récupère 3 factures d'un portail réel de bout en bout |
| **L1 — Moteur de plugin** (5 sem.)      | Interprète du DSL, schéma v1, filtre de domaines, journalisation, 2FA/TOTP   | 10 plugins écrits sans toucher au code de l'app                              |
| **L2 — Application** (5 sem.)           | Catalogue, ajout de source, bibliothèque, exécution manuelle, export dossier | Un utilisateur non technique ajoute une source et exporte son mois           |
| **L3 — Extraction et exports** (3 sem.) | Regex + OCR, LLM optionnel, webhook, e-mail, CSV, Paperless-ngx              | &gt; 85 % des champs corrects sur un jeu de 100 factures réelles             |
| **L4 — E-mail et import** (3 sem.)      | IMAP, Gmail OAuth, Graph, glisser-déposer                                    | Collecte mixte portails + boîte mail dans une seule exécution                |
| **L5 — Écosystème** (4 sem.)            | Dépôt public, CI, index signé, mode développeur, documentation               | Un contributeur externe fusionne un plugin sans aide                         |
| **L6 — Sortie 1.0** (3 sem.)            | Planification, notifications, signature/notarisation, site, traductions      | 60 plugins, dont 25 FR ; audit de sécurité interne passé                     |


Total indicatif : **27 semaines à temps plein**, hors imprévus. À une demi-journée par semaine, c'est un projet de plusieurs années — c'est le point le plus important de ce document.

---

## 12. Décisions à trancher


| #   | Question                                                                 | Pourquoi c'est bloquant                                                                                                                     |
| --- | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | Nom définitif et dépôt de marque                                         | Conditionne le domaine, l'organisation GitHub, l'identifiant de bundle Apple                                                                |
| D2  | Licence de l'app : AGPL ou Apache-2.0                                    | Irréversible en pratique dès qu'il y a des contributeurs externes                                                                           |
| D3  | Chromium embarqué ou navigateur du système                               | Détermine la taille du binaire et la reproductibilité des plugins                                                                           |
| D4  | Réutilisation du format Invoice Radar : compatible, inspiré, ou distinct | Compatible = accès immédiat à 300 plugins existants, mais dépendance à un format tiers non licencié explicitement, à vérifier juridiquement |
| D5  | Cible prioritaire : freelance (P1) ou cabinet (P3)                       | Change le modèle de données (cloisonnement multi-entités) et l'ergonomie                                                                    |
| D6  | Extraction IA : incluse mais optionnelle, ou hors périmètre v1           | Impacte le lot L3 et la promesse de confidentialité                                                                                         |
| D7  | Modèle économique éventuel                                               | Détermine si un CLA est nécessaire dès le départ                                                                                            |


---

## Annexe A — Sources consultées

- Invoice Radar, page produit française et manuel des plugins (dépôt `invoiceradar/plugins`, 261 commits, 64 étoiles, 18 forks à la date de rédaction).
- Invoice Collector (positionnement cabinets comptables), invoicefetcher® (Allemagne), GetMyInvoices.

## Annexe B — Ce que ce document ne couvre pas encore

Maquettes d'interface, plan de tests détaillé, stratégie de traduction, budget d'infrastructure (index de plugins, site, CI), plan de communication de lancement, et le calendrier exact de la réforme française de la facturation électronique, à revérifier auprès d'une source officielle avant tout argumentaire commercial.