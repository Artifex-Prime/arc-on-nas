// The frontend (../frontend.yaml): the one address clients use, `frontend:8980`, for the remote
// cache (CAS, action cache) and remote execution. It passes cache requests to the storage pod and
// execution requests to the scheduler. Clients reach it from other namespaces and from outside the
// cluster (README, "Tenant namespaces", "The build farm's network"), so it speaks TLS only.
local common = import 'common.libsonnet';
local topology = import 'topology.libsonnet';

// Remembers for a minute which objects exist, so that a build's repeated FindMissingBlobs calls do
// not all reach the storage pod. bb-deployments keeps a million entries; a tenth of that keeps
// the frontend's memory small and still covers a large build.
local existenceCache = {
  cacheSize: 100000,
  cacheDuration: '60s',
  cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
};

{
  grpcServers: [{
    listenAddresses: [':8980'],
    authenticationPolicy: common.allowAll,
    // The key pair from the Secret frontend-tls (scripts/farm-tls.sh), read again every minute: a
    // renewed Secret reaches the pod's volume within about two minutes, and is served from then
    // on with no restart. bb-storage reports each certificate's expiry in its metrics
    // (tls_certificate_not_after_time_seconds).
    tls: {
      serverKeyPair: {
        files: {
          certificatePath: '/tls/tls.crt',
          privateKeyPath: '/tls/tls.key',
          refreshInterval: '60s',
        },
      },
    },
  }],
  schedulers: {
    // Every instance name goes to the one scheduler, with the client's request metadata (the
    // build's invocation ID, among others), which the scheduler groups operations by.
    '': {
      endpoint: {
        address: 'scheduler:8982',
        addMetadataJmespathExpression: {
          expression: |||
            {
              "build.bazel.remote.execution.v2.requestmetadata-bin": incomingGRPCMetadata."build.bazel.remote.execution.v2.requestmetadata-bin"
            }
          |||,
        },
      },
    },
  },
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,
  global: common.global,
  supportedCompressors: ['ZSTD'],
  contentAddressableStorageServer: {
    contentAddressableStorage: {
      chunkStorage: { existenceCaching: { backend: topology.chunkStorage, existenceCache: existenceCache } },
      chunkMappingStorage: { existenceCaching: { backend: topology.chunkMappingStorage, existenceCache: existenceCache } },
      cdcParameterCache: topology.cdcParameterCache,
    },
    getAuthorizer: common.allowAll,
    putAuthorizer: common.allowAll,
    findMissingAuthorizer: common.allowAll,
    maximumChunkCount: 100000,
  },
  // No client writes an action result or a file system access profile: the workers compute them
  // and write them to the storage pod directly, and a client's own result could be anything. A
  // blob in the CAS is named by its hash, so a client's upload of one cannot be wrong.
  actionCache: {
    backend: topology.actionCache,
    getAuthorizer: common.allowAll,
    putAuthorizer: common.denyAll,
  },
  fileSystemAccessCache: {
    backend: topology.fileSystemAccessCache,
    getAuthorizer: common.allowAll,
    putAuthorizer: common.denyAll,
  },
  executeAuthorizer: common.allowAll,
}
