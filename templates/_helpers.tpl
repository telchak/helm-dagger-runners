{{/*
Standard fullname: release-name truncated to 63 chars.
*/}}
{{- define "dagger-runners.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Standard labels applied to all resources.
*/}}
{{- define "dagger-runners.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/*
Engine Helm release name for a given version.
Usage: {{ include "dagger-runners.engineReleaseName" "0.20.3" }}
*/}}
{{- define "dagger-runners.engineReleaseName" -}}
dagger-engine-v{{ . | replace "." "-" }}
{{- end -}}

{{/*
Engine StatefulSet pod name (used for kube-pod:// connection string).
The dagger-helm chart names the StatefulSet: <release>-dagger-helm-engine
*/}}
{{- define "dagger-runners.engineStatefulSetPod" -}}
{{ include "dagger-runners.engineReleaseName" . }}-dagger-helm-engine-0
{{- end -}}

{{/*
Engine host socket path (daemonset mode).
The dagger-helm chart exposes the socket at: /run/dagger-<release>-dagger-helm
*/}}
{{- define "dagger-runners.engineSocketPath" -}}
/run/dagger-{{ include "dagger-runners.engineReleaseName" . }}-dagger-helm
{{- end -}}

{{/*
Engine runner host connection string.
DaemonSet: unix socket via hostPath mount.
StatefulSet: kube-pod:// protocol via Kubernetes API.
Usage: {{ include "dagger-runners.engineRunnerHost" (dict "version" "0.20.3" "mode" $.Values.engineMode "namespace" $.Release.Namespace) }}
*/}}
{{- define "dagger-runners.engineRunnerHost" -}}
{{- if eq .mode "daemonset" -}}
unix:///run/dagger/engine.sock
{{- else -}}
kube-pod://{{ include "dagger-runners.engineStatefulSetPod" .version }}?namespace={{ .namespace }}
{{- end -}}
{{- end -}}

{{/*
Image pull policy derived from tag.
*/}}
{{- define "dagger-runners.imagePullPolicy" -}}
{{- if hasSuffix ":latest" . -}}Always{{- else -}}IfNotPresent{{- end -}}
{{- end -}}

{{/*
Extract minor version (X.Y) from a semver string (X.Y.Z).
Usage: {{ include "dagger-runners.minorVersion" "0.20.3" }}
*/}}
{{- define "dagger-runners.minorVersion" -}}
{{- $parts := split "." . -}}
{{- printf "%s.%s" $parts._0 $parts._1 -}}
{{- end -}}
