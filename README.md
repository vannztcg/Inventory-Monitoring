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
Le Pro coûte 7,99 $/mois, prix final (aucune taxe ajoutée tant que VannzTCG est un petit fournisseur non inscrit à la TPS/TVQ). Le paiement passe par un lien de paiement Stripe ; une fonction Supabase reçoit la confirmation et active le Pro toute seule.

1. **Stripe** (dashboard.stripe.com) : crée le produit « Inventory Monitoring Pro », prix récurrent de 7,99 CAD par mois.
2. **Taxes** : aucune pour l'instant (petit fournisseur, 30 000 $ de ventes taxables ou moins sur 12 mois). Si ce seuil est dépassé : inscription à la TPS/TVQ, puis Stripe Tax et « Collect tax automatically » sur le lien.
3. **Lien de paiement** (Payment Links › New) : ce prix (laisser « Collect tax automatically » décoché), et après le paiement « Don't show confirmation page » → `https://inventorymonitoring.ca/?paid=1`.
4. **Portail client** (Settings › Billing › Customer portal) : active-le et copie le lien de connexion (`https://billing.stripe.com/p/login/…`).
5. **Webhook** (Developers › Webhooks › Add endpoint) : `https://qghjmjbmpbpslfkwyqet.supabase.co/functions/v1/stripe-webhook`, événements `checkout.session.completed`, `invoice.paid`, `customer.subscription.updated`, `customer.subscription.deleted`. Copie le « Signing secret » (`whsec_…`) et colle-le toi-même dans Supabase › Edge Functions › Secrets sous le nom `STRIPE_WEBHOOK_SECRET`. Ne l'envoie à personne.
6. Dans l'app : Console › Réglages › Paiement en ligne, colle le lien de paiement et le lien du portail.

La fonction `supabase/functions/stripe-webhook` vérifie la signature de Stripe et transmet l'événement à `billing.stripe_apply()` (schéma non exposé à l'API).
