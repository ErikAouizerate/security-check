# INSTRUCTIONS.md — security-check

Prochaines instructions à suivre :

- Construire l'image en local : `make build`, puis `make audit`.
- Pousser une première fois l'image sur GHCR (le workflow `build-image` s'en charge sur `main`).
- Activer la protection de branche `main` et exiger le job `security-audit`.
- Configurer GitHub Advanced Security / code scanning pour recevoir les SARIF.
- À chaque montée de version d'un outil : mettre à jour le tag épinglé dans `Dockerfile.security` et le README.
- Étudier un job CI qui construit l'image de la PR et l'audite directement (pour scanner les changements de la PR).
- Rendre le package GHCR public (ou utiliser pull_request_target) pour que les PR de forks puissent tirer l'image.
