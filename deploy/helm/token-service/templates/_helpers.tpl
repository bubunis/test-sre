{{/* Name of each component: <release>-api, <release>-grpc, ... */}}
{{- define "ts.name" -}}
{{- printf "%s-%s" .root.Release.Name .component | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ts.labels" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/part-of: token-service
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version }}
{{- end -}}

{{- define "ts.selector" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end -}}

{{/* Pod-level security: non-root, fixed uid, default seccomp */}}
{{- define "ts.podSecurity" -}}
runAsNonRoot: true
runAsUser: {{ .uid }}
runAsGroup: {{ .gid | default .uid }}
fsGroup: {{ .gid | default .uid }}
seccompProfile:
  type: {{ .root.Values.podSecurity.seccompProfile }}
{{- end -}}

{{/* Container-level security: read-only root, no privilege escalation, no capabilities */}}
{{- define "ts.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
privileged: false
capabilities:
  drop: ["ALL"]
{{- end -}}

{{/* Spread replicas: hard across zones, best effort across nodes.
     nodeTaintsPolicy Honor: a cordoned/drained node's zone is ignored, so
     replacements can still start in the remaining zone during maintenance. */}}
{{- define "ts.spread" -}}
{{- if .root.Values.topologySpread.enabled }}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: {{ .root.Values.topologySpread.whenUnsatisfiable }}
    nodeTaintsPolicy: Honor
    matchLabelKeys: ["pod-template-hash"]   # count only pods of the same rollout
    labelSelector:
      matchLabels:
        {{- include "ts.selector" . | nindent 8 }}
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    nodeTaintsPolicy: Honor
    labelSelector:
      matchLabels:
        {{- include "ts.selector" . | nindent 8 }}
{{- end }}
{{- end -}}
