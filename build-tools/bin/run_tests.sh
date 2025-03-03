#!/bin/bash

set -x
set -o nounset
set -e

function usage() {
    set +x
    echo "Runs tests for the hotpatch agent."
    echo "Usage: run_tests.sh <Path to agent.jar> <JDK_ROOT>"
    echo "Optional params:"
    echo "    --classname <name of main class>:"
    echo "    --skip-static:  Skips tests of the static agent"
    echo "    --skip-security-manager: Skips testing with the securit manager"
    exit 1
}

function start_target() {

  if [[ -f /tmp/vuln.log ]]; then
    rm /tmp/vuln.log
  fi

  local jdk_dir=$1
  shift 1

  pushd "${ROOT_DIR}/test"
  ${jdk_dir}/bin/java  -cp log4j-core-2.12.1.jar:log4j-api-2.12.1.jar:. $* Vuln > /tmp/vuln.log 2>&1 &
  popd

  sleep 2
}

function start_static_target() {

  if [[ -f /tmp/vuln.log ]]; then
    rm /tmp/vuln.log
  fi

  local jdk_dir=$1
  local agent_jar=$2

  pushd "${ROOT_DIR}/test"
  ${jdk_dir}/bin/java  -cp log4j-core-2.12.1.jar:log4j-api-2.12.1.jar:. -javaagent:${agent_jar} Vuln > /tmp/vuln.log 2>&1 &
  popd
}

function verify_target() {
  local vuln_pid=$1

  # Wait a few seconds for the target to log the patched string
  sleep 3

  kill $vuln_pid

  if grep -q 'Patched JndiLookup' /tmp/vuln.log
  then
    echo "Successfully patched target process"
  else
    echo "Failed to patch target process"
    cat /tmp/vuln.log
    exit 1
  fi
}

function verify_idempotent_client() {
  if grep -q 'Skipping patch for JVM process' /tmp/client.log
  then
    echo "Did not patch already patched target"
  else
    echo "Failed or attempted to re-patch target"
    cat /tmp/client.log
    cat /tmp/vuln.log
    exit 1
  fi
}

function verify_idempotent_agent() {
    if grep -q 'hot patch agent already loaded' /tmp/vuln.log
    then
      echo "Agent knows it is already loaded"
    else
      echo "Agent reloaded itself"
      cat /tmp/client.log
      cat /tmp/vuln.log
      exit 1
    fi
}

if [[ $# -lt 2 ]]; then
    usage
    exit 1
fi

ROOT_DIR="$(pwd)"
# Need fully qualified path
AGENT_JAR=$(readlink -f $1)
JDK_DIR=$2
shift
shift

CLASSNAME="Log4jHotPatch"
SKIP_STATIC=""
SKIP_SECURITY_MANAGER=""
while [[ $# -gt 0 ]]; do
    case ${1} in
        --classname)
            CLASSNAME=${2}
            shift
            shift
            ;;
        --skip-static)
            SKIP_STATIC=1
            shift
            ;;
        --skip-security-manager)
            SKIP_SECURITY_MANAGER=1
            shift
            ;;
        * )
            echo "Unknown option '${1}'"
            usage
            ;;
    esac
done

JVM_MV=$(${JDK_DIR}/bin/java -XshowSettings:properties -version 2>&1 |grep java.vm.specification.version | cut -d'=' -f2 | tr -d ' ')

case ${JVM_MV} in
    1.7|1.8)
        CLASS_PATH=":${JDK_DIR}/lib/tools.jar"
        ;;
    *)
        CLASS_PATH=""
    ;;
esac

JVM_OPTIONS=""
if [[ "${JVM_MV}" == "17" ]]; then
    JVM_OPTIONS="--add-exports jdk.internal.jvmstat/sun.jvmstat.monitor=ALL-UNNAMED"
fi

pushd "${ROOT_DIR}/test"
${JDK_DIR}/bin/javac -cp log4j-core-2.12.1.jar:log4j-api-2.12.1.jar Vuln.java
popd

echo "******************"
echo "Running JDK${JVM_MV} -> JDK${JVM_MV} Test Idempotent"

start_target ${JDK_DIR}
VULN_PID=$!

${JDK_DIR}/bin/java -cp ${AGENT_JAR}${CLASS_PATH} \
${CLASSNAME} $VULN_PID > /tmp/client.log  2>&1

sleep 1
${JDK_DIR}/bin/java -cp ${AGENT_JAR}${CLASS_PATH} \
${CLASSNAME} $VULN_PID > /tmp/client.log  2>&1

verify_target $VULN_PID
verify_idempotent_client

echo "******************"
echo "Running JDK${JVM_MV} -> JDK${JVM_MV} Test"
start_target ${JDK_DIR}
VULN_PID=$!

${JDK_DIR}/bin/java -cp ${AGENT_JAR}${CLASS_PATH} ${CLASSNAME} $VULN_PID

verify_target $VULN_PID

echo "******************"
echo "Running StdErr only JDK${JVM_MV} -> JDK${JVM_MV} Test"

pushd "${ROOT_DIR}/test"
${JDK_DIR}/bin/java  -cp log4j-core-2.12.1.jar:log4j-api-2.12.1.jar:. $* Vuln > /tmp/vuln.out 2>/tmp/vuln.err &
VULN_PID=$!
popd
sleep 2

${JDK_DIR}/bin/java -cp ${AGENT_JAR}${CLASS_PATH} ${CLASSNAME} $VULN_PID > /tmp/client.out 2>/tmp/client.err

sleep 2
kill $VULN_PID

if [[ "$(stat -c%s /tmp/client.out)" != "0" ]]; then
  echo "Error: something went to stdout!"
  cat /tmp/client.out
  exit 1
fi

if ! grep -vq "\\\[main\\\] ERROR Vuln -" /tmp/vuln.out ; then
  echo "Error: something went to stdout!"
  cat /tmp/vuln.out
  exit 1
fi

echo "******************"
echo "Running Agent StdErr only JDK${JVM_MV} -> JDK${JVM_MV} Test"

pushd "${ROOT_DIR}/test"
${JDK_DIR}/bin/java  -javaagent:${AGENT_JAR} -cp log4j-core-2.12.1.jar:log4j-api-2.12.1.jar:. $* Vuln > /tmp/vuln.out 2>/tmp/vuln.err &
VULN_PID=$!
popd

sleep 3
kill $VULN_PID

if ! grep -vq "\\\[main\\\] ERROR Vuln -" /tmp/vuln.out ; then
  echo "Error: something went to stdout!"
  cat /tmp/vuln.out
  exit 1
fi

if [[ "${JVM_MV}" != "1.7"  && "${JVM_MV}" != "1.8" ]]; then
  echo "******************"
  echo "Running executable jar JDK${JVM_MV} -> JDK${JVM_MV} Test"
  start_target ${JDK_DIR}
  VULN_PID=$!

  ${JDK_DIR}/bin/java -jar ${AGENT_JAR} $VULN_PID

  verify_target $VULN_PID
fi

if [[ -z "${SKIP_SECURITY_MANAGER}" ]]; then
    echo "******************"
    echo "Running JDK${JVM_MV} -> JDK${JVM_MV} (Security Manager) Test"
    start_target ${JDK_DIR} -Djava.security.manager -Djava.security.policy=security.policy
    VULN_PID=$!

    ${JDK_DIR}/bin/java ${JVM_OPTIONS} -cp ${AGENT_JAR}${CLASS_PATH} ${CLASSNAME} $VULN_PID

    sleep 1
    ${JDK_DIR}/bin/java ${JVM_OPTIONS} -cp ${AGENT_JAR}${CLASS_PATH} ${CLASSNAME} $VULN_PID

    verify_target $VULN_PID
    verify_idempotent_agent
fi

if [[ -z "${SKIP_STATIC}" ]]; then
    echo "******************"
    echo "Running Static JDK${JVM_MV} Test"

    start_static_target ${JDK_DIR} ${AGENT_JAR}
    VULN_PID=$!

    sleep 2

    verify_target $VULN_PID

    echo "******************"
    echo "Running Static _JAVA_OPTIONS JDK${JVM_MV} Test"

    _JAVA_OPTIONS="-javaagent:${AGENT_JAR}"
    export _JAVA_OPTIONS
    start_target ${JDK_DIR}
    VULN_PID=$!

    sleep 2

    verify_target $VULN_PID

    echo "******************"
    echo "Running Static JAVA_TOOL_OPTIONS JDK${JVM_MV} Test"

    JAVA_TOOL_OPTIONS="-javaagent:${AGENT_JAR}"
    export JAVA_TOOL_OPTIONS
    start_target ${JDK_DIR}
    VULN_PID=$!

    sleep 2

    verify_target $VULN_PID
fi
