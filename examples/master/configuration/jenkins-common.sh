#!/bin/sh

export DEFAULT_SLAVE_DIRECTORY=/opt/app-root/jenkins
export JENKINS_HOME=/var/lib/jenkins
export CONFIG_PATH=${JENKINS_HOME}/config.xml
export PROJECT_NAME=${PROJECT_NAME:-ci}
export OPENSHIFT_API_URL=https://openshift.default.svc.cluster.local
export KUBE_CA=/run/secrets/kubernetes.io/serviceaccount/ca.crt
export AUTH_TOKEN=/run/secrets/kubernetes.io/serviceaccount/token
export JENKINS_PASSWORD KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
export ITEM_ROOTDIR="\${ITEM_ROOTDIR}" # Preserve this variable Jenkins has in config.xml
export K8S_PLUGIN_POD_TEMPLATES=""
export PATH=$PATH:${JENKINS_HOME}/.local/bin

export oc_auth="--token=$(cat $AUTH_TOKEN) --certificate-authority=${KUBE_CA}"
export oc_cmd="oc -n ${PROJECT_NAME} --server=$OPENSHIFT_API_URL ${oc_auth}"

function has_service_account() {
  [ -f "${AUTH_TOKEN}" ]
}

# get_imagestream_names returns a list of imagestreams names that contains
# label 'role=jenkins-slave'
function get_is_names() {
  $oc_cmd get is -l role=jenkins-slave -o template --template "{{range .items}}{{.metadata.name}} {{end}}"
}

# convert_is_to_slave converts the OpenShift imagestream to a Jenkins Kubernetes
# Plugin slave configuration.
function convert_is_to_slave() {
  local name=$1
  local template_file=$(mktemp)
  local template="
  <org.csanchez.jenkins.plugins.kubernetes.PodTemplate>
    <name>{{.metadata.name}}</name>
    <image>{{.status.dockerImageRepository}}</image>
    <privileged>false</privileged>
    <command></command>
    <args></args>
    <instanceCap>5</instanceCap>
    <volumes/>
    <remoteFs>{{if index .metadata.annotations \"slave-directory\"}}{{index .metadata.annotations \"slave-directory\"}}{{else}}${DEFAULT_SLAVE_DIRECTORY}{{end}}</remoteFs>
    <label>{{if index .metadata.annotations \"slave-label\"}}{{index .metadata.annotations \"slave-label\"}}{{else}}${name}{{end}}</label>
  </org.csanchez.jenkins.plugins.kubernetes.PodTemplate>
  "
  echo "${template}" > ${template_file}
  $oc_cmd get is/${name} -o templatefile --template ${template_file}
  rm -f ${template_file} &>/dev/null
}

# Generate passwd file based on current uid
function generate_passwd_file() {
  export USER_ID=$1
  export GROUP_ID=$2
  envsubst < /opt/openshift/passwd.template > /opt/openshift/passwd
  export LD_PRELOAD=libnss_wrapper.so
  export NSS_WRAPPER_PASSWD=/opt/openshift/passwd
  export NSS_WRAPPER_GROUP=/etc/group
}

function obfuscate_password {
    local password="$1"
    local acegi_security_path=`find /tmp/war/WEB-INF/lib/ -name acegi-security-*.jar`
    local commons_codec_path=`find /tmp/war/WEB-INF/lib/ -name commons-codec-*.jar`

    java -classpath "${acegi_security_path}:${commons_codec_path}:/opt/openshift/password-encoder.jar" com.redhat.openshift.PasswordEncoder $password
}

function generate_kubernetes_config() {
    local slave_templates=""
    if has_service_account; then
      for name in $(get_is_names); do
        echo "Adding ${name} imagestream as Jenkins Slave ..."
        slave_templates+=$(convert_is_to_slave ${name})
      done
    else
      return
    fi
    [ -z "${slave_templates}" ] && return
    echo "
    <org.csanchez.jenkins.plugins.kubernetes.KubernetesCloud plugin=\"kubernetes@0.5\">
      <name>openshift</name>
      <templates>
        ${slave_templates}
      </templates>
      <serverUrl>https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}</serverUrl>
      <skipTlsVerify>true</skipTlsVerify>
      <namespace>ci</namespace>
      <jenkinsUrl>http://jenkins:8080</jenkinsUrl>
      <credentialsId>1a12dfa4-7fc5-47a7-aa17-cc56572a41c7</credentialsId>
      <containerCap>10</containerCap>
      <retentionTimeout>5</retentionTimeout>
    </org.csanchez.jenkins.plugins.kubernetes.KubernetesCloud>
    "
}

function generate_kubernetes_credentials() {
  echo "<entry>
      <com.cloudbees.plugins.credentials.domains.Domain>
        <specifications/>
      </com.cloudbees.plugins.credentials.domains.Domain>
      <java.util.concurrent.CopyOnWriteArrayList>
        <org.csanchez.jenkins.plugins.kubernetes.ServiceAccountCredential plugin=\"kubernetes@0.5-SNAPSHOT\">
          <scope>GLOBAL</scope>
          <id>1a12dfa4-7fc5-47a7-aa17-cc56572a41c7</id>
          <description></description>
        </org.csanchez.jenkins.plugins.kubernetes.ServiceAccountCredential>
      </java.util.concurrent.CopyOnWriteArrayList>
    </entry>
    "
}
