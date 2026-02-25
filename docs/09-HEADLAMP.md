# Headlamp
> WIP

## Installation

The deployment is managed by, ... you guessed it: ArgoCD.

The `Application` is [here](../k3s/argocd/apps/headlamp.yaml), the actual manifests are [here](../k3s/apps/headlamp/).

After a successful deployment, the following resources are created:

```
$ kubectl get all -n kube-system -l app.kubernetes.io/name=headlamp

NAME                            READY   STATUS    RESTARTS   AGE
pod/headlamp-6b84f9fdc5-86gsj   1/1     Running   0          43m

NAME               TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)   AGE
service/headlamp   ClusterIP   10.43.5.187   <none>        80/TCP    48m

NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/headlamp   1/1     1            1           48m

NAME                                  DESIRED   CURRENT   READY   AGE
replicaset.apps/headlamp-5c64f4f645   0         0         0       45m
replicaset.apps/headlamp-6b84f9fdc5   1         1         1       43m
replicaset.apps/headlamp-85945776df   0         0         0       48m
```

And, we have an `Ingress`:

```
NAME       CLASS     HOSTS               ADDRESS      PORTS     AGE
headlamp   traefik   dash.geeklabs.dev   10.0.1.240   80, 443   26
```

By default, the Helm chart also creates a `ServiceAccount` called `headlamp` (if you did not change this in the `values.yaml`). For now, we need to create an access token to be able to login.

## Get Access Token

```
$ kubectl create token headlamp -n kube-system

eyJhbGciOiJSUzI1NiIsImtpZCI6IkxJMHRiSGVaM3BPM1J2bTRyMG...
```

Use this token to login.

As mentioned, this is a work-in-progress. I will add OIDC login (using Authentik) later.

## Dashboard

As you can see in the `Ingress` defintion, we used `dash.geeklabs.dev`. Because of our integration with `external-dns` and `cert-manager`, we can access our dashboard in our browser at https://dash.geeklabs.dev