// Who the frontend lets in, and what for (README, "Tenant namespaces", "The build farm's
// credentials"): frontend.jsonnet imports `policy` for its gRPC server and `authorizer` for every
// request a client makes. The clients are in clients.libsonnet.
//
// Every request carries a JWT. Its signature and claims say who sent it, and the authentication
// metadata Buildbarn keeps for the request says two things:
//   client  who: `ci-main` or `ci-dev` for CI, the client's own name for the others;
//   tier    the one instance name it may use: `main` for code that is on main or in the merge
//           queue on its way there, `dev` for everything else.
// The authorizer then lets a request through only for its tier's instance name, and only while
// its client is not revoked (the ConfigMap farm-revoked).
//
// Every expression has test vectors, which bb-storage evaluates when it starts: if one fails, the
// frontend does not start, so a broken rule stops the farm instead of opening it.
local clients = import 'clients.libsonnet';

local gh = clients.github;

// Where the frontend's pod mounts what changes without a restart (../frontend.yaml).
local paths = {
  // GitHub's signing keys, kept current by the CronJob github-jwks (../github-jwks.yaml).
  githubJwks: '/auth/github/jwks.json',
  // The revoked clients, `,name,name,`: read again every minute.
  revoked: '/auth/revoked/revoked',
};

// A request's tokens are checked once and the result kept, LRU, for as long as the token is valid:
// a repeat skips the checks (pkg/jwt). GitHub mints a token per job, a box one an hour.
local cache = {
  maximumCacheSize: 1000,
  cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
};

// GitHub's tokens.
//
// Claims: GitHub's issuer, the farm's audience, this repository, a self-hosted runner (ThunderBox's
// runners; a fork's run is on GitHub's) and an actor from the list.
local githubClaims = |||
  payload.iss == '%(issuer)s'
    && payload.aud == '%(audience)s'
    && payload.repository == '%(repository)s'
    && payload.runner_environment == 'self-hosted'
    && contains(`%(actors)s`, payload.actor)
||| % (gh { audience: clients.audience, actors: std.manifestJsonMinified(gh.actors) });

// The tier. `main` only for ci.yml itself:
//   - the merge queue's run: a pull_request run by mergify[bot] of its branch mergify/merge-queue/…
//     (a collaborator's push there is that collaborator's, not mergify[bot]'s);
//   - on main, by schedule or by hand: ci.yml itself, or nightly.yml calling it.
// And the job's own file (job_workflow_ref, else workflow_ref) is ci.yml: a workflow a pull request
// adds stays `dev` even when it calls ci.yml, and so does a job of another reusable workflow ci.yml
// calls. Every claim that can be missing is read through `|| ''`: in go-jmespath,
// starts_with(null, …) is an error, and an error refuses the token.
local githubMetadata = |||
  ( ( ( payload.ref == 'refs/heads/main'
        && contains(['schedule', 'workflow_dispatch'], payload.event_name)
        && contains(['%(ci)s@refs/heads/main', '%(nightly)s@refs/heads/main'], payload.workflow_ref) )
      || ( payload.event_name == 'pull_request'
           && payload.actor == 'mergify[bot]'
           && starts_with(payload.head_ref || '', 'mergify/merge-queue/')
           && starts_with(payload.workflow_ref || '', '%(ci)s@refs/pull/') ) )
    && starts_with(payload.job_workflow_ref || payload.workflow_ref || '', '%(ci)s@')
    && 'main' || 'dev' )
  | {public: {client: join('', ['ci-', @]), tier: @}}
||| % gh;

// The test vectors' tokens. `queue` is the merge queue's run of ci.yml, as GitHub mints it.
local base = {
  iss: gh.issuer,
  aud: clients.audience,
  repository: gh.repository,
  repository_owner: 'kristofk',
  runner_environment: 'self-hosted',
  jti: '6a0a4d2e-0b8f-4c43-9a6e-2f1f8c3f9b10',
  exp: 1794573877,
};
local queue = base {
  actor: 'mergify[bot]',
  event_name: 'pull_request',
  ref: 'refs/pull/1500/merge',
  head_ref: 'mergify/merge-queue/0f1e2d3c4b',
  base_ref: 'main',
  workflow_ref: gh.ci + '@refs/pull/1500/merge',
};
local onMain(event, workflow) = base {
  actor: 'kristofk',
  event_name: event,
  ref: 'refs/heads/main',
  workflow_ref: workflow + '@refs/heads/main',
};
local pr = base {
  actor: 'Artifex-Prime',
  event_name: 'pull_request',
  ref: 'refs/pull/1501/merge',
  head_ref: 'artifex-issue-1501',
  base_ref: 'main',
  workflow_ref: gh.ci + '@refs/pull/1501/merge',
};
local onBranch(event, workflow) = base {
  actor: 'Artifex-Prime',
  event_name: event,
  ref: 'refs/heads/artifex-issue-1501',
  workflow_ref: workflow + '@refs/heads/artifex-issue-1501',
};

local tiers = [
  // main
  [queue, 'main'],
  [queue { job_workflow_ref: queue.workflow_ref }, 'main'],
  [onMain('workflow_dispatch', gh.ci), 'main'],
  [onMain('schedule', gh.nightly) { job_workflow_ref: gh.ci + '@refs/heads/main' }, 'main'],
  [onMain('workflow_dispatch', gh.nightly) { job_workflow_ref: gh.ci + '@refs/heads/main' }, 'main'],
  // dev: an ordinary pull request, and a push to a branch
  [pr, 'dev'],
  [pr { job_workflow_ref: pr.workflow_ref }, 'dev'],
  [onBranch('push', gh.ci), 'dev'],
  // dev: a collaborator's push to the merge queue's branch
  [queue { actor: 'Artifex-Prime' }, 'dev'],
  // dev: a workflow a pull request adds, run in the queue, alone and calling ci.yml
  [queue { workflow_ref: 'kristofk/AIDepartment/.github/workflows/mine.yml@refs/pull/1500/merge' }, 'dev'],
  [queue {
    workflow_ref: 'kristofk/AIDepartment/.github/workflows/mine.yml@refs/pull/1500/merge',
    job_workflow_ref: gh.ci + '@refs/pull/1500/merge',
  }, 'dev'],
  // dev: the queue's ci.yml calling another reusable workflow
  [queue { job_workflow_ref: 'kristofk/AIDepartment/.github/workflows/app-image.yml@refs/pull/1500/merge' }, 'dev'],
  // dev: on main, but another workflow, or a push
  [onMain('workflow_dispatch', 'kristofk/AIDepartment/.github/workflows/release.yml'), 'dev'],
  [onMain('push', gh.ci), 'dev'],
  // dev: ci.yml dispatched on a branch, and nightly.yml as changed on a branch, dispatched there
  [onBranch('workflow_dispatch', gh.ci), 'dev'],
  [onBranch('workflow_dispatch', gh.nightly) { job_workflow_ref: gh.ci + '@refs/heads/artifex-issue-1501' }, 'dev'],
  // dev: a pull request's run that names a ci.yml of another repository's
  [queue { workflow_ref: 'Artifex-Prime/AIDepartment/.github/workflows/ci.yml@refs/pull/1500/merge' }, 'dev'],
];

local githubAccepted = [t[0] for t in tiers];
local githubRejected = [
  pr { runner_environment: 'github-hosted' },
  pr { actor: 'stranger' },
  std.prune(pr { actor: null }),
  pr { repository: 'Artifex-Prime/AIDepartment' },
  pr { aud: 'https://github.com/kristofk' },
  pr { iss: 'https://token.actions.githubusercontent.com/kristofk' },
];

// A client's own token: its audience, its name as `sub`, and an expiry (the credential helper sets
// one hour). Its key is checked first: only this client's own keys (clients.libsonnet).
local clientClaims(name) = |||
  payload.aud == '%(audience)s' && payload.sub == '%(name)s' && payload.exp != null
||| % { audience: clients.audience, name: name };

local clientJwt(name, keys) = {
  jwt: cache {
    jwksInline: { keys: keys },
    claimsValidationJmespathExpression: {
      expression: clientClaims(name),
      local token = { aud: clients.audience, sub: name, iat: 1794570277, exp: 1794573877 },
      testVectors: [
        { input: { payload: token }, expectedOutput: true },
        { input: { payload: token { sub: name + '-x' } }, expectedOutput: false },
        { input: { payload: token { aud: 'elsewhere' } }, expectedOutput: false },
        { input: { payload: std.prune(token { exp: null }) }, expectedOutput: false },
      ],
    },
    metadataExtractionJmespathExpression: {
      expression: '`%s`' % std.manifestJsonMinified({ public: { client: name, tier: 'dev' } }),
    },
  },
};

// The authorizer, for every request a client makes: its tier's instance name only, and not while
// its client is revoked. Without a client (no metadata) join() fails, and a failure refuses.
local authorizerExpression = |||
  authenticationMetadata.public.tier == instanceName
    && !contains(files.revoked, join('', [',', authenticationMetadata.public.client, ',']))
|||;
local as(client, tier) = { public: { client: client, tier: tier } };
local revoked(list) = { revoked: list };

{
  paths: paths,

  policy: {
    any: {
      policies: [{
        jwt: cache {
          jwksFile: paths.githubJwks,
          claimsValidationJmespathExpression: {
            expression: githubClaims,
            testVectors:
              [{ input: { payload: t }, expectedOutput: true } for t in githubAccepted]
              + [{ input: { payload: t }, expectedOutput: false } for t in githubRejected],
          },
          metadataExtractionJmespathExpression: {
            expression: githubMetadata,
            testVectors: [
              { input: { payload: t[0] }, expectedOutput: as('ci-' + t[1], t[1]) }
              for t in tiers
            ],
          },
        },
      }] + [clientJwt(name, clients.keys[name]) for name in std.objectFields(clients.keys)],
    },
  },

  authorizer: {
    jmespathExpression: {
      expression: authorizerExpression,
      files: [{ key: 'revoked', path: paths.revoked }],
      testVectors: [
        { input: { authenticationMetadata: as('ci-main', 'main'), instanceName: 'main', files: revoked(',') }, expectedOutput: true },
        { input: { authenticationMetadata: as('ci-dev', 'dev'), instanceName: 'dev', files: revoked(',') }, expectedOutput: true },
        { input: { authenticationMetadata: as('artifex-prime', 'dev'), instanceName: 'dev', files: revoked(',') }, expectedOutput: true },
        // Each tier its own instance name only, and no other.
        { input: { authenticationMetadata: as('ci-dev', 'dev'), instanceName: 'main', files: revoked(',') }, expectedOutput: false },
        { input: { authenticationMetadata: as('artifex-prime', 'dev'), instanceName: 'main', files: revoked(',') }, expectedOutput: false },
        { input: { authenticationMetadata: as('ci-main', 'main'), instanceName: 'dev', files: revoked(',') }, expectedOutput: false },
        { input: { authenticationMetadata: as('ci-main', 'main'), instanceName: '', files: revoked(',') }, expectedOutput: false },
        { input: { authenticationMetadata: as('ci-dev', 'dev'), instanceName: 'dev/x', files: revoked(',') }, expectedOutput: false },
        // A revoked client, and one whose name is part of a revoked one's.
        { input: { authenticationMetadata: as('artifex-prime', 'dev'), instanceName: 'dev', files: revoked(',mac,artifex-prime,') }, expectedOutput: false },
        { input: { authenticationMetadata: as('ci-main', 'main'), instanceName: 'main', files: revoked(',ci-main,') }, expectedOutput: false },
        { input: { authenticationMetadata: as('artifex-prime', 'dev'), instanceName: 'dev', files: revoked(',artifex-prime-2,') }, expectedOutput: true },
        { input: { authenticationMetadata: as('ci-dev', 'dev'), instanceName: 'dev', files: revoked('') }, expectedOutput: true },
      ],
    },
  },
}
