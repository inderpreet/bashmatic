#!/usr/bin/env bash
#===============================================================================
# Private Functions
#===============================================================================

export bashmatic_db_config=${bashmatic_db_config:-"${HOME}/.db/database.yml"}
declare -a bashmatic_db_connection

unset bashmatic_db_username
unset bashmatic_db_password
unset bashmatic_db_host
unset bashmatic_db_database

db.psql.args-data-only() {
  printf -- "%s" "--no-align --pset footer -q -X --tuples-only"
}

db.config.init() {
  export bashmatic_db_connection=(host database username password)
}

# @description Returns a space-separated values of db host, db name, username and password
#
# @example
#    db.config.set-file ~/.db/database.yml
#    db.config.parse development
#    #=> hostname dbname dbuser dbpass
#    declare -a params=($(db.config.parse development))
#    echo ${params[0]} # host
#
# @requires
#    Local psql CLI client
db.config.parse() {
  local db="$1"
  [[ -z ${db} ]] && return 1
  [[ -f ${bashmatic_db_config} ]] || return 2
  db.config.init
  local -a script=("require 'yaml'; h = YAML.load(STDIN); ")
  for field in "${bashmatic_db_connection[@]}"; do
    script+=("h.key?('${db}') && h['${db}'].key?('${field}') ? print(h['${db}']['${field}']) : print('null'); print ' '; ")
  done
  ruby.handle-missing
  ruby -e "${script[*]}"<"${bashmatic_db_config}"
}

db.config.connections-list() {
  [[ -f ${bashmatic_db_config} ]] || return 2
  ruby.handle-missing
  gem.install colored2 >/dev/null
  __yaml_source="${bashmatic_db_config}" ruby <<RUBY
  require 'yaml'
  require 'colored2'
  h = YAML.load(File.read(ENV['__yaml_source']))
  h.each_pair do |name, params| 
    printf "%50s → %s@%s/%s\n", 
      name.bold.yellow, 
      params['username'].blue,
      params['host'].green,
      params['database'].cyan
  end
RUBY
}

db.config.connections() {
  ascii-clean "$(db.config.connections-list | awk '{print $1}')"
}

db.config.set-file() {
  [[ -s "$1" ]] || return 1
  export bashmatic_db_config="$1"
}

db.config.get-file() {
  echo "${bashmatic_db_config}"
}

db.psql.args.config() {
  local output="$(db.config.parse "$1")"
  local -a params

  [[ -z ${output} || "${output}" =~ "null" ]] && {
    section.red 65 "Unknown database connection — ${bldylw}$1." >&2
    info "The following are connections defined in ${bldylw}${bashmatic_db_config/${HOME}/\~}:\n" >&2
    for c in $(db.config.connections); do info " • ${c}" >&2; done
    echo >&2
    exit 1
  }

  params=($(db.config.parse "$1"))

  local dbhost
  local dbname
  local dbuser
  local dbpass

  dbhost=${params[0]}
  dbname=${params[1]}
  dbuser=${params[2]}
  dbpass=${params[3]}

  export PGPASSWORD="${dbpass}"
  printf -- "-U ${dbuser} -h ${dbhost} -d ${dbname}"
}

# @description Connect to one of the databases named in the YAML file, and 
#              optionally pass additional arguments to psql.
#              Informational messages are sent to STDERR.
#
# @example
#    db.psql.connect production 
#    db.psql.connect production -c 'show all'
#
db.psql.connect() {
  local dbname="$1"; shift

  if [[ -z ${dbname} ]]; then
    h1 "USAGE: db.connect connection-name" \
      "WHERE: connection-name is defined by your ${bldylw}${bashmatic_db_config}${clr} file." >&2
    return 0
  fi

  local tempfile=$(mktemp)
  db.psql.args.config "${dbname}" >"${tempfile}"

  local -a args=($(cat "${tempfile}"))

  rm -f "${tempfile}" >/dev/null

  (
    printf "${txtpur}export PGPASSWORD=[reducted]${clr}\n"
    printf "${txtylw}$(which psql) ${args[*]}${clr}\n"
    hr
  ) >&2
  
  psql "${args[@]}" "$@"
}

# @description Similar to the db.psql.connect, but outputs
#              just the raw data with no headers.
#
# @example
#    db.psql.connect.just-data production -c 'select datname from pg_database;'
db.psql.connect.just-data() {
  local dbname="$1"; shift
  # shellcheck disable=SC2046
  db.psql.connect "${dbname}" $(db.psql.args-data-only) "$@"
}

# @description Print out PostgreSQL settings for a connection specified by args
#
# @example
#    db.psql.db-settings -h localhost -U postgres appdb
#
# @requires
#    Local psql CLI client
db.psql.db-settings() {
  psql "$*" -X -q -c 'show all' | sort | awk '{ printf("%s=%s\n", $1, $3) }' | sed -E 's/[()\-]//g;/name=setting/d;/^[-+=]*$/d;/^[0-9]*=$/d'
}

# @description Print out PostgreSQL settings for a named connection
# @arg1 dbname database entry name in ~/.db/database.yml
# @example
#    db.psql.connect.settings-table primary
#
db.psql.connect.settings-table() {
  db.psql.connect "$@" -A -X -q -c 'show all' | \
    grep -v 'rows)' | \
    sort | \
    awk "BEGIN{FS=\"|\"}{ printf(\"%-40.40s %-30.30s ## %s\n\", \$1, \$2, \$3) }" | \
    sedx '/##\s*$/d' | \
    GREP_COLOR="1;32" grep -E -C 1000 -i --color=always -e '^([^ ]*)' | \
    GREP_COLOR="3;0;34" grep -E -C 1000 -i --color=always -e '##.*$|$'
}

# @description Print out PostgreSQL settings for a named connection using TOML/ini
#              format.
#
# @arg1 dbname database entry name in ~/.db/database.yml
# @example
#    db.psql.connect.settings-ini primary > primary.ini
#
db.psql.connect.settings-ini() {
  db.psql.connect.just-data "$1" -c 'show all' | awk 'BEGIN{FS="|"}{printf "%s=%s\n", $1, $2}' | sort
}

db.psql.args() {
  if [[ -z "${bashmatic_db_database}" || -z "${bashmatic_db_host}" ]]; then
    if [[ -n "$1" ]]; then
      db.psql.args.config "$1"
    else
      error "Unable to determine DB connection parameters"
      return 1
    fi
  else
    export PGPASSWORD="${bashmatic_db_password}"
    printf -- "-U ${bashmatic_db_username} -h ${bashmatic_db_host} ${bashmatic_db_database}"
  fi
}

db.psql.args.localhost() {
  printf -- "-U postgres -h localhost $*"
}

db.psql.args.maintenance() {
  db.psql.args.localhost "--maintenance-db=postgres $*"
}

db.wait-until-db-online() {
  local db="${1}"
  inf 'waiting for the database to come up...'
  while true; do
    out=$(psql -c "select count(*) from pg_stat_user_tables" "$(db.psql.args "${db}")" 2>&1)
    code=$?
    [[ ${code} == 0 ]] && break # can connect and all is good
    [[ ${code} == 1 ]] && break # db is there, but no database/table is found
    sleep 1
    [[ ${out} =~ 'does not exist' ]] && break
  done
  ui.closer.ok:
  return 0
}

db.pg.local.num-procs() {
  /bin/ps -ef | /bin/grep "[p]ostgres" | wc -l | awk '{print $1}'
}

db.datetime() {
  date '+%Y%m%d-%H%M%S'
}

.db.backup-filename() {
  local dbname=${1:-"development"}
  local checksum=$(db.rails.schema.checksum)
  if [[ -z ${checksum} ]]; then
    error "Can not calculate DB checksum based on Rails DB structure"
  else
    printf "${checksum}.$(util.arch).${dbname}.dump"
  fi
}

db.actions.top() {
  db.top "$@" 
}

db.actions.connect() {
  db.psql.connect "$@"
}

db.actions.connections() {
  db.config.connections
}

db.actions.settings-table() {
  db.psql.connect.settings-table "$@"
}

db.actions.settings-ini() {
  db.psql.connect.settings-ini "$@"
}
