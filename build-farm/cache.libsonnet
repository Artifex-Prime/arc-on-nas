// The build farm's cache: the storage backends of Buildbarn's storage pod (bb-storage), with their
// sizes and eviction settings, on the claim `cache` in build-farm
// (manifests/tenants/build-farm/cache-claim.yaml) mounted at `mountPath`. The storage pod's
// configuration imports this file and places the fields as bb-deployments' storage.jsonnet does:
//
//   contentAddressableStorageServer: { contentAddressableStorage: cache.contentAddressableStorage, ... },
//   actionCache: { backend: cache.actionCache, ... },
//   fileSystemAccessCache: { backend: cache.fileSystemAccessCache, ... },
//
// Written for bb-storage 20261102T091443Z-ca3d8b4, the version bb-deployments pinned on 2026-11-06
// (its CAS splits large objects into chunks, so it has a chunk store and a chunk-mapping store).
// The configuration's schema changes between versions: check it against the release notes when
// the server is upgraded.
//
// The size cap. Each store is LocalBlobAccess: fixed-size files, written block by block, so the
// cache never grows past the files' sizes, whatever is written. Their total (131.2 GiB) stays below
// the host filesystem's quota, the PersistentVolume's capacity (150 GiB), leaving room for the four
// small state files; scripts/check-consistency.sh checks it. The files are sparse until written, so the quota counts only what was stored.
//
// Eviction. A store is a ring of blocks (block size = file size / (spare + old + current + new)).
// New objects go into the new blocks; when they are full, the oldest block is dropped whole and
// becomes a new one. An object read from an old block is copied forward into a new block, so what
// builds keep using stays and the rest ages out: roughly least recently used. The block counts are
// Buildbarn's recommended ones (blobstore.proto). An object larger than one block cannot be stored.
//
// The key-location maps are hash tables of 66-byte records, with twice as many records as a store
// holds objects of 10 KiB on average in the CAS and 2 KiB in the others. bb-storage's metric
// buildbarn_lossymap_hash_map_put_too_many_iterations_total above zero means a map is too small for
// its store.
//
// Persistence: each store's state file is written every five minutes, so a restart keeps the
// cache, and a crash loses at most the objects written since then.

local KiB = 1024;
local MiB = 1024 * KiB;
local GiB = 1024 * MiB;

// Where the storage pod mounts the claim.
local mountPath = '/cache';

// One LocalBlobAccess store in its own directory under mountPath.
local store(dir, blocksBytes, keyLocationMapBytes, newBlocks) = {
  'local': {
    keyLocationMap: {
      onBlockDevice: {
        file: { path: '%s/%s/key_location_map' % [mountPath, dir], sizeBytes: keyLocationMapBytes },
      },
      maximumGetAttempts: 16,
      maximumPutAttempts: 64,
    },
    oldBlocks: 8,
    currentBlocks: 24,
    // Only the CAS may have more than one new block (blobstore.proto): the other stores update
    // existing entries, which needs a single block to write into.
    newBlocks: newBlocks,
    blocksOnBlockDevice: {
      source: {
        file: { path: '%s/%s/blocks' % [mountPath, dir], sizeBytes: blocksBytes },
      },
      spareBlocks: 3,
    },
    persistent: {
      stateDirectoryPath: '%s/%s/persistent_state' % [mountPath, dir],
      minimumEpochInterval: '300s',
    },
  },
};

// The stores. Blocks of 3.4 GiB in the CAS (38 of them), 28 MiB in the action cache and 7 MiB in
// the other two (36 each).
local stores = {
  // Build inputs and outputs, and the chunks of large ones: nearly all of the cache.
  cas: store('cas', 128 * GiB, 1600 * MiB, 3) + {
    'local'+: {
      // As bb-deployments: objects are split into chunks of 256 KiB and more.
      chunkingParameters: { minChunkSizeBytes: 256 * KiB, horizonSizeBytes: 8 * 256 * KiB },
    },
  },
  // Which chunks a large object is made of.
  casChunkMap: store('cas-chunk-map', 256 * MiB, 16 * MiB, 1),
  // Action results, a few KiB each: 1 GiB holds a few hundred thousand.
  ac: store('ac', 1 * GiB, 64 * MiB, 1),
  // The workers' record of which files an action read, for prefetching.
  fsac: store('fsac', 256 * MiB, 16 * MiB, 1),
};

{
  mountPath: mountPath,

  // The directories that must exist before bb-storage starts: it creates its files, not their
  // directories. The storage pod makes them (an init container, as in bb-deployments), as its user.
  directories: [s['local'].persistent.stateDirectoryPath for s in std.objectValues(stores)],

  contentAddressableStorage: {
    chunkStorage: stores.cas,
    chunkMappingStorage: stores.casChunkMap,
  },
  actionCache: stores.ac,
  fileSystemAccessCache: stores.fsac,
}
