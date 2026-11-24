# Inventory Monitoring

L'app d'inventaire, de ventes, de dépenses et de profit pour vendeurs de cartes à collectionner.

**Ouvrir l'app :** https://inventorymonitoring.ca

## Pour commencer
1. Ouvre l'adresse ci-dessus (Safari sur iPhone, Chrome ou Edge sur ordinateur).
2. Touche **Créer un compte**, entre ton courriel et un mot de passe, puis confirme ton courriel.
3. Sur iPhone : **Partager → Sur l'écran d'accueil** pour l'installer comme une app.

Tes données sont synchronisées sur tous tes appareils et privées : seul ton compte y a accès.

## Sécurité
- Chaque compte doit confirmer son courriel (et passer la vérification anti-robot) ; il commence ensuite sur le forfait Free, sans attente.
- VannzTCG peut suspendre un compte ou offrir un essai Pro de 7 jours depuis sa console.
- Mots de passe de 10 caractères minimum, vérifiés contre les fuites connues (Have I Been Pwned, sans jamais envoyer le mot de passe).
- Double authentification (code d'une app comme Google Authenticator) dans Réglages › Sécurité.
- Limite d'essais de connexion, déconnexion qui révoque la session, « Déconnecter mes autres appareils ».
- Politique de sécurité du contenu (CSP), protection contre l'affichage dans un cadre, bibliothèque externe vérifiée (SRI).
- Base de données : `supabase/security.sql` puis `supabase/plans.sql` (règles RLS : chacun ne voit que ses données ; forfaits, essai et Stripe ; 20 000 documents max par compte).

## Paiement en ligne (Stripe)
Le Pro coûte 7,99 $/mois ou 79,90 $/an (2 mois gratuits), prix final (aucune taxe ajoutée tant que VannzTCG est un petit fournisseur non inscrit à la TPS/TVQ). Le paiement passe par un lien de paiement Stripe ; une fonction Supabase reçoit la confirmation et active le Pro toute seule.

1. **Stripe** (dashboard.stripe.com) : crée le produit « Inventory Monitoring Pro » avec 2 prix récurrents : 7,99 CAD par mois et 79,90 CAD par année.
2. **Taxes** : aucune pour l'instant (petit fournisseur, 30 000 $ de ventes taxables ou moins sur 12 mois). Si ce seuil est dépassé : inscription à la TPS/TVQ, puis Stripe Tax et « Collect tax automatically » sur le lien.
3. **Liens de paiement** (Payment Links › New), un pour chaque prix (laisser « Collect tax automatically » décoché), et après le paiement « Don't show confirmation page » → `https://inventorymonitoring.ca/?paid=1`.
4. **Portail client** (Settings › Billing › Customer portal) : active-le, permets de changer entre les 2 prix (mensuel ↔ annuel) et copie le lien de connexion (`https://billing.stripe.com/p/login/…`).
5. **Webhook** (Developers › Webhooks › Add endpoint) : `https://qghjmjbmpbpslfkwyqet.supabase.co/functions/v1/stripe-webhook`, événements `checkout.session.completed`, `invoice.paid`, `customer.subscription.updated`, `customer.subscription.deleted`. Copie le « Signing secret » (`whsec_…`) et colle-le toi-même dans Supabase › Edge Functions › Secrets sous le nom `STRIPE_WEBHOOK_SECRET`. Ne l'envoie à personne.
6. Dans l'app : Console › Réglages › Paiement en ligne, colle le lien mensuel, le lien annuel et le lien du portail.

La fonction `supabase/functions/stripe-webhook` vérifie la signature de Stripe et transmet l'événement à `billing.stripe_apply()` (schéma non exposé à l'API).

### Page de paiement dans l'app
Les membres paient sans quitter l'app : la fonction `supabase/functions/create-checkout` crée une session Stripe Checkout (`ui_mode: elements`) et l'app affiche le formulaire de carte de Stripe (Payment Element) dans sa propre page. Le webhook ci-dessus active le Pro, comme avec les liens.

1. **Clé restreinte** (Stripe › Developers › API keys › Create restricted key) : *Checkout Sessions* en écriture, *Customers* en écriture, *Prices* et *Products* en lecture. Colle-la toi-même dans Supabase › Edge Functions › Secrets sous le nom `STRIPE_SECRET_KEY`. Ne l'envoie à personne.
2. **Fonction** `create-checkout` déployée avec « Verify JWT » désactivé (elle vérifie elle-même la session Supabase), et le SQL `supabase/plans.sql` relancé (table `billing.checkout_log`, limite de 12 sessions par compte et par heure).
3. **Clé publiable** (`pk_live_…`) : Console › Réglages › Paiement en ligne. Sans cette clé ou si la fonction ne répond pas, l'app utilise le lien de paiement Stripe comme avant.
4. **Domaine** `inventorymonitoring.ca` enregistré dans Stripe › Settings › Payment method domains (Apple Pay, Google Pay et Link).


## Pages légales et conformité

- `/conditions/` : Conditions d'utilisation (forfaits, renouvellement automatique, annulation, remboursement, marques).
- `/confidentialite/` : Politique de confidentialité (Loi 25 : renseignements recueillis, fournisseurs, hébergement hors Québec, conservation, droits).
- Les deux pages sont générées par `legal.py` (textes dans `legal_content.py`), en français (version qui fait foi) et en anglais.
- Les coordonnées de l'entreprise (nom légal, adresse, téléphone, responsable des renseignements personnels) se règlent dans la console propriétaire › Réglages › « Ton entreprise (pages légales) ». Les pages les lisent en direct avec la fonction `legal_info()`.
- `supabase/legal.sql` : à coller une fois dans Supabase → SQL Editor. Ajoute `legal_info()`, `delete_my_account()` et le suivi des annulations programmées (`members.cancel_at`).
- Dans l'app : case de consentement à l'inscription (jamais cochée d'avance, version enregistrée dans le compte), bouton « Annuler mon abonnement » dans Mon abonnement, Réglages › Confidentialité (export, suppression du compte, avis de marques).
- Les polices (Inter, Instrument Serif) sont servies depuis `/fonts/` : aucune requête vers Google Fonts.
