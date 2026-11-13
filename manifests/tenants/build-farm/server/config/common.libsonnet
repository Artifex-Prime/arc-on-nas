// What the build farm's servers share: storage.jsonnet, frontend.jsonnet and scheduler.jsonnet
// import it. Written for the Buildbarn versions the manifests pin (../kustomization.yaml): the
// configuration's schema changes between versions, so compare it with bb-deployments' at the new
// version on every upgrade (README, "Tenant namespaces", "Upgrading the build farm's server").
{
  // The largest gRPC message a server sends or accepts, as bb-deployments. Larger blobs move
  // through ByteStream in pieces.
  maximumMessageSizeBytes: 2 * 1024 * 1024,

  // Each server's metrics, for Prometheus, on port 9980 (`/metrics`). No pprof or active spans:
  // nothing reads them, and the namespace's other pods would reach them.
  global: {
    diagnosticsHttpServer: {
      httpServers: [{
        listenAddresses: [':9980'],
        authenticationPolicy: { allow: {} },
      }],
      enablePrometheus: true,
      enablePprof: false,
      enableActiveSpans: false,
    },
  },

  // Who may connect to the storage pod and the scheduler: everyone that reaches the port. The
  // namespace's NetworkPolicies let in only the namespace's own pods
  // (../../../base/networkpolicy.yaml). The frontend, which the runners and the forwarder reach too
  // (../../networkpolicy.yaml), takes a credential from every client instead (auth.libsonnet).
  allowAll: { allow: {} },
  denyAll: { deny: {} },
}
