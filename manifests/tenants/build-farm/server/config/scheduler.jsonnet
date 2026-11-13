// The scheduler (../scheduler.yaml): queues the actions clients send through the frontend
// (port 8982) and hands them to the execution workers, which connect to it (port 8983) and are
// not part of this directory. Without workers, an action is refused at once (UNAVAILABLE, "No
// workers exist for instance name prefix"), and a client builds locally if it is set to fall back.
//
// Its queue lives in memory: a restart of the scheduler fails the operations queued or running at
// that moment, and Bazel retries them.
local common = import 'common.libsonnet';
local topology = import 'topology.libsonnet';

{
  clientGrpcServers: [{
    listenAddresses: [':8982'],
    authenticationPolicy: common.allowAll,
  }],
  workerGrpcServers: [{
    listenAddresses: [':8983'],
    authenticationPolicy: common.allowAll,
  }],
  // The scheduler reads each action's platform properties from the CAS.
  contentAddressableStorage: {
    chunkStorage: topology.chunkStorage,
    chunkMappingStorage: topology.chunkMappingStorage,
    cdcParameterCache: topology.cdcParameterCache,
  },
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,
  global: common.global,
  executeAuthorizer: common.allowAll,
  modifyDrainsAuthorizer: common.allowAll,
  killOperationsAuthorizer: common.allowAll,
  synchronizeAuthorizer: common.allowAll,
  actionRouter: {
    simple: {
      platformKeyExtractor: { action: {} },
      invocationKeyExtractors: [
        { correlatedInvocationsId: {} },
        { toolInvocationId: {} },
      ],
      // bb-deployments' timeouts, until the workers come with limits of their own.
      initialSizeClassAnalyzer: {
        defaultExecutionTimeout: '1800s',
        maximumExecutionTimeout: '7200s',
      },
    },
  },
  // How long a platform's queue stays after its last worker leaves: a worker restarting within
  // that time finds its queued actions still there.
  platformQueueWithNoWorkersTimeout: '900s',
}
