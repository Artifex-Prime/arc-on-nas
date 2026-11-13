// Where the frontend and the scheduler find the cache: the one storage pod (../storage.yaml),
// through its headless Service. One server, so no sharding; a second storage pod would need
// bb-deployments' sharding and a volume of its own.
local storage = {
  grpc: {
    client: { address: 'storage-0.storage:8981' },
    enableCompression: true,
  },
};

{
  // Saves a GetCapabilities call for every chunked (content-defined chunking) request.
  cdcParameterCache: {
    cacheSize: 1000,
    cacheDuration: '60s',
    cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
  },
  chunkStorage: storage,
  // A chunk map is returned only when every chunk it names is still stored.
  chunkMappingStorage: { chunkMappingValidating: { backend: storage } },
  // An action result is returned only when every output it names is still in the CAS, so a
  // client never gets a cache hit whose files were evicted.
  actionCache: {
    completenessChecking: {
      backend: storage,
      maximumTotalTreeSizeBytes: 64 * 1024 * 1024,
    },
  },
  fileSystemAccessCache: storage,
}
