# Authentik

[Authentik](https://goauthentik.io/) is an IdP (Identity Provider) and SSO (Single Sign On) platform that is built with security at the forefront of every piece of code, every feature, with an emphasis on flexibility and versatility.

With authentik, site administrators, application developers, and security engineers have a dependable and secure solution for authentication in almost any type of environment. There are robust recovery actions available for the users and applications, including user profile and password management. You can quickly edit, deactivate, or even impersonate a user profile, and set a new password for new users or reset an existing password.

## Deployment

Deployment is fully done by ArgoCD. But, ... with a (small) twist. We're using [Kustomize](https://argo-cd.readthedocs.io/en/stable/user-guide/kustomize/) to deploy the official `authentik` Helm chart and related resources (our secrets).

> Kustomize/Helm support needs to be enabled in the ArgoCD config. In [08-ARGOCD.md](../../../docs/08-ARGOCD.md) you can read that we used `--set 'configs.cm.kustomize\.buildOptions=--enable-helm'` when installing the Helm chart.

More info about Kustomize can be found [here](https://kustomize.io/).

## Create Sealed Secrets

```
kubectl create secret generic authentik-secret-key \
  --namespace authentik \
  --from-literal=AUTHENTIK_SECRET_KEY=$(openssl rand -base64 64 | tr -d '\n') \
  --from-literal=AUTHENTIK_BOOTSTRAP_EMAIL="admin@geeklabs.dev" \
  --from-literal=AUTHENTIK_BOOTSTRAP_PASSWORD=$(openssl rand -base64 32 | tr -d '\n') \
  --from-literal=AUTHENTIK_BOOTSTRAP_TOKEN=$(openssl rand -base64 32 | tr -d '\n') \
  --dry-run=client -o yaml | \
kubeseal \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=sealed-secrets \
  --format yaml
```

When using the 'embedded' PostgreSQL database, you need to create a `password` as well:

```
kubectl create secret generic authentik-postgres-credentials \
  --namespace authentik \
  --from-literal=password=$(openssl rand -base64 32 | tr -d '\n') \
  --dry-run=client -o yaml | \
kubeseal \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=sealed-secrets \
  --format yaml
```

Copy result of both commands to (`secrets.yaml`)[secrets.yaml]. If you decide to give these secrets a different name, make sure to update the `values.yaml` file.

## TODO

* use external db
* and/or use `PersistentVolume` to store db data on Synology NAS
* implement ('domain-level forward authentication')[https://docs.goauthentik.io/add-secure-apps/providers/proxy/server_traefik/]
* integrate with (Synology DSM)[https://integrations.goauthentik.io/infrastructure/synology-dsm/]

