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
Resolve the GitHub App secret name for a config entry, falling back to the
top-level github.app values.
Usage: {{ include "dagger-runners.configSecretName" (dict "config" $cfg "root" $root) }}
*/}}
{{- define "dagger-runners.configSecretName" -}}
{{- $app := .config.app | default dict -}}
{{- if $app.existingSecretName -}}
{{- $app.existingSecretName -}}
{{- else if $app.secretName -}}
{{- $app.secretName -}}
{{- else if .root.Values.github.app.existingSecretName -}}
{{- .root.Values.github.app.existingSecretName -}}
{{- else -}}
{{- .root.Values.github.app.secretName -}}
{{- end -}}
{{- end -}}

{{/*
One AutoscalingRunnerSet.

Every scale set in this chart — exact version, minor alias and latest alias,
across every GitHub config — renders through here. It used to be three
copy-pasted pod specs; multiplying that by the config list would have made
five hundred lines of duplication, and drift between the copies is exactly how
imagePullPolicy ended up inconsistent in earlier versions.

Usage:
  {{ include "dagger-runners.scaleSet" (dict
       "root" $root
       "name" "dagger-v0-21-8"          # metadata.name
       "scaleSetName" "dagger-v0.21.8"  # the runner label workflows target
       "engineVersion" "0.21.8"         # which engine to connect the runner to
       "config" $cfg
       "sizeConfig" $sizeConfig
       "minRunners" 40
       "extraLabels" (dict "dagger.io/version" "0.21.8")) }}
*/}}
{{- define "dagger-runners.scaleSet" -}}
{{- $root := .root -}}
{{- $cfg := .config -}}
{{- $sizeConfig := .sizeConfig -}}
{{- $engineMode := $root.Values.engineMode -}}
{{- $secretName := include "dagger-runners.configSecretName" (dict "config" $cfg "root" $root) -}}
{{- $runner := $cfg.runner | default dict -}}
{{- $maxRunners := $runner.maxRunners | default $root.Values.runner.maxRunners -}}
{{- $engineRunnerHost := include "dagger-runners.engineRunnerHost" (dict "version" .engineVersion "mode" $engineMode "namespace" $root.Release.Namespace) -}}
{{- $engineSocketPath := include "dagger-runners.engineSocketPath" .engineVersion -}}
---
apiVersion: actions.github.com/v1alpha1
kind: AutoscalingRunnerSet
metadata:
  name: {{ .name }}
  namespace: {{ $root.Release.Namespace }}
  labels:
    {{- include "dagger-runners.runnerLabels" $root | nindent 4 }}
    app.kubernetes.io/component: runner-scale-set
    {{- if $cfg.name }}
    dagger.io/github-config: {{ $cfg.name | quote }}
    {{- end }}
    {{- range $k, $v := (.extraLabels | default dict) }}
    {{ $k }}: {{ $v | quote }}
    {{- end }}
spec:
  githubConfigUrl: {{ $cfg.configUrl }}
  githubConfigSecret: {{ $secretName }}
  runnerScaleSetName: {{ .scaleSetName }}
  minRunners: {{ .minRunners }}
  maxRunners: {{ $maxRunners }}
  template:
    metadata:
      annotations:
        cluster-autoscaler.kubernetes.io/safe-to-evict: "true"
    spec:
      {{- if eq $engineMode "statefulset" }}
      serviceAccountName: dagger-runner
      {{- end }}
      restartPolicy: Never
      initContainers:
        - name: init-runner-externals
          image: {{ $root.Values.runner.image }}
          imagePullPolicy: IfNotPresent
          command: ["cp"]
          args: ["-r", "-v", "/home/runner/externals/.", "/home/runner/tmpDir/"]
          volumeMounts:
            - name: runner-externals
              mountPath: /home/runner/tmpDir
        {{- if eq $engineMode "statefulset" }}
        - name: init-kubectl
          image: {{ $root.Values.kubectlImage }}
          imagePullPolicy: IfNotPresent
          command: ["cp"]
          args: ["/opt/bitnami/kubectl/bin/kubectl", "/shared-bin/kubectl"]
          volumeMounts:
            - name: shared-bin
              mountPath: /shared-bin
        {{- end }}
      containers:
        - name: runner
          image: {{ $root.Values.runner.image }}
          imagePullPolicy: IfNotPresent
          command: ["/home/runner/run.sh"]
          env:
            - name: _EXPERIMENTAL_DAGGER_RUNNER_HOST
              value: {{ $engineRunnerHost | quote }}
            {{- if eq $engineMode "statefulset" }}
            - name: PATH
              value: /shared-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            {{- end }}
            {{- if $root.Values.daggerCloudToken }}
            - name: DAGGER_CLOUD_TOKEN
              valueFrom:
                secretKeyRef:
                  name: dagger-cloud-token
                  key: token
            {{- end }}
          volumeMounts:
            - name: work
              mountPath: /home/runner/_work
            {{- if eq $engineMode "daemonset" }}
            - name: dagger-socket
              mountPath: /run/dagger
              readOnly: true
            {{- end }}
            {{- if eq $engineMode "statefulset" }}
            - name: shared-bin
              mountPath: /shared-bin
              readOnly: true
            {{- end }}
          {{- if or $sizeConfig.requests $sizeConfig.limits }}
          resources:
            {{- if $sizeConfig.requests }}
            requests:
              {{- toYaml $sizeConfig.requests | nindent 14 }}
            {{- end }}
            {{- if $sizeConfig.limits }}
            limits:
              {{- toYaml $sizeConfig.limits | nindent 14 }}
            {{- end }}
          {{- end }}
      volumes:
        - name: runner-externals
          emptyDir: {}
        - name: work
          emptyDir: {}
        {{- if eq $engineMode "daemonset" }}
        - name: dagger-socket
          hostPath:
            path: {{ $engineSocketPath }}
            type: DirectoryOrCreate
        {{- end }}
        {{- if eq $engineMode "statefulset" }}
        - name: shared-bin
          emptyDir: {}
        {{- end }}
{{- end -}}

{{/*
Extract minor version (X.Y) from a semver string (X.Y.Z).
Usage: {{ include "dagger-runners.minorVersion" "0.20.3" }}
*/}}
{{- define "dagger-runners.minorVersion" -}}
{{- $parts := split "." . -}}
{{- printf "%s.%s" $parts._0 $parts._1 -}}
{{- end -}}
