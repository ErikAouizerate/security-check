# INSTRUCTIONS.md — security-check

Prochaines instructions à suivre :

- Construire l'image en local : `make build`, puis `make audit`.
- Pousser une première fois l'image sur GHCR (le workflow `build-image` s'en charge sur `main`).
- Activer la protection de branche `main` et exiger le job `security-audit`.
- Configurer GitHub Advanced Security / code scanning pour recevoir les SARIF.
- À chaque montée de version d'un outil : mettre à jour le tag épinglé dans `Dockerfile.security` et le README.
