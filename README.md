# Inventory Monitoring

L'app d'inventaire, de ventes, de dépenses et de profit pour vendeurs de cartes à collectionner.

**Ouvrir l'app :** https://inventorymonitoring.ca

## Pour commencer
1. Ouvre l'adresse ci-dessus (Safari sur iPhone, Chrome ou Edge sur ordinateur).
2. Touche **Créer un compte**, entre ton courriel et un mot de passe, puis confirme ton courriel.
3. Sur iPhone : **Partager → Sur l'écran d'accueil** pour l'installer comme une app.

Tes données sont synchronisées sur tous tes appareils et privées : seul ton compte y a accès.

## Sécurité
- Chaque compte doit confirmer son courriel, puis être approuvé par VannzTCG avant d'ouvrir l'app.
- Mots de passe de 10 caractères minimum, vérifiés contre les fuites connues (Have I Been Pwned, sans jamais envoyer le mot de passe).
- Double authentification (code d'une app comme Google Authenticator) dans Réglages › Sécurité.
- Limite d'essais de connexion, déconnexion qui révoque la session, « Déconnecter mes autres appareils ».
- Politique de sécurité du contenu (CSP), protection contre l'affichage dans un cadre, bibliothèque externe vérifiée (SRI).
- Base de données : `supabase/security.sql` (règles RLS : chacun ne voit que ses données, seulement une fois approuvé).
