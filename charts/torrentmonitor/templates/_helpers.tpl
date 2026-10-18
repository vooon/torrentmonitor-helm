{{- define "tm.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "tm.fullname" -}}
{{- if contains .Chart.Name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "tm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "tm.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "tm.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "tm.image" -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.Version }}
{{- end }}

{{- define "tm.keySecret" -}}
{{- .Values.encryptionKey.existingSecret | default (printf "%s-key" (include "tm.fullname" .)) }}
{{- end }}

{{/* Environment shared by the web pod, the engine and the migrator. */}}
{{- define "tm.env" -}}
- name: TM_TIMEZONE
  value: {{ .Values.timezone | quote }}
- name: TM_ENCRYPTION_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "tm.keySecret" . }}
      key: {{ .Values.encryptionKey.secretKey }}
- name: TM_DB_TYPE
  value: {{ .Values.database.type }}
{{- if eq .Values.database.type "pgsql" }}
{{- $s := required "database.pgsql.existingSecret is required for pgsql" .Values.database.pgsql.existingSecret }}
{{- range $env, $k := dict "TM_DB_HOST" .Values.database.pgsql.keys.host "TM_DB_PORT" .Values.database.pgsql.keys.port "TM_DB_NAME" .Values.database.pgsql.keys.dbname "TM_DB_USER" .Values.database.pgsql.keys.user "TM_DB_PASSWORD" .Values.database.pgsql.keys.password }}
- name: {{ $env }}
  valueFrom:
    secretKeyRef:
      name: {{ $s }}
      key: {{ $k }}
{{- end }}
{{- else if eq .Values.database.type "sqlite" }}
- name: TM_DB_PATH
  value: /var/lib/torrentmonitor/tm.sqlite
{{- else }}
{{- fail "database.type must be pgsql or sqlite" }}
{{- end }}
{{- if .Values.configXml }}
- name: TM_CONFIG_XML
  value: /etc/torrentmonitor-custom/config.xml
{{- end }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "tm.volumeMounts" -}}
- name: tmp
  mountPath: /tmp
- name: torrents
  mountPath: /app/torrents
{{- if eq .Values.database.type "sqlite" }}
- name: data
  mountPath: /var/lib/torrentmonitor
{{- end }}
{{- if .Values.configXml }}
- name: config-xml
  mountPath: /etc/torrentmonitor-custom
  readOnly: true
{{- end }}
{{- end }}

{{- define "tm.volumes" -}}
- name: tmp
  emptyDir: {}
- name: torrents
  emptyDir: {}
{{- if eq .Values.database.type "sqlite" }}
- name: data
  persistentVolumeClaim:
    claimName: {{ .Values.database.sqlite.persistence.existingClaim | default (printf "%s-data" (include "tm.fullname" .)) }}
{{- end }}
{{- if .Values.configXml }}
- name: config-xml
  configMap:
    name: {{ include "tm.fullname" . }}-config
{{- end }}
{{- end }}

{{/* Migrator init container: idempotent, serialized by an advisory lock
(pgsql); runs before the web pod and before every engine run, so neither
works on an older schema after an image upgrade. */}}
{{- define "tm.migrateContainer" -}}
- name: migrate
  image: {{ include "tm.image" . }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  command: [php, /app/migrate.php]
  env:
    {{- include "tm.env" . | nindent 4 }}
    {{- with .Values.database.baselineVersion }}
    - name: TM_DB_BASELINE_VERSION
      value: {{ . | quote }}
    {{- end }}
  securityContext:
    {{- toYaml .Values.securityContext | nindent 4 }}
  resources:
    {{- toYaml .Values.migrate.resources | nindent 4 }}
  volumeMounts:
    {{- include "tm.volumeMounts" . | nindent 4 }}
{{- end }}
