// The CronJob github-jwks (../github-jwks.yaml): bb-storage's sync_jwks_to_configmap, which fetches
// GitHub's OIDC signing keys and writes them into the ConfigMap github-jwks, which the frontend
// reads (auth.libsonnet). bb-storage fetches no key set itself, by design (jwt.proto). The
// namespace reaches the internet only through the stack's proxy; the API server it reaches
// directly, by the admin's leave (../../github-jwks.yaml).
local clients = import 'clients.libsonnet';

{
  httpClient: { proxyUrl: 'http://172.31.250.2:3128' },
  jwksUrl: clients.github.jwksUrl,
  configMapNamespace: 'build-farm',
  configMapName: 'github-jwks',
  configMapKey: 'jwks.json',
}
