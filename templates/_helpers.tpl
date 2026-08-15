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
Labels for AutoscalingRunnerSet objects.
Sets app.kubernetes.io/version to .Values.arcControllerVersion so that the
ARC controller's version compatibility check passes (it deletes runner sets
whose label value does not match the controller's own build version).
*/}}
{{- define "dagger-runners.runnerLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.arcControllerVersion | quote }}
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
Reject floating image tags.

Every image here is pulled with imagePullPolicy: IfNotPresent, because Always
with dozens of pods starting at once exceeds registry pull QPS. That makes a
floating tag actively dangerous rather than merely sloppy: each node serves
whatever it cached first and never sees a new push, so the deployment silently
freezes on an old image with no way to move it forward.

That is how this chart shipped runner 2.334.0 indefinitely, which strands every
AutoscalingRunnerSet in Outdated with no runners and no errors
(actions/actions-runner-controller#4596).

Usage: {{ include "dagger-runners.requirePinnedImage" (dict "image" $img "field" "runner.image") }}

Set allowFloatingTags: true to downgrade this to a NOTES.txt warning.
*/}}
{{- define "dagger-runners.requirePinnedImage" -}}
{{- $image := .image -}}
{{- $field := .field -}}
{{- if or (hasSuffix ":latest" $image) (not (or (contains ":" (last (splitList "/" $image))) (contains "@" $image))) -}}
{{- fail (printf "\n\n%s is %q, which is a floating tag.\n\nImages here are pulled with IfNotPresent, so a floating tag freezes on whatever each node cached first and can never be updated. Pin a version or a digest.\n\nSee values.yaml for why this matters, and actions/actions-runner-controller#4596 for what it caused.\nTo override anyway: --set allowFloatingTags=true\n" $field $image) -}}
{{- end -}}
{{- end -}}

{{/*
Extract minor version (X.Y) from a semver string (X.Y.Z).
Usage: {{ include "dagger-runners.minorVersion" "0.20.3" }}
*/}}
{{- define "dagger-runners.minorVersion" -}}
{{- $parts := split "." . -}}
{{- printf "%s.%s" $parts._0 $parts._1 -}}
{{- end -}}
