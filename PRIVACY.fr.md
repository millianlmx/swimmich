[English](PRIVACY.md) · [Français](PRIVACY.fr.md) · [Deutsch](PRIVACY.de.md) · [Español](PRIVACY.es.md) · [Italiano](PRIVACY.it.md)

# Swimmich — Politique de confidentialité

Dernière mise à jour : 16 octobre 2026

Swimmich est un client iOS tiers pour les serveurs Immich auto-hébergés. Il n'est pas affilié au projet Immich. Le serveur auquel vous vous connectez appartient à vous-même ou à son administrateur, pas au développeur de Swimmich.

## Aucune collecte par le développeur

Le développeur de Swimmich ne collecte, ne reçoit, ne stocke et ne vend aucune donnée. Il n'exploite aucun serveur et n'a aucun accès à vos photos ni à votre compte.

## Ni pistage ni analytics

Swimmich ne contient aucun pistage, aucun analytics, aucun rapport de plantage, aucune publicité ni aucun SDK tiers de ce type. L'app ne lit jamais la position de votre appareil.

## Données envoyées à votre serveur Immich, et à lui seul

Les données suivantes quittent votre appareil pour le serveur Immich que vous avez choisi, et pour personne d'autre :

- l'adresse du serveur ;
- votre e-mail et votre mot de passe à la connexion, ou la connexion SSO (authentification unique) auprès du fournisseur que votre serveur est configuré pour utiliser ;
- le jeton de session, joint à chaque requête ;
- les photos et vidéos que vous sauvegardez ou envoyez, avec leurs dates et métadonnées, ainsi que les modifications de métadonnées que vous effectuez ;
- un identifiant d'appareil aléatoire généré par l'app (ce n'est ni un identifiant matériel ni un identifiant publicitaire) ;
- les mises à jour en temps réel échangées avec ce même serveur.

Ce que le serveur fait de ces données relève de son administrateur et de sa propre politique.

## Services Apple

Les cartes et l'affichage des lieux envoient à Apple les coordonnées de vos photos et les zones que vous consultez : tuiles de carte, noms de lieux et itinéraires. AirPlay passe par iOS. Ces services relèvent de la politique de confidentialité d'Apple. Rien ne passe par le développeur.

## Données stockées sur votre appareil

- **Trousseau (cet appareil uniquement) :** le jeton de session de chaque compte, le code PIN facultatif du dossier verrouillé, et la session partagée avec le widget et l'extension de partage (adresse du serveur, jeton et identifiant d'appareil). Votre mot de passe n'est jamais stocké.
- **Réglages et comptes enregistrés :** l'adresse du serveur, les comptes enregistrés (adresse, e-mail et nom), votre identifiant d'utilisateur et votre statut d'administrateur, l'identifiant d'appareil, les serveurs approuvés, et vos préférences (sauvegarde et albums choisis, nettoyage, langue, verrouillage, affichage).
- **Caches et fichiers :** un cache d'images sur le disque, les originaux que vous conservez hors ligne, le journal de sauvegarde, les états d'édition, un cache de repères de carte (coordonnées), les téléchargements et des fichiers temporaires.
- **Journal de l'app :** conservé en mémoire seulement, et exporté uniquement si vous le faites vous-même.

Ces données restent sur votre appareil, sauf ce qui est envoyé à votre serveur comme décrit ci-dessus.

Autorisations :

- **Photos (lecture et écriture) :** pour sauvegarder votre photothèque, enregistrer des photos et libérer de l'espace.
- **Caméra :** uniquement pour scanner le QR code qui configure le serveur.
- **Face ID :** pour verrouiller l'app. Il est géré par iOS ; l'app ne reçoit aucune donnée biométrique.

## Suppression du compte

Swimmich ne crée aucun compte. Votre compte appartient à votre serveur Immich. Pour le supprimer, adressez-vous à l'administrateur de ce serveur.

## Contact

Questions et support : https://github.com/millianlmx/swimmich/issues
