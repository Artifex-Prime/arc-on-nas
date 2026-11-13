// Who may use the build farm (README, "Tenant namespaces", "The build farm's credentials"). The
// frontend (frontend.jsonnet) authenticates every request with one of these, through auth.libsonnet.
// Only public values: this repository is public. A change here makes a new ConfigMap, and the
// frontend restarts with it.
{
  // The JWT audience every client's token names, GitHub's and the clients' own.
  audience: 'aid-build-farm',

  // CI: GitHub's OIDC tokens for the jobs of this repository on self-hosted runners, started by one
  // of these logins. A fork's pull request runs on GitHub's runners and is started by its author,
  // so it is refused twice over. The merge queue's runs are mergify[bot]'s; the nightly's are those
  // of whoever last changed its schedule.
  github: {
    issuer: 'https://token.actions.githubusercontent.com',
    jwksUrl: 'https://token.actions.githubusercontent.com/.well-known/jwks',
    repository: 'kristofk/AIDepartment',
    actors: ['kristofk', 'Opifex-Magnus', 'Artifex-Prime', 'mergify[bot]'],
    // The workflows whose jobs may be trusted (`main`): ci.yml, started by the merge queue or on
    // main, or called by nightly.yml on main.
    ci: 'kristofk/AIDepartment/.github/workflows/ci.yml',
    nightly: 'kristofk/AIDepartment/.github/workflows/nightly.yml',
  },

  // Everyone else: a client with an Ed25519 key of its own, which signs its own short tokens (its
  // `sub` is its name). The private half stays in the client's keychain; this is the public half,
  // as AIDepartment's scripts/build-farm-credential.sh public prints it. Such a client is never
  // trusted: its builds are `dev`. Two keys for one client while it rotates; removing a client's
  // entry revokes it (README, "Rotating and revoking").
  keys: {
    'artifex-prime': [{ kty: 'OKP', crv: 'Ed25519', x: 'nxw0Arts7G4DOOtmKpJ6lmjalJNUaVVhdrwiJsGCfI8' }],
  },
}
