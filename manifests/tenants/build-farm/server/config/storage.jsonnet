// The storage pod (../storage.yaml): the cache itself, on the claim `cache`. Its stores, sizes
// and eviction are in cache.libsonnet. Only the frontend and the scheduler talk to it.
local cache = import 'cache.libsonnet';
local common = import 'common.libsonnet';

{
  grpcServers: [{
    listenAddresses: [':8981'],
    authenticationPolicy: common.allowAll,
  }],
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,
  global: common.global,
  supportedCompressors: ['ZSTD'],
  contentAddressableStorageServer: {
    contentAddressableStorage: cache.contentAddressableStorage,
    getAuthorizer: common.allowAll,
    putAuthorizer: common.allowAll,
    findMissingAuthorizer: common.allowAll,
    maximumChunkCount: 100000,
  },
  actionCache: {
    backend: cache.actionCache,
    getAuthorizer: common.allowAll,
    putAuthorizer: common.allowAll,
  },
  fileSystemAccessCache: {
    backend: cache.fileSystemAccessCache,
    getAuthorizer: common.allowAll,
    putAuthorizer: common.allowAll,
  },
}
