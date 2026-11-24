{{/* One Argo CD Application. args: root, name, wave, namespace, and either
     chart (a .Values.charts entry + valuesFile) or path (in this repo) */}}
{{- define "app" -}}
{{- $r := .root -}}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ .name }}
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: {{ .wave | quote }}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: token-platform
  destination:
    server: https://kubernetes.default.svc
    namespace: {{ .namespace }}
  {{- if .chart }}
  sources:
    - repoURL: {{ .chart.repo }}
      chart: {{ .chart.chart }}
      targetRevision: {{ .chart.version | quote }}
      helm:
        releaseName: {{ .release | default .name }}
        valueFiles:
          - $values/{{ .valuesFile }}
    - repoURL: {{ $r.Values.repoURL }}
      targetRevision: {{ $r.Values.targetRevision }}
      ref: values
  {{- else }}
  source:
    repoURL: {{ $r.Values.repoURL }}
    targetRevision: {{ $r.Values.targetRevision }}
    path: {{ .path }}
    {{- with .helm }}
    helm:
      {{- toYaml . | nindent 6 }}
    {{- end }}
  {{- end }}
  syncPolicy:
    automated:
      prune: true        # removed from git -> removed from the cluster
      selfHeal: true     # changed by hand -> changed back to what git says
    syncOptions:
      - CreateNamespace=false     # namespaces (with their Pod Security labels) come from bootstrap.sh
      {{- if .serverSide }}
      - ServerSideApply=true      # CRDs and the dashboards ConfigMap are too big for client-side apply
      {{- end }}
    retry:
      limit: 10
      backoff: { duration: 10s, factor: 2, maxDuration: 3m }
{{- end -}}
