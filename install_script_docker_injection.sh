#!/bin/bash
# (C) Datadog, Inc. 2010-present
# All rights reserved
# Licensed under Apache-2.0 License (see LICENSE)
# Datadog Agent installation script: install and set up the Agent on supported Linux distributions
# using the package manager and Datadog repositories.

set -e



install_script_version=1.26.0
logfile="ddagent-install.log"
support_email=support@datadoghq.com
variant=install_script_docker_injection

LEGACY_ETCDIR="/etc/dd-agent"
LEGACY_CONF="$LEGACY_ETCDIR/datadog.conf"

# DATADOG_APT_KEY_CURRENT.public always contains key used to sign current
# repodata and newly released packages
# DATADOG_APT_KEY_382E94DE.public expires in 2022
# DATADOG_APT_KEY_F14F620E.public expires in 2032
# DATADOG_APT_KEY_C0962C7D.public expires in 2028
APT_GPG_KEYS=("DATADOG_APT_KEY_CURRENT.public" "DATADOG_APT_KEY_C0962C7D.public" "DATADOG_APT_KEY_F14F620E.public" "DATADOG_APT_KEY_382E94DE.public")

# DATADOG_RPM_KEY_CURRENT.public always contains key used to sign current
# repodata and newly released packages
# DATADOG_RPM_KEY_E09422B3.public expires in 2022
# DATADOG_RPM_KEY_FD4BF915.public expires in 2024
# DATADOG_RPM_KEY_B01082D3.public expires in 2028
RPM_GPG_KEYS=("DATADOG_RPM_KEY_CURRENT.public" "DATADOG_RPM_KEY_B01082D3.public" "DATADOG_RPM_KEY_FD4BF915.public" "DATADOG_RPM_KEY_E09422B3.public")

# DATADOG_RPM_KEY.public (4172A230) was only useful to install old (< 6.14) Agent packages.
# We no longer add it and we explicitly remove it.
RPM_GPG_KEYS_TO_REMOVE=("gpg-pubkey-4172a230-55dd14f6")

# Error codes for telemetry
GENERAL_ERROR_CODE=1
UNSUPPORTED_PLATFORM_CODE=5
INVALID_PARAMETERS_CODE=6
UNABLE_TO_INSTALL_DEPENDENCY_CODE=7

# Set up a named pipe for logging
npipe=/tmp/$$.tmp
mknod $npipe p

# Log all output to a log for error checking
tee <$npipe $logfile &
exec 1>&-
exec 1>$npipe 2>&1
trap 'rm -f $npipe' EXIT

##
# REPORTING AND COMMON METHODS
##
function fallback_msg(){
  printf "
If you are still having problems, please send an email to $support_email
with the contents of $logfile and any information you think would be
useful and we will do our very best to help you solve your problem.\n"
}

function report(){
  if curl -f -s \
    --data-urlencode "os=${OS}" \
    --data-urlencode "version=${agent_major_version}" \
    --data-urlencode "log=$(cat $logfile)" \
    --data-urlencode "email=${email}" \
    --data-urlencode "apikey=${apikey}" \
    --data-urlencode "variant=${variant}" \
    "$report_failure_url"; then
   printf "A notification has been sent to Datadog with the contents of $logfile\n"
  else
    printf "Unable to send the notification (curl v7.18 or newer is required)"
  fi
}

function report_telemetry() {
  local install_id="$1"
  local install_type="$2"
  local install_time="$3"

  if [ "$DD_INSTRUMENTATION_TELEMETRY_ENABLED" == "false" ] || \
    [ "$site" == "ddog-gov.com" ] || \
    [ -z "${apikey}" ] || \
    [ -z "$telemetry_url" ]; then
    return
  fi

  install_id_tag=
  install_type_tag=
  install_time_tag=
  if [ -n "$install_id" ] ; then
    install_id_tag="\"install_id\": \"$install_id\","
  fi
  if [ -n "$install_type" ] ; then
    install_type_tag="\"install_type\": \"$install_type\","
  fi
  if [ -n "$install_time" ] ; then
    install_time_tag="\"install_time\": $install_time,"
  fi

  if [ -n "$agent_minor_version" ] ; then
    safe_agent_version=$(echo -n "$agent_major_version.$agent_minor_version" | tr '\n' ' ' | tr '"' '_')
  else
    safe_agent_version=$(echo -n "$agent_major_version" | tr '\n' ' ' | tr '"' '_')
  fi

  library_telemetry_info=

  if [ ${#apm_libraries[@]} -gt 0 ]; then
    for lib in "${apm_libraries[@]}"
    do
      cur_lib=$(echo "$lib" | cut -s -d':' -f1)
      cur_version=$(echo "$lib" | cut -s -d':' -f2)
      if [ -z "$cur_version" ] ; then
        cur_version="default"
        cur_lib="$lib"
      fi
      case $cur_lib in
        datadog-apm-library-java)
          library_telemetry_info="${library_telemetry_info},\"specified_java_lib_version\": \"${cur_version}\""
          ;;
        datadog-apm-library-js)
          library_telemetry_info="${library_telemetry_info},\"specified_nodejs_lib_version\": \"${cur_version}\""
          ;;
        datadog-apm-library-python)
          library_telemetry_info="${library_telemetry_info},\"specified_python_lib_version\": \"${cur_version}\""
          ;;
        datadog-apm-library-dotnet)
          library_telemetry_info="${library_telemetry_info},\"specified_dotnet_lib_version\": \"${cur_version}\""
          ;;
        datadog-apm-library-ruby)
          library_telemetry_info="${library_telemetry_info},\"specified_ruby_lib_version\": \"${cur_version}\""
          ;;
        *)
          ;;
      esac
    done
  fi

  safe_agent_version=noagent_autoinstrumentation
  if [ -z "${ERROR_CODE}" ] ; then
    telemetry_event="
{
   \"request_type\": \"apm-onboarding-event\",
   \"api_version\": \"v1\",
   \"payload\": {
       \"event_name\": \"agent.installation.success\",
       \"tags\": {
           $install_id_tag
           $install_type_tag
           $install_time_tag
           \"agent_platform\": \"native\",
           \"agent_version\": \"$safe_agent_version\",
           \"script_version\": \"$install_script_version\" $library_telemetry_info
       }
   }
}
"
  else
    safe_error_message=$(echo -n "$ERROR_MESSAGE" | tr '\n' ' ' | tr '"' '_')
    # Install ID, time and type are typically not reported if the installation does not succeed,
    # but if the function is called with those arguments, we will pass them along anyway.
    telemetry_event="
{
   \"request_type\": \"apm-onboarding-event\",
   \"api_version\": \"v1\",
   \"payload\": {
       \"event_name\": \"agent.installation.error\",
       \"tags\": {
           $install_id_tag
           $install_type_tag
           $install_time_tag
           \"agent_platform\": \"native\",
           \"agent_version\": \"$safe_agent_version\",
           \"script_version\": \"$install_script_version\" $library_telemetry_info
       },
       \"error\": {
          \"code\": $ERROR_CODE,
          \"message\": \"$safe_error_message\"
       }
   }
}
"
  fi

  if ! (cat <<END
       $telemetry_event
END
       ) | curl --fail --silent --output /dev/null \
    "$telemetry_url" \
    --header 'Content-Type: application/json' \
    --header "DD-Api-Key: $apikey" \
    --data @-
  then
    printf "Unable to send telemetry\n"
  fi
}

function on_read_error() {
  printf "Timed out or input EOF reached, assuming 'No'\n"
  yn="n"
}

function get_email() {
  emaillocalpart='^[a-zA-Z0-9][a-zA-Z0-9._%+-]{0,63}'
  hostnamepart='[a-zA-Z0-9.-]+\.[a-zA-Z]+'
  email_regex="$emaillocalpart@$hostnamepart"
  cntr=0
  until [[ "$cntr" -eq 3 ]]
  do
      read -p "Enter an email address so we can follow up: " -r email
      if [[ "$email" =~ $email_regex ]]; then
        isEmailValid=true
        break
      else
        ((cntr=cntr+1))
        echo -e "\033[33m($cntr/3) Email address invalid: $email\033[0m\n"
      fi
  done
}

function on_error() {
    if [ -z "${ERROR_MESSAGE}" ] ; then
      # Save the few lines of the log file for telemetry if the error message is blank
      SAVED_ERROR_MESSAGE=$(tail -n 3 $logfile)
    fi

    printf "\033[31m$ERROR_MESSAGE
It looks like you hit an issue when trying to install the $nice_flavor.

    $ERR_SUMMARY

Troubleshooting and basic usage information for the $nice_flavor are available at:

    https://docs.datadoghq.com/agent/basic_agent_usage/\n\033[0m\n"

    ERROR_MESSAGE=$SAVED_ERROR_MESSAGE
    ERROR_CODE=$GENERAL_ERROR_CODE
    report_telemetry

    if ! tty -s; then
      fallback_msg
      exit 1;
    fi

    if [ "$site" == "ddog-gov.com" ]; then
      fallback_msg
      exit 1;
    fi

    while true; do
        read -t 60 -p  "Do you want to send a failure report to Datadog (including $logfile)? (y/[n]) " -r yn || on_read_error
        case $yn in
          [Yy]* )
            get_email
            if [[ -n "$isEmailValid" ]]; then
              report
            fi
            fallback_msg
            break;;
          [Nn]*|"" )
            fallback_msg
            break;;
          * )
            printf "Please answer yes or no.\n"
            ;;
        esac
    done
}
trap on_error ERR

function verify_agent_version(){
    local ver_separator="$1"
    if [ -z "$agent_version_custom" ]; then
        ERROR_MESSAGE="Specified version not found: $agent_major_version.$agent_minor_version"
        ERROR_CODE=$INVALID_PARAMETERS_CODE
        echo -e "
  \033[33mWarning: $ERROR_MESSAGE
  Check available versions at: https://github.com/DataDog/datadog-agent/blob/main/CHANGELOG.rst\033[0m"
        fallback_msg
        report_telemetry
        exit 1;
    else
        agent_flavor+="$ver_separator$agent_version_custom"
    fi
}

function remove_rpm_gpg_keys() {
    local sudo_cmd="$1"
    shift
    local old_keys=("$@")
    for key in "${old_keys[@]}"; do
        if $sudo_cmd rpm -q "$key" 1>/dev/null 2>/dev/null; then
            echo -e "\033[34m\nRemoving old RPM key $key from the RPM database\n\033[0m"
            $sudo_cmd rpm --erase "$key"
        fi
    done
}

# Emulate hashmap with simple switch case
function getMapData() {

    if [ "$1" = "flavor_to_readable" ]; then
        case "$2" in
            "datadog-agent")
                DATA="Datadog Agent"
                ;;
             "datadog-iot-agent")
                DATA="Datadog IoT Agent"
                ;;
             "datadog-dogstatsd")
                DATA="Datadog Dogstatsd"
                ;;
             "datadog-fips-proxy")
                DATA="Datadog FIPS Proxy"
                ;;
             "datadog-heroku-agent")
                DATA="Datadog Heroku Agent"
                ;;
              *)
                DATA="Unknown"
                ;;
         esac
    fi
    printf '%s' "$DATA"
}

# Create a configuration file with proper ownership and permission if it doesn't already exist
function ensure_config_file_exists() {
    local sudo_cmd="$1"
    local config_file="$2"
    local owner="$3"

    if [ -e "$config_file" ]; then
        printf "\033[34m\n* Keeping old $config_file configuration file\n\033[0m\n"
        return 1
    else
        $sudo_cmd cp "$config_file.example" "$config_file"
        cp_res=$?
        $sudo_cmd chown "$owner:dd-agent" "$config_file"
        chown_res=$?
        $sudo_cmd chmod 640 "$config_file"
        chmod_res=$?
        return $((cp_res + chown_res + chmod_res))
    fi
}

echo -e "\033[34m\n* Datadog Docker Injection install script v${install_script_version}\n\033[0m"

##
# AGENT CONFIGURATION OPTIONS
# They are only considered if the configuration file does not already exist (call to `ensure_config_file_exist`)
##
hostname=
if [ -n "$DD_HOSTNAME" ]; then
    hostname=$DD_HOSTNAME
fi

site=
if [ -n "$DD_SITE" ]; then
    site="$DD_SITE"
fi

apikey=
if [ -n "$DD_API_KEY" ]; then
    apikey=$DD_API_KEY
fi

no_start=
if [ -n "$DD_INSTALL_ONLY" ]; then
    no_start=true
fi

no_agent=
if [ -n "$DD_NO_AGENT_INSTALL" ]; then
    no_agent=true
fi

host_tags=  # A comma-separated list of tags, e.g. foo:bar,env:prod
if [ -n "$DD_HOST_TAGS" ]; then
    host_tags=$DD_HOST_TAGS
fi

if [ -n "$DD_REPO_URL" ]; then
    repository_url=$DD_REPO_URL
elif [ -n "$REPO_URL" ]; then
    echo -e "\033[33mWarning: REPO_URL is deprecated and might be removed later (use DD_REPO_URL instead).\033[0m"
    repository_url=$REPO_URL
else
    repository_url="datadoghq.com"
fi

upgrade=
if [ -n "$DD_UPGRADE" ]; then
  upgrade=$DD_UPGRADE
fi

fips_mode=
if [ -n "$DD_FIPS_MODE" ]; then
  fips_mode=$DD_FIPS_MODE
fi

dd_env=
if [ -n "$DD_ENV" ]; then
    dd_env=$DD_ENV
fi

system_probe_ensure_config=
if [ -n "$DD_SYSTEM_PROBE_ENSURE_CONFIG" ]; then
  system_probe_ensure_config=$DD_SYSTEM_PROBE_ENSURE_CONFIG
fi

agent_flavor="datadog-agent"
if [ -n "$DD_AGENT_FLAVOR" ]; then
    agent_flavor=$DD_AGENT_FLAVOR #Eg: datadog-iot-agent
fi


##
# INSTALL SCRIPT CONFIGURATION OPTIONS
# Technical options to test with non-production values for signature keys, packages or reporting telemetry.
##
if [ -n "$TESTING_KEYS_URL" ]; then
  keys_url=$TESTING_KEYS_URL
else
  keys_url="keys.datadoghq.com"
fi

if [ -n "$TESTING_YUM_URL" ]; then
  yum_url=$TESTING_YUM_URL
else
  yum_url="yum.${repository_url}"
fi

# We turn off `repo_gpgcheck` for custom REPO_URL, unless explicitly turned
# on via DD_RPM_REPO_GPGCHECK.
# There is more logic for redhat/suse in their specific code branches below
rpm_repo_gpgcheck=
if [ -n "$DD_RPM_REPO_GPGCHECK" ]; then
    rpm_repo_gpgcheck=$DD_RPM_REPO_GPGCHECK
else
    if [ -n "$REPO_URL" ] || [ -n "$DD_REPO_URL" ]; then
        rpm_repo_gpgcheck=0
    fi
fi

if [ -n "$TESTING_APT_URL" ]; then
  apt_url=$TESTING_APT_URL
else
  apt_url="apt.${repository_url}"
fi

report_failure_url="https://api.datadoghq.com/agent_stats/report_failure"
if [ -n "$DD_SITE" ]; then
    report_failure_url="https://api.${DD_SITE}/agent_stats/report_failure"
fi

telemetry_url="https://instrumentation-telemetry-intake.datadoghq.com/api/v2/apmtelemetry"
if [ -n "$DD_SITE" ]; then
    telemetry_url="https://instrumentation-telemetry-intake.${DD_SITE}/api/v2/apmtelemetry"
fi

if [ -n "$TESTING_REPORT_URL" ]; then
  report_failure_url=$TESTING_REPORT_URL
  telemetry_url=$TESTING_REPORT_URL
fi

##
# APM SPECIFIC CONFIGURATION
##
declare -a apm_libraries
declare host_injection_enabled
declare docker_injection_enabled
install_type="linux_agent_installer"
DD_APM_INSTRUMENTATION_ENABLED="docker"

if [ "$DD_APM_INSTRUMENTATION_ENABLED" = "all" ] ; then
  host_injection_enabled="true"
  docker_injection_enabled="true"
  install_type="linux_single_step_all"
fi

if [ "$DD_APM_INSTRUMENTATION_ENABLED" = "host" ] ; then
  host_injection_enabled="true"
  install_type="linux_single_step_hst"
fi

if [ "$DD_APM_INSTRUMENTATION_ENABLED" = "docker" ] ; then
  docker_injection_enabled="true"
  install_type="linux_single_step_dkr"
  no_agent=true
fi

if [ -n "${host_injection_enabled}${docker_injection_enabled}" ] ; then
    apm_libraries=("datadog-apm-inject")
fi

if [ -n "${host_injection_enabled}" ] && [ -n "${no_agent}" ] ; then
    ERROR_MESSAGE="Host injection is not supported with the DD_NO_AGENT_INSTALL flag. Unset either DD_APM_INSTRUMENTATION_ENABLED or DD_NO_AGENT_INSTALL"
    ERROR_CODE=$INVALID_PARAMETERS_CODE
    echo -e "\033[31m$ERROR_MESSAGE\033[0m\n"
    report_telemetry
    exit 1;
fi

docker_config_dir="/etc/docker"

if [ -n "$docker_injection_enabled" ]; then
    if [ ! -d "$docker_config_dir" ]; then
      ERROR_MESSAGE="$docker_config_dir does not exist. Please ensure docker is installed"
      ERROR_CODE=$INVALID_PARAMETERS_CODE
      echo -e "\033[31m$ERROR_MESSAGE\033[0m\n"
      report_telemetry
      exit 1;
    fi
fi

if [ -n "$DD_APM_INSTRUMENTATION_LIBRARIES" ]; then
  read -r -a lib_array <<< "$(echo "$DD_APM_INSTRUMENTATION_LIBRARIES" | tr , ' ')"
  for lib in "${lib_array[@]}"
  do
    cur_lib=$(echo "$lib" | cut -s -d':' -f1)
    cur_version=$(echo "$lib" | cut -s -d':' -f2)
    if [ -z "$cur_lib" ] ; then
      cur_lib="$lib"
    elif [ "$cur_version" = "latest" ] ; then
      cur_version=""
    else
      cur_version=":${cur_version}-1"
    fi
    case $cur_lib in
      all)
        apm_libraries+=("datadog-apm-library-java" "datadog-apm-library-js" "datadog-apm-library-python" "datadog-apm-library-dotnet" "datadog-apm-library-ruby")
        ;;
      java)
        apm_libraries+=("datadog-apm-library-java${cur_version}")
        ;;
      js)
        apm_libraries+=("datadog-apm-library-js${cur_version}")
        ;;
      python)
        apm_libraries+=("datadog-apm-library-python${cur_version}")
        ;;
      dotnet)
        apm_libraries+=("datadog-apm-library-dotnet${cur_version}")
        ;;
      ruby)
        apm_libraries+=("datadog-apm-library-ruby${cur_version}")
        ;;
      *)
        ERROR_MESSAGE="Unknown apm library: $cur_lib. Must be one of: all, java, js, python, dotnet, ruby"
        ERROR_CODE=$INVALID_PARAMETERS_CODE
        echo "$ERROR_MESSAGE"
        report_telemetry
        exit 1;
        ;;
    esac
  done
elif [ -n "$DD_APM_INSTRUMENTATION_LANGUAGES" ]; then
  read -r -a lib_array <<< "$DD_APM_INSTRUMENTATION_LANGUAGES"
  for lib in "${lib_array[@]}"
  do
    case $lib in
      all)
        apm_libraries+=("datadog-apm-library-java" "datadog-apm-library-js" "datadog-apm-library-python" "datadog-apm-library-dotnet" "datadog-apm-library-ruby")
        ;;
      java)
        apm_libraries+=("datadog-apm-library-java")
        ;;
      js)
        apm_libraries+=("datadog-apm-library-js")
        ;;
      python)
        apm_libraries+=("datadog-apm-library-python")
        ;;
      dotnet)
        apm_libraries+=("datadog-apm-library-dotnet")
        ;;
      ruby)
        apm_libraries+=("datadog-apm-library-ruby")
        ;;
      *)
        ERROR_MESSAGE="Unknown apm library: $lib. Must be one of: all, java, js, python, dotnet, ruby"
        ERROR_CODE=$INVALID_PARAMETERS_CODE
        echo "$ERROR_MESSAGE"
        report_telemetry
        exit 1;
        ;;
    esac
  done
elif [ -n "$host_injection_enabled" ] || [ -n "$docker_injection_enabled" ]; then
  # Default to all libraries if injection is enabled
  apm_libraries+=("datadog-apm-library-java" "datadog-apm-library-js" "datadog-apm-library-python" "datadog-apm-library-dotnet" "datadog-apm-library-ruby")
fi

no_config_change=
if [ -n "$DD_APM_INSTRUMENTATION_NO_CONFIG_CHANGE" ]; then
  no_config_change="--no-config-change"
fi

##
# SETUP & VALIDATE CONFIGURATION
##

nice_flavor=$(getMapData flavor_to_readable "$agent_flavor")

if [ -z "$nice_flavor" ]; then
    ERROR_MESSAGE="Unknown DD_AGENT_FLAVOR \"$agent_flavor\""
    ERROR_CODE=$INVALID_PARAMETERS_CODE
    echo -e "\033[33m$ERROR_MESSAGE\033[0m"
    fallback_msg
    report_telemetry
    exit 1;
fi

if [ "$agent_flavor" = "datadog-dogstatsd" ]; then
    system_service="datadog-dogstatsd"
    etcdir="/etc/datadog-dogstatsd"
    config_file="$etcdir/dogstatsd.yaml"
fi

if [ -z "$system_service" ]; then
    system_service="datadog-agent"
fi

declare -a services

if [ -n "$no_agent" ]; then
  services=()
else
  services=("$system_service")
fi

if [ -n "$fips_mode" ]; then
  services+=("datadog-fips-proxy")
fi

if [ -z "$etcdir" ]; then
    etcdir="/etc/datadog-agent"
fi

etcdirfips=/etc/datadog-fips-proxy

if [ -z "$config_file" ]; then
    config_file="$etcdir/datadog.yaml"
fi

config_file_fips=$etcdirfips/datadog-fips-proxy.cfg
system_probe_config_file=$etcdir/system-probe.yaml
security_agent_config_file=$etcdir/security-agent.yaml

agent_major_version=7
# shellcheck disable=SC2050
# ^ to disable the warning about constant comparison in the elif clause below
if [ -n "$DD_AGENT_MAJOR_VERSION" ]; then
  if [ "$DD_AGENT_MAJOR_VERSION" != "6" ] && [ "$DD_AGENT_MAJOR_VERSION" != "7" ]; then
    ERROR_MESSAGE="DD_AGENT_MAJOR_VERSION must be either 6 or 7. Current value: $DD_AGENT_MAJOR_VERSION"
    ERROR_CODE=$INVALID_PARAMETERS_CODE
    echo "$ERROR_MESSAGE"
    report_telemetry
    exit 1;
  fi
  agent_major_version=$DD_AGENT_MAJOR_VERSION
elif [ "" == "true" ]; then
  if [ "$agent_flavor" == "datadog-agent" ] ; then
    echo -e "\033[33mWarning: DD_AGENT_MAJOR_VERSION not set. Installing $nice_flavor version 6 by default.\033[0m"
  else
    echo -e "\033[33mWarning: DD_AGENT_MAJOR_VERSION not set. Installing $nice_flavor version 7 by default.\033[0m"
    agent_major_version=7
  fi
fi

if [ -n "$DD_AGENT_MINOR_VERSION" ]; then
  # Examples:
  #  - 20   = defaults to highest patch version x.20.2
  #  - 20.0 = sets explicit patch version x.20.0
  # Note: Specifying an invalid minor version will terminate the script.
  agent_minor_version=${DD_AGENT_MINOR_VERSION}
  # Handle pre-release versions like "35.0~rc.5" -> "35.0" or "27.1~viper~conflict~fix" -> "27.1"
  # Allow to get a "clean" version number that can be used to compare the version with others (e.g: "35.0~rc.5" < "36.0" because "35.0" < "36.0")
  clean_agent_minor_version=$(echo "${DD_AGENT_MINOR_VERSION}" | sed -E 's/~.*//g')
  # remove the patch version if the minor version includes it (eg: 33.1 -> 33)
  agent_minor_version_without_patch="${clean_agent_minor_version%.*}"
fi

agent_dist_channel=stable
if [ -n "$DD_AGENT_DIST_CHANNEL" ]; then
  if [ "$repository_url" == "datadoghq.com" ]; then
    if [ "$DD_AGENT_DIST_CHANNEL" != "stable" ] && [ "$DD_AGENT_DIST_CHANNEL" != "beta" ]; then
      ERROR_MESSAGE="DD_AGENT_DIST_CHANNEL must be either 'stable' or 'beta'. Current value: $DD_AGENT_DIST_CHANNEL"
      ERROR_CODE=$INVALID_PARAMETERS_CODE
      echo "$ERROR_MESSAGE"
      report_telemetry
      exit 1;
    fi
  elif [ "$DD_AGENT_DIST_CHANNEL" != "stable" ] && [ "$DD_AGENT_DIST_CHANNEL" != "beta" ] && [ "$DD_AGENT_DIST_CHANNEL" != "nightly" ]; then
    ERROR_MESSAGE="DD_AGENT_DIST_CHANNEL must be either 'stable', 'beta' or 'nightly' on custom repos. Current value: $DD_AGENT_DIST_CHANNEL"
    ERROR_CODE=$INVALID_PARAMETERS_CODE
    echo "$ERROR_MESSAGE"
    report_telemetry
    exit 1;
  fi
  agent_dist_channel=$DD_AGENT_DIST_CHANNEL
fi

if [ -n "$TESTING_YUM_VERSION_PATH" ]; then
  yum_version_path=$TESTING_YUM_VERSION_PATH
else
  yum_version_path="${agent_dist_channel}/${agent_major_version}"
fi

if [ -n "$TESTING_APT_REPO_VERSION" ]; then
  apt_repo_version=$TESTING_APT_REPO_VERSION
else
  apt_repo_version="${agent_dist_channel} ${agent_major_version}"
fi

if [ ! "$apikey" ]; then
  # if it's an upgrade, then we will use the transition script
  if [ ! "$upgrade" ] && [ ! -e "$config_file" ] && [ ! "$no_agent" ]; then
    printf "\033[31mAPI key not available in DD_API_KEY environment variable.\033[0m\n"
    exit 1;
  fi
fi

if [[ $(uname -m) == "armv7l" ]] && [[ $agent_flavor == "datadog-agent" ]] && [ ! "$no_agent" ]; then
    ERROR_MESSAGE="The full $nice_flavor isn't available for your architecture (armv7l).\nInstall the $(getMapData flavor_to_readable datadog-iot-agent) by setting DD_AGENT_FLAVOR='datadog-iot-agent'."
    ERROR_CODE=$UNSUPPORTED_PLATFORM_CODE
    printf "\033[31m$ERROR_MESSAGE\033[0m\n"
    report_telemetry
    exit 1;
fi

if [ ${#apm_libraries[@]} -gt 0 ] && [ "$agent_major_version" = "6" ] ; then
  ERROR_MESSAGE="APM library injection is not supported with Agent version 6"
  ERROR_CODE=$INVALID_PARAMETERS_CODE
  echo -e "\033[31m$ERROR_MESSAGE\033[0m\n"
  report_telemetry
  exit 1;
fi

# OS/Distro Detection
# Try lsb_release, fallback with /etc/issue then uname command
KNOWN_DISTRIBUTION="(Debian|Ubuntu|RedHat|CentOS|openSUSE|Amazon|Arista|SUSE|Rocky|AlmaLinux)"
DISTRIBUTION=$(lsb_release -d 2>/dev/null | grep -Eo $KNOWN_DISTRIBUTION  || grep -Eo $KNOWN_DISTRIBUTION /etc/issue 2>/dev/null || grep -Eo $KNOWN_DISTRIBUTION /etc/Eos-release 2>/dev/null || grep -m1 -Eo $KNOWN_DISTRIBUTION /etc/os-release 2>/dev/null || uname -s)

if [ "$DISTRIBUTION" == "Darwin" ]; then
    ERROR_MESSAGE="This script does not support installing on the Mac."
    ERROR_CODE=$UNSUPPORTED_PLATFORM_CODE
    printf "\033[31m$ERROR_MESSAGE

Please use the 1-step script available at https://app.datadoghq.com/account/settings#agent/mac.\033[0m\n"
    report_telemetry
    exit 1;

elif [ -f /etc/debian_version ] || [ "$DISTRIBUTION" == "Debian" ] || [ "$DISTRIBUTION" == "Ubuntu" ]; then
    OS="Debian"
elif [ -f /etc/redhat-release ] || [ "$DISTRIBUTION" == "RedHat" ] || [ "$DISTRIBUTION" == "CentOS" ] || [ "$DISTRIBUTION" == "Amazon" ] || [ "$DISTRIBUTION" == "Rocky" ] || [ "$DISTRIBUTION" == "AlmaLinux" ]; then
    OS="RedHat"
# Some newer distros like Amazon may not have a redhat-release file
elif [ -f /etc/system-release ] || [ "$DISTRIBUTION" == "Amazon" ]; then
    OS="RedHat"
# Arista is based off of Fedora14/18 but do not have /etc/redhat-release
elif [ -f /etc/Eos-release ] || [ "$DISTRIBUTION" == "Arista" ]; then
    OS="RedHat"
# openSUSE and SUSE use /etc/SuSE-release or /etc/os-release
elif [ -f /etc/SuSE-release ] || [ "$DISTRIBUTION" == "SUSE" ] || [ "$DISTRIBUTION" == "openSUSE" ]; then
    OS="SUSE"
fi

if [[ "$agent_flavor" == "datadog-dogstatsd" ]]; then
    if [[ $(uname -m) == "armv7l" ]] || { [[ $(uname -m) != "x86_64" ]] && [[ "$OS" != "Debian" ]]; }; then
        ERROR_MESSAGE="The $nice_flavor isn't available for your architecture."
        ERROR_CODE=$UNSUPPORTED_PLATFORM_CODE
        printf "\033[31m$ERROR_MESSAGE\033[0m\n"
        report_telemetry
        exit 1;
    fi
    if  [[ "$OS" == "Debian" ]] && [[ $(uname -m) == "aarch64" ]] && { [[ -n "$agent_minor_version_without_patch" ]] && [[ "$agent_minor_version_without_patch" -lt 35 ]]; }; then
        ERROR_MESSAGE="The $nice_flavor is only available since version 7.35.0 for your architecture."
        ERROR_CODE=$UNSUPPORTED_PLATFORM_CODE
        printf "\033[31m$ERROR_MESSAGE\033[0m\n"
        report_telemetry
        exit 1;
    fi
fi

if [ -n "$fips_mode" ]; then
    UNAME_M=$(uname -m)
    if [[ ${UNAME_M} != "x86_64" ]] && [[ ${UNAME_M} != "aarch64" ]]; then
        ERROR_MESSAGE="FIPS mode isn't available for your architecture"
        ERROR_CODE=$UNSUPPORTED_PLATFORM_CODE
        printf "\033[31m$ERROR_MESSAGE\033[0m\n"
        report_telemetry
        exit 1;
    fi
    if [[ -n "$agent_minor_version_without_patch" ]] && [[ "${agent_minor_version_without_patch}" -lt 41 ]]; then
        ERROR_MESSAGE="FIPS mode is only available since version 7.41.0 and requested minor version is $agent_minor_version"
        ERROR_CODE=$INVALID_PARAMETERS_CODE
        printf "\033[31m$ERROR_MESSAGE\033[0m\n"
        report_telemetry
        exit 1;
    fi
fi

# Root user detection
if [ "$UID" == "0" ]; then
    sudo_cmd=''
else
    sudo_cmd='sudo'
fi

##
# INSTALL THE NECESSARY PACKAGE SOURCES
##
if [ "$OS" == "RedHat" ]; then
    remove_rpm_gpg_keys "$sudo_cmd" "${RPM_GPG_KEYS_TO_REMOVE[@]}"
    if { [ "$DISTRIBUTION" == "Rocky" ] || [ "$DISTRIBUTION" == "AlmaLinux" ]; } && { [ -n "$agent_minor_version_without_patch" ] && [ "$agent_minor_version_without_patch" -lt 33 ]; } && ! echo "$agent_flavor" | grep '[0-9]' > /dev/null; then
        ERROR_MESSAGE="A future version of $nice_flavor will support $DISTRIBUTION"
        ERROR_CODE=$UNSUPPORTED_PLATFORM_CODE
        echo -e "\033[33m$ERROR_MESSAGE\n\033[0m"
        report_telemetry
        exit;
    fi
    echo -e "\033[34m\n* Installing YUM sources for Datadog\n\033[0m"

    UNAME_M=$(uname -m)
    if [ "$UNAME_M" == "i686" ] || [ "$UNAME_M" == "i386" ] || [ "$UNAME_M" == "x86" ]; then
        ARCHI="i386"
    elif [ "$UNAME_M" == "aarch64" ]; then
        ARCHI="aarch64"
    else
        ARCHI="x86_64"
    fi

    # Because of https://bugzilla.redhat.com/show_bug.cgi?id=1792506, we disable
    # repo_gpgcheck on RHEL/CentOS 8.1
    if [ -z "$rpm_repo_gpgcheck" ]; then
        if grep -q "8\.1\(\b\|\.\)" /etc/redhat-release 2>/dev/null; then
            rpm_repo_gpgcheck=0
        else
            rpm_repo_gpgcheck=1
        fi
    fi

    gpgkeys=''
    separator='\n       '
    for key_path in "${RPM_GPG_KEYS[@]}"; do
      gpgkeys="${gpgkeys:+"${gpgkeys}${separator}"}https://${keys_url}/${key_path}"
    done

    # if some packages were previously pinned (using excludepkgs)
    # this will unpin them as a side effect
    $sudo_cmd sh -c "echo -e '[datadog]\nname = Datadog, Inc.\nbaseurl = https://${yum_url}/${yum_version_path}/${ARCHI}/\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=${rpm_repo_gpgcheck}\npriority=1\ngpgkey=${gpgkeys}' > /etc/yum.repos.d/datadog.repo"

    $sudo_cmd yum -y clean metadata

    dnf_flag=""
    if [ -f "/usr/bin/dnf" ] && { [ ! -f "/usr/bin/yum" ] || [ -L "/usr/bin/yum" ]; } ; then
      # On modern Red Hat based distros, yum is an alias (symlink) of dnf.
      # "dnf install" doesn't upgrade a package if a newer version
      # is available, unless the --best flag is set
      # NOTE: we assume that sometime in the future "/usr/bin/yum" will
      # be removed altogether, so we test for that as well.
      dnf_flag="--best"
    fi

    if [ -n "$agent_minor_version" ]; then
        # Example: datadog-agent-7.20.2-1
        pkg_pattern="$agent_major_version\.${agent_minor_version%.}(\.[[:digit:]]+){0,1}(-[[:digit:]])?"
        agent_version_custom="$(yum -y --disablerepo=* --enablerepo=datadog list --showduplicates datadog-agent | sort -r | grep -E "$pkg_pattern" -om1)" || true
        verify_agent_version "-"
    fi

    declare -a packages
    if [ -n "$no_agent" ]; then
      packages=()
    else
      packages=("$agent_flavor")
    fi

    if [ -n "$fips_mode" ]; then
      packages+=("datadog-fips-proxy")
    fi

    excludepkgs=""
    if [ ${#apm_libraries[@]} -gt 0 ]; then
      for lib in "${apm_libraries[@]}"
      do
        cur_lib=$(echo "$lib" | cut -s -d':' -f1)
        cur_version=$(echo "$lib" | cut -s -d':' -f2)
        if [ -z "$cur_lib" ] ; then
          packages+=("${lib}")
        else
          packages+=("${cur_lib}-${cur_version}")
          excludepkgs="${excludepkgs:+${excludepkgs}, }${cur_lib}"
        fi
      done
    fi

    # packages can be empty if no_agent is set
    if [ ${#packages[@]} -ne 0 ]; then
      echo -e "  \033[33mInstalling package(s): ${packages[*]}\n\033[0m"

      $sudo_cmd yum -y --disablerepo='*' --enablerepo='datadog' install $dnf_flag "${packages[@]}" 2> >(tee /tmp/ddog_install_error_msg >&2) || $sudo_cmd yum -y install $dnf_flag "${packages[@]}" 2> >(tee /tmp/ddog_install_error_msg >&2)

      ERR_SUMMARY=$(grep "Error Summary" -A3 /tmp/ddog_install_error_msg || true)
    else
      echo -e "  \033[33mNo packages to install.\033[0m\n"
    fi

    if [ -n "$excludepkgs" ]; then
        # exclude pinned tracer versions from updates
        repofile_content=$(cat /etc/yum.repos.d/datadog.repo)
        $sudo_cmd sh -c "echo -e '${repofile_content}\nexclude=${excludepkgs}' > /etc/yum.repos.d/datadog.repo"
    fi

elif [ "$OS" == "Debian" ]; then
    apt_trusted_d_keyring="/etc/apt/trusted.gpg.d/datadog-archive-keyring.gpg"
    apt_usr_share_keyring="/usr/share/keyrings/datadog-archive-keyring.gpg"

    DD_APT_INSTALL_ERROR_MSG=/tmp/ddog_install_error_msg
    MAX_RETRY_NB=10
    for i in $(seq 1 $MAX_RETRY_NB)
    do
        printf "\033[34m\n* Installing apt-transport-https, curl and gnupg\n\033[0m\n"
        $sudo_cmd apt-get update || printf "\033[31m'apt-get update' failed, the script will not install the latest version of apt-transport-https.\033[0m\n"
        # installing curl might trigger install of additional version of libssl; this will fail the installation process,
        # see https://unix.stackexchange.com/q/146283 for reference - we use DEBIAN_FRONTEND=noninteractive to fix that
        apt_exit_code=0
        if [ -z "$sudo_cmd" ]; then
            # if $sudo_cmd is empty, doing `$sudo_cmd X=Y command` fails with
            # `X=Y: command not found`; therefore we don't prefix the command with
            # $sudo_cmd at all in this case
            DEBIAN_FRONTEND=noninteractive apt-get install -y apt-transport-https curl gnupg 2>$DD_APT_INSTALL_ERROR_MSG  || apt_exit_code=$?
        else
            $sudo_cmd DEBIAN_FRONTEND=noninteractive apt-get install -y apt-transport-https curl gnupg 2>$DD_APT_INSTALL_ERROR_MSG || apt_exit_code=$?
        fi

        if grep "Could not get lock" $DD_APT_INSTALL_ERROR_MSG; then
            RETRY_TIME=$((i*5))
            printf "\033[31mInstallation failed: Unable to get lock.\nRetrying in ${RETRY_TIME}s ($i/$MAX_RETRY_NB).\033[0m\n"
            sleep $RETRY_TIME
        elif [ $apt_exit_code -ne 0 ]; then
            cat $DD_APT_INSTALL_ERROR_MSG
            exit $apt_exit_code
        else
            break
        fi
    done

    printf "\033[34m\n* Installing APT package sources for Datadog\n\033[0m\n"
    $sudo_cmd sh -c "echo 'deb [signed-by=${apt_usr_share_keyring}] https://${apt_url}/ ${apt_repo_version}' > /etc/apt/sources.list.d/datadog.list"
    $sudo_cmd sh -c "chmod a+r /etc/apt/sources.list.d/datadog.list"

    if [ ! -f $apt_usr_share_keyring ]; then
        $sudo_cmd touch $apt_usr_share_keyring
    fi
    # ensure that the _apt user used on Ubuntu/Debian systems to read GPG keyrings
    # can read our keyring
    $sudo_cmd chmod a+r $apt_usr_share_keyring

    for key in "${APT_GPG_KEYS[@]}"; do
        $sudo_cmd curl --retry 5 -o "/tmp/${key}" "https://${keys_url}/${key}"
        $sudo_cmd cat "/tmp/${key}" | $sudo_cmd gpg --import --batch --no-default-keyring --keyring "$apt_usr_share_keyring"
    done

    release_version="$(grep VERSION_ID /etc/os-release | cut -d = -f 2 | xargs echo | cut -d "." -f 1)"
    if { [ "$DISTRIBUTION" == "Debian" ] && [ "$release_version" -lt 9 ]; } || \
       { [ "$DISTRIBUTION" == "Ubuntu" ] && [ "$release_version" -lt 16 ]; }; then
        # copy with -a to preserve file permissions
        $sudo_cmd cp -a $apt_usr_share_keyring $apt_trusted_d_keyring
    fi

    if [ "$DISTRIBUTION" == "Debian" ] && [ "$release_version" -lt 8 ]; then
      if [ -n "$agent_minor_version_without_patch" ]; then
          if [ "$agent_minor_version_without_patch" -ge "36" ]; then
              ERROR_MESSAGE="Debian < 8 only supports $nice_flavor $agent_major_version up to $agent_major_version.35."
              ERROR_CODE=$UNSUPPORTED_PLATFORM_CODE
              printf "\033[31m$ERROR_MESSAGE\033[0m\n"
              report_telemetry
              exit;
          fi
      else
          if ! echo "$agent_flavor" | grep '[0-9]' > /dev/null; then
              echo -e "  \033[33m$nice_flavor $agent_major_version.35 is the last supported version on $DISTRIBUTION $release_version. Installing $agent_major_version.35 now.\n\033[0m"
              agent_minor_version=35
              clean_agent_minor_version=35
          fi
      fi
    fi

    ERROR_MESSAGE="ERROR
Failed to update the sources after adding the Datadog repository.
This may be due to any of the configured APT sources failing -
see the logs above to determine the cause.
If the failing repository is Datadog, please contact Datadog support.
*****
"
    $sudo_cmd apt-get update -o Dir::Etc::sourcelist="sources.list.d/datadog.list" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0"
    ERROR_MESSAGE="ERROR
Failed to install one or more packages, sometimes it may be
due to another APT source failing. See the logs above to
determine the cause.
If the cause is unclear, please contact Datadog support.
*****
"

    if [ -n "$agent_minor_version" ]; then
        # Example: datadog-agent=1:7.20.2-1
        pkg_pattern="([[:digit:]]:)?$agent_major_version\.${agent_minor_version%.}(\.[[:digit:]]+){0,1}(-[[:digit:]])?"
        agent_version_custom="$(apt-cache madison datadog-agent | grep -E "$pkg_pattern" -om1)" || true
        verify_agent_version "="
    fi

    declare -a packages
    if [ -n "$no_agent" ]; then
      packages=("datadog-signing-keys")
    else
      packages=("$agent_flavor" "datadog-signing-keys")
    fi

    if [ -n "$fips_mode" ]; then
     packages+=("datadog-fips-proxy")
    fi

    packages_to_lock=()
    if [ ${#apm_libraries[@]} -gt 0 ]; then
      for lib in "${apm_libraries[@]}"
      do
        cur_lib=$(echo "$lib" | cut -s -d':' -f1)
        cur_version=$(echo "$lib" | cut -s -d':' -f2)
        if [ -z "$cur_lib" ] ; then
          packages+=("${lib}")
          # the tracer might have been excluded from updates previously => un-hold it
          $sudo_cmd dpkg --set-selections <<< "${lib} install" >/dev/null 2>&1
        else
          packages_to_lock+=("${cur_lib}")
          packages+=("${cur_lib}=${cur_version}")
          $sudo_cmd dpkg --set-selections <<< "${cur_lib} install" >/dev/null 2>&1
        fi
      done
    fi

    echo -e "  \033[33mInstalling package(s): ${packages[*]}\n\033[0m"

    $sudo_cmd apt-get install -y --force-yes "${packages[@]}" 2> >(tee /tmp/ddog_install_error_msg >&2)

    for pkg in "${packages_to_lock[@]}"
    do
        # exclude pinned tracer versions from updates
        $sudo_cmd apt-mark hold "${pkg}" >/dev/null 2>&1
    done

    ERR_SUMMARY=$(grep "No space left on device" -C1 /tmp/ddog_install_error_msg || true)

    ERROR_MESSAGE=""
elif [ "$OS" == "SUSE" ]; then
  remove_rpm_gpg_keys "$sudo_cmd" "${RPM_GPG_KEYS_TO_REMOVE[@]}"
  UNAME_M=$(uname -m)
  if [ "$UNAME_M"  == "i686" ] || [ "$UNAME_M"  == "i386" ] || [ "$UNAME_M"  == "x86" ]; then
      ERROR_MESSAGE="The Datadog Agent installer is only available for 64 bit SUSE Enterprise machines."
      ERROR_CODE=$UNSUPPORTED_PLATFORM_CODE
      printf "\033[31m$ERROR_MESSAGE\033[0m\n"
      report_telemetry
      exit;
  elif [ "$UNAME_M"  == "aarch64" ]; then
      ARCHI="aarch64"
  else
      ARCHI="x86_64"
  fi

  if [ -z "$rpm_repo_gpgcheck" ]; then
      rpm_repo_gpgcheck=1
  fi

  # Try to guess if we're installing on SUSE 11, as it needs a different flow to work
  # Note that SUSE11 doesn't have /etc/os-release file, so we have to use /etc/SuSE-release
  if cat /etc/SuSE-release 2>/dev/null | grep VERSION | grep 11; then
    SUSE11="yes"
  fi

  # Doing "rpm --import" requires curl on SUSE/SLES
  echo -e "\033[34m\n* Ensuring curl is installed\n\033[0m\n"
  if ! rpm -q curl > /dev/null; then
    # If zypper fails to refresh a random repo, it installs the package, but then fails
    # anyway. Therefore we let it do its thing and then see if curl was installed or not.
    if [ -z "$sudo_cmd" ]; then
      ZYPP_RPM_DEBUG="${ZYPP_RPM_DEBUG:-0}" zypper --non-interactive install curl ||:
    else
      $sudo_cmd ZYPP_RPM_DEBUG="${ZYPP_RPM_DEBUG:-0}" zypper --non-interactive install curl ||:
    fi
    if ! rpm -q curl > /dev/null; then
      ERROR_MESSAGE="Failed to install curl."
      ERROR_CODE=$UNABLE_TO_INSTALL_DEPENDENCY_CODE
      echo -e "\033[31m$ERROR_MESSAGE\033[0m\n"
      fallback_msg
      report_telemetry
      exit 1;
    fi
  fi

  echo -e "\033[34m\n* Importing the Datadog GPG Keys\n\033[0m"
  if [ "$SUSE11" == "yes" ]; then
    # SUSE 11 special case
    for key_path in "${RPM_GPG_KEYS[@]}"; do
      $sudo_cmd curl -o "/tmp/${key_path}" "https://${keys_url}/${key_path}"
      $sudo_cmd rpm --import "/tmp/${key_path}"
    done
  else
    for key_path in "${RPM_GPG_KEYS[@]}"; do
      $sudo_cmd rpm --import "https://${keys_url}/${key_path}"
    done
  fi

  # Parse the major version number out of the distro release info file. xargs is used to trim whitespace.
  # NOTE: We use this to find out whether or not release version is >= 15, so we have to use /etc/os-release,
  # as /etc/SuSE-release has been deprecated and is no longer present everywhere, e.g. in AWS AMI.
  # See https://www.suse.com/releasenotes/x86_64/SUSE-SLES/15/#fate-324409
  SUSE_VER=$(cat /etc/os-release 2>/dev/null | grep VERSION_ID | tr -d '"' | tr . = | cut -d = -f 2 | xargs echo)
  gpgkeys="https://${keys_url}/DATADOG_RPM_KEY_CURRENT.public"
  if [ -n "$SUSE_VER" ] && [ "$SUSE_VER" -ge 15 ] && [ "$SUSE_VER" -ne 42 ]; then
    gpgkeys=''
    separator='\n       '
    for key_path in "${RPM_GPG_KEYS[@]}"; do
      gpgkeys="${gpgkeys:+"${gpgkeys}${separator}"}https://${keys_url}/${key_path}"
    done
  fi

  echo -e "\033[34m\n* Installing YUM Repository for Datadog\n\033[0m"
  $sudo_cmd sh -c "echo -e '[datadog]\nname=datadog\nenabled=1\nbaseurl=https://${yum_url}/suse/${yum_version_path}/${ARCHI}\ntype=rpm-md\ngpgcheck=1\nrepo_gpgcheck=${rpm_repo_gpgcheck}\ngpgkey=${gpgkeys}' > /etc/zypp/repos.d/datadog.repo"

  echo -e "\033[34m\n* Refreshing repositories\n\033[0m"
  $sudo_cmd zypper --non-interactive --no-gpg-checks refresh datadog

  # ".32" is the latest version supported for OpenSUSE < 15 and SLES < 12
  # we explicitly test for SUSE11 = "yes", as some SUSE11 don't have /etc/os-release, thus SUSE_VER is empty
  if [ "$DISTRIBUTION" == "openSUSE" ] && { [ "$SUSE11" == "yes" ] || [ "$SUSE_VER" -lt 15 ]; }; then
      if [ -n "$agent_minor_version_without_patch" ]; then
          if [ "$agent_minor_version_without_patch" -ge "33" ]; then
              ERROR_MESSAGE="openSUSE < 15 only supports $nice_flavor $agent_major_version up to $agent_major_version.32."
              ERROR_CODE=$UNSUPPORTED_PLATFORM_CODE
              printf "\033[31m$ERROR_MESSAGE\033[0m\n"
              report_telemetry
              exit;
          fi
      else
          if ! echo "$agent_flavor" | grep '[0-9]' > /dev/null; then
              echo -e "  \033[33m$nice_flavor $agent_major_version.32 is the last supported version on $DISTRIBUTION $SUSE_VER\n\033[0m"
              agent_minor_version=32
              clean_agent_minor_version=32
          fi
      fi
  fi
  if [ "$DISTRIBUTION" == "SUSE" ] && { [ "$SUSE11" == "yes" ] || [ "$SUSE_VER" -lt 12 ]; }; then
      if [ -n "$agent_minor_version_without_patch" ]; then
          if [ "$agent_minor_version_without_patch" -ge "33" ]; then
              ERROR_MESSAGE="SLES < 12 only supports $nice_flavor $agent_major_version up to $agent_major_version.32."
              ERROR_CODE=$UNSUPPORTED_PLATFORM_CODE
              printf "\033[31m$ERROR_MESSAGE\033[0m\n"
              report_telemetry
              exit;
          fi
      else
          if ! echo "$agent_flavor" | grep '[0-9]' > /dev/null; then
              echo -e "  \033[33m$nice_flavor $agent_major_version.32 is the last supported version on $DISTRIBUTION $SUSE_VER\n\033[0m"
              agent_minor_version=32
              clean_agent_minor_version=32
          fi
      fi
  fi

  if [ -n "$agent_minor_version" ]; then
      # Example: datadog-agent-1:7.20.2-1
      pkg_pattern="([[:digit:]]:)?$agent_major_version\.${agent_minor_version%.}(\.[[:digit:]]+){0,1}(-[[:digit:]])?"
      agent_version_custom="$(zypper search -s datadog-agent | grep -E "$pkg_pattern" -om1)" || true
      verify_agent_version "-"
  fi

  declare -a packages
  if [ -n "$no_agent" ]; then
    packages=()
  else
    packages=("$agent_flavor")
  fi

  if [ -n "$fips_mode" ]; then
    packages+=("datadog-fips-proxy")
  fi

  if [ ${#apm_libraries[@]} -gt 0 ]; then
    ERROR_MESSAGE="APM injection is not supported on SUSE"
    ERROR_CODE=$UNSUPPORTED_PLATFORM_CODE
    echo -e "\033[31m$ERROR_MESSAGE\033[0m\n"
    report_telemetry
    exit 1;
  fi

  if [ ${#packages[@]} -ne 0 ]; then
    echo -e "  \033[33mInstalling package(s): ${packages[*]}\n\033[0m"

    if [ -z "$sudo_cmd" ]; then
      ZYPP_RPM_DEBUG="${ZYPP_RPM_DEBUG:-0}" zypper --non-interactive install "${packages[@]}" 2> >(tee /tmp/ddog_install_error_msg >&2) ||:
    else
      $sudo_cmd ZYPP_RPM_DEBUG="${ZYPP_RPM_DEBUG:-0}" zypper --non-interactive install "${packages[@]}" 2> >(tee /tmp/ddog_install_error_msg >&2) ||:
    fi

    ERR_SUMMARY=$(grep "Write error" -C1 /tmp/ddog_install_error_msg || true)
  else
    echo -e "  \033[33mNo packages to install.\033[0m\n"
  fi

  # If zypper fails to refresh a random repo, it installs the package, but then fails
  # anyway. Therefore we let it do its thing and then see if curl was installed or not.
  for expected_pkg in "${packages[@]}"; do
    if ! rpm -q "${expected_pkg}" > /dev/null; then
      ERROR_MESSAGE="Failed to install ${expected_pkg}."
      ERROR_CODE=$UNABLE_TO_INSTALL_DEPENDENCY_CODE
      echo -e "\033[31m$ERROR_MESSAGE\033[0m\n"
      fallback_msg
      report_telemetry
      exit 1;
    fi
  done

else
    ERROR_MESSAGE="Your OS or distribution are not supported by this install script.
Please follow the instructions on the Agent setup page:

https://app.datadoghq.com/account/settings#agent"
    ERROR_CODE=$UNSUPPORTED_PLATFORM_CODE
    printf "\033[31m$ERROR_MESSAGE\033[0m\n"
    report_telemetry
    exit;
fi

##
# UPGRADE FROM AGENT 5
##
if [ -n "$upgrade" ] && [ "$agent_flavor" != "datadog-dogstatsd" ]; then
  if [ -e $LEGACY_CONF ]; then
    # try to import the config file from the previous version
    icmd="datadog-agent import $LEGACY_ETCDIR $etcdir"
    # shellcheck disable=SC2086
    $sudo_cmd $icmd || printf "\033[31mAutomatic import failed, you can still try to manually run: $icmd\n\033[0m\n"
    # fix file owner and permissions since the script moves around some files
    $sudo_cmd chown -R dd-agent:dd-agent "$etcdir"
    $sudo_cmd find "$etcdir/" -type f -exec chmod 640 {} \;
  else
    printf "\033[31mYou don't have a datadog.conf file to convert.\n\033[0m\n"
  fi
fi

##
# SET THE CONFIGURATION
##
# Unit method
function update_api_key() {
  local sudo_cmd="$1"
  local apikey="$2"
  local config_file="$3"
  if [ -n "$apikey" ]; then
    printf "\033[34m\n* Adding your API key to the $nice_flavor configuration: $config_file\n\033[0m\n"
    $sudo_cmd sh -c "sed -i 's/api_key:.*/api_key: $apikey/' $config_file"
  else
    # If the import script failed for any reason, we might end here also in case
    # of upgrade, let's not start the agent or it would fail because the api key
    # is missing
    if ! $sudo_cmd grep -q -E '^api_key: .+' "$config_file"; then
      printf "\033[31mThe $nice_flavor won't start automatically at the end of the script because the Api key is missing, please add one in datadog.yaml and start the $nice_flavor manually.\n\033[0m\n"
      no_start=true
    fi
  fi
}
function update_site() {
  local sudo_cmd="$1"
  local site="$2"
  local config_file="$3"
  if [ -n "$site" ]; then
    printf "\033[34m\n* Setting SITE in the $nice_flavor configuration: $config_file\n\033[0m\n"
    $sudo_cmd sh -c "sed -i 's/^# site:.*$/site: $site/' $config_file"
  fi
}
function update_url() {
  local sudo_cmd="$1"
  local url="$2"
  local config_file="$3"
  if [ -n "$url" ]; then
    printf "\033[34m\n* Setting DD_URL in the $nice_flavor configuration: $config_file\n\033[0m\n"
    $sudo_cmd sh -c "sed -i 's|^# dd_url:.*$|dd_url: $url|' $config_file"
  fi
}
function update_fips() {
  local sudo_cmd="$1"
  local config_file="$2"
  printf "\033[34m\n* Setting $nice_flavor configuration to use FIPS proxy: $config_file\n\033[0m\n"
  $sudo_cmd cp "$config_file" "${config_file}.orig"
  $sudo_cmd sh -c "exec cat - '${config_file}.orig' > '$config_file'" <<EOF
# Configuration for the agent to use datadog-fips-proxy to communicate with Datadog via FIPS-compliant channel.

fips:
    enabled: true
    port_range_start: 9803
    https: false
EOF
}
function update_hostname(){
  local sudo_cmd="$1"
  local hostname="$2"
  local config_file="$3"
  if [ -n "$hostname" ]; then
    printf "\033[34m\n* Adding your HOSTNAME to the $nice_flavor configuration: $config_file\n\033[0m\n"
    $sudo_cmd sh -c "sed -i 's/^# hostname:.*$/hostname: $hostname/' $config_file"
  fi
}
function update_hosttags(){
  local sudo_cmd="$1"
  local host_tags="$2"
  local config_file="$3"
  if [ -n "$host_tags" ]; then
      printf "\033[34m\n* Adding your HOST TAGS to the $nice_flavor configuration: $config_file\n\033[0m\n"
      formatted_host_tags="['""$( echo "$host_tags" | sed "s/,/', '/g" )""']"  # format `env:prod,foo:bar` to yaml-compliant `['env:prod','foo:bar']`
      $sudo_cmd sh -c "sed -i \"s/^# tags:.*$/tags: ""$formatted_host_tags""/\" $config_file"
  fi
}
function update_env(){
  local sudo_cmd="$1"
  local dd_env="$2"
  local config_file="$3"
  if [ -n "$dd_env" ]; then
    printf "\033[34m\n* Adding your DD_ENV to the $nice_flavor configuration: $config_file\n\033[0m\n"
    $sudo_cmd sh -c "sed -i 's/^# env:.*/env: $dd_env/' $config_file"
  fi
}
function update_security_and_or_compliance(){
  local sudo_cmd="$1"
  local local_config_file="$2"
  local enable_security="$3"
  local enable_compliance="$4"
  if [ "$enable_security" == "true" ]; then
    printf "\033[34m\n* Enabling runtime security in $local_config_file configuration\n\033[0m\n"
    $sudo_cmd sh -c "sed -i 's/^#\s*runtime_security_config:$/runtime_security_config:/' $local_config_file"
    $sudo_cmd sh -c "sed -i '/^runtime_security_config:/,// s/\(\s\+\)#\s*enabled:\s*false/\1enabled: true/' $local_config_file"
  fi
  if [ "$enable_compliance" == "true" ]; then
    printf "\033[34m\n* Enabling compliance monitoring in $local_config_file configuration\n\033[0m\n"
    $sudo_cmd sh -c "sed -i 's/^#\s*compliance_config:$/compliance_config:/' $local_config_file"
    $sudo_cmd sh -c "sed -i '/^compliance_config:/,// s/\(\s\+\)#\s*enabled:\s*false/\1enabled: true/' $local_config_file"
  fi
}
function manage_security_and_system_probe_config(){
  local sudo_cmd="$1"
  local security_config_file="$2"
  local probe_config_file="$3"
  local enable_security="$4"
  local enable_compliance="$5"
  if [ "$enable_security" == "true" ] || [ "$enable_compliance" == "true" ]; then
    if ensure_config_file_exists "$sudo_cmd" "$security_config_file" "root"; then
      update_security_and_or_compliance "$sudo_cmd" "$security_config_file" "$enable_security" "$enable_compliance"
    fi
    if [ "$enable_security" == "true" ]; then
      if ensure_config_file_exists "$sudo_cmd" "$probe_config_file" "root"; then
        update_security_and_or_compliance "$sudo_cmd" "$probe_config_file" "$enable_security" "false"
      fi
    fi
  fi
}
# "Main" configuration update
if [ -e "$config_file" ] && [ -z "$upgrade" ]; then
  printf "\033[34m\n* Keeping old $config_file configuration file\n\033[0m\n"
elif [ ! "$no_agent" ]; then
  if ensure_config_file_exists "$sudo_cmd" "$config_file" "dd-agent"; then
    update_api_key "$sudo_cmd" "$apikey" "$config_file"
    if [ -z "$fips_mode" ]; then
      update_site "$sudo_cmd" "$site" "$config_file"
      update_url "$sudo_cmd" "$DD_URL" "$config_file"
    else
      update_fips "$sudo_cmd" "$config_file"
    fi
    update_hostname "$sudo_cmd" "$hostname" "$config_file"
    update_hosttags "$sudo_cmd" "$host_tags" "$config_file"
    update_env "$sudo_cmd" "$dd_env" "$config_file"
  fi
  manage_security_and_system_probe_config "$sudo_cmd" "$security_agent_config_file" "$system_probe_config_file" "$DD_RUNTIME_SECURITY_CONFIG_ENABLED" "$DD_COMPLIANCE_CONFIG_ENABLED"
fi

if [ ! "$no_agent" ]; then
  $sudo_cmd chown dd-agent:dd-agent "$config_file"
  $sudo_cmd chmod 640 "$config_file"
fi

# set the FIPS configuration
if [ -n "$fips_mode" ]; then
  ensure_config_file_exists "$sudo_cmd" "$config_file_fips" "dd-agent"
  # TODO: set port range in file, or environment variable
fi

# set the system-probe configuration
if [ -n "$system_probe_ensure_config" ]; then
  ensure_config_file_exists "$sudo_cmd" "$system_probe_config_file" "root"
fi

# run apm injection scripts
if [ -n "$host_injection_enabled" ]; then
  $sudo_cmd dd-host-install --no-agent-restart ${no_config_change}
fi

if [ -n "$docker_injection_enabled" ]; then
  $sudo_cmd dd-container-install --no-agent-restart
fi

# Creating or overriding the install information
function generate_install_id() {
  # Try generating a UUID based on /proc/sys/kernel/random/uuid
  uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
  # If that does not work, then try uuidgen
  if [ ${#uuid} -ne 36 ]; then
    uuid=$(uuidgen 2>/dev/null)
  fi
  # Convert to lowercase
  uuid=$(echo "$uuid" | tr '[:upper:]' '[:lower:]')
  printf "$uuid"
}

function generate_install_signature() {
  local install_id="$1"
  local install_type="$2"
  local install_time="$3"
  printf "{\"install_id\":\"$install_id\",\"install_type\":\"$install_type\",\"install_time\":$install_time}"
}

install_id=$(generate_install_id)
install_time=$(date +%s)

# If an install.json already exists, is formatted correctly, and was generated by this script,
# reuse the original install ID and time.
if [ -f "$etcdir/install.json" ]; then
  # Parse the JSON file using substring extraction to avoid a dependency on any JSON parser
  install_info=$(cat "$etcdir/install.json" 2>/dev/null)
  if [ ${#install_info} -eq 118 ]; then
    if [ "${install_info:2:10}" == "install_id" ] && [ "${install_info:53:38}" == "\"install_type\":\"$install_type\"" ] && [ "${install_info:93:12}" == "install_time" ]; then
      install_id=${install_info:15:36}
      install_time=${install_info:107:10}
    fi
  fi
fi

install_signature=$(generate_install_signature "$install_id" "$install_type" "$install_time")

install_info_content="---
install_method:
  tool: install_script
  tool_version: $variant
  installer_version: install_script-$install_script_version
"

if [ ! "$no_agent" ]; then
  $sudo_cmd sh -c "echo '$install_signature' > $etcdir/install.json"
  $sudo_cmd chmod 644 "$etcdir/install.json"
  $sudo_cmd sh -c "exec cat > $etcdir/install_info " <<EOF
$install_info_content
EOF
fi

if [ -n "$fips_mode" ]; then
  # Creating or overriding the install information
  $sudo_cmd sh -c "echo '$install_info_content' > $etcdirfips/install_info"
fi

# On SUSE 11, sudo service datadog-agent start fails (because /sbin is not in a base user's path)
# However, sudo /sbin/service datadog-agent does work.
# Use which (from root user) to find the absolute path to service

service_cmd="service"
if [ "$SUSE11" == "yes" ]; then
  # We're testing SLES11 on a opensuse 13.2, `which service` will fail on openSUSE 13.2 and needs to have `service` as a default value
  service_cmd=$($sudo_cmd which service || echo "service")
fi

declare -a monitoring_services
monitoring_services=( "datadog-agent" )

##
# START THE AGENT
##
if [ -n "$no_start" ]; then
  printf "\033[34m\n  * DD_INSTALL_ONLY environment variable set.\033[0m\n"
fi

for current_service in "${services[@]}"; do
    nice_current_flavor=$(getMapData flavor_to_readable "$current_service")

  # Use /usr/sbin/service by default.
  # Some distros usually include compatibility scripts with Upstart or Systemd. Check with: `command -v service | xargs grep -E "(upstart|systemd)"`
  restart_cmd="$sudo_cmd $service_cmd $current_service restart"
  stop_instructions="$sudo_cmd $service_cmd $current_service stop"
  start_instructions="$sudo_cmd $service_cmd $current_service start"

  if [[ $($sudo_cmd ps --no-headers -o comm 1 2>&1) == "systemd" ]] && command -v systemctl 2>&1; then
    # Use systemd if systemctl binary exists and systemd is the init process
    restart_cmd="$sudo_cmd systemctl restart ${current_service}.service"
    stop_instructions="$sudo_cmd systemctl stop $current_service"
    start_instructions="$sudo_cmd systemctl start $current_service"
  elif /sbin/init --version 2>&1 | grep -q upstart; then
    # Try to detect Upstart, this works most of the times but still a best effort
    restart_cmd="$sudo_cmd stop $current_service || true ; sleep 2s ; $sudo_cmd start $current_service"
    stop_instructions="$sudo_cmd stop $current_service"
    start_instructions="$sudo_cmd start $current_service"
  fi

  if [ -n "$no_start" ]; then
    printf "\033[34m\n    The newly installed version of the ${nice_current_flavor} will not be started.
    You will have to do it manually using the following command:

    $start_instructions\033[0m\n\n"

    continue
  fi

  printf "\033[34m* Starting the ${nice_current_flavor}...\n\033[0m\n"
  ERROR_MESSAGE="Error starting ${nice_current_flavor}"

  eval "$restart_cmd"

  ERROR_MESSAGE=""

  # Metrics are submitted, echo some instructions and exit
  printf "\033[32m  Your ${nice_current_flavor} is running and functioning properly.\n\033[0m"

  if [[ "${monitoring_services[*]}" =~ ${current_service} ]]; then
    printf "\033[32m  It will continue to run in the background and submit metrics to Datadog.\n\033[0m"
  fi

  printf "\033[32m  If you ever want to stop the ${nice_current_flavor}, run:

      $stop_instructions

  And to run it again run:

      $start_instructions\033[0m\n\n"

  if [ -d "$docker_config_dir" ]; then
    groups dd-agent 2>&1 | grep -v docker > /dev/null && printf "\033[32m  Consider adding dd-agent to the docker group to enable the docker support, run:

      sudo usermod -a -G docker dd-agent\033[0m\n\n"
  fi
done

report_telemetry "$install_id" "$install_type" "$install_time"
