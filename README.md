# Élection des délégués

Application web pour élire le ou la délégué(e) et le ou la suppléant(e) de la classe.
Chaque élève se connecte avec son prénom, vote une seule fois (vérifié par le serveur),
et tout le monde voit en direct le top 3 de chaque scrutin. Le vote est secret :
la base enregistre *que* tu as voté, jamais *pour qui*.

Fichiers :
- `index.html` : le site (une seule page, rien à installer)
- `supabase.sql` : la base de données et la liste des 31 élèves

## 1. Supabase (5 min)

Tu peux réutiliser ton projet Supabase existant (les tables commencent par `election_`, aucun conflit).

1. Supabase > ton projet > **SQL Editor** > New query
2. Colle tout le contenu de `supabase.sql` > **Run**
3. **Project Settings > API** : copie la *Project URL* et la clé *anon* (ou *publishable*)

## 2. Configurer le site

Ouvre `index.html`, en haut du `<script>` :

```js
const SUPABASE_URL = "https://xxxxx.supabase.co";
const SUPABASE_KEY = "ta clé anon";
const NOM_CLASSE   = "BTS MCO 1";   // facultatif
```

La clé anon est faite pour être publique : les élèves ne peuvent rien faire d'autre
qu'appeler les 4 fonctions de vote.

## 3. GitHub

1. github.com > **New repository** > nom : `election-delegues` (de préférence **Private**, le SQL contient les noms de la classe)
2. **Add file > Upload files** > glisse `index.html` (et les 2 autres fichiers si tu veux) > Commit

## 4. Vercel

1. vercel.com > **Add New > Project** > importe `election-delegues`
2. Framework Preset : **Other** > **Deploy**
3. Partage l'adresse `https://election-delegues-xxx.vercel.app` à la classe

## 5. Avant le vrai vote

Teste avec quelques prénoms, puis remets tout à zéro dans le SQL Editor :

```sql
truncate election_bulletins;
update election_eleves set a_vote = false;
```

Identifiants : le prénom, sans se soucier des majuscules ni des accents.
Les deux Marie se connectent avec **MarieG** (Gastal) et **MarieR** (Rigaud).

## Requêtes utiles

```sql
-- Qui n'a pas encore voté
select prenom, nom from election_eleves where not a_vote order by nom;

-- Dépouillement complet du scrutin délégué(e)
select e.prenom, e.nom, count(*) as voix
  from election_bulletins b join election_eleves e on e.identifiant = b.delegue
 group by 1, 2 order by voix desc;

-- Corriger l'orthographe d'un prénom
update election_eleves set prenom = 'Naïs' where identifiant = 'nais';
```
