#!/bin/bash -e

DIRNAME=$(dirname "$0")
DEPLOY_CONFIG_FILE="deploy.config"
MKTEMP_TEMPLATE="deploybuild.XXXXX"


function exitError {
	echo "Error: $1" >&2
	exit 1
}

function writeWarning {
	echo "Warning: $1"
}

function writeNotice {
	echo "Notice: $1"
}

function usage {
	cat <<EOM
Usage: $(basename "$0") [OPTION]...

  -d    dry run deployment
  -t    retain build directory after completion
  -h    display help
EOM

	exit 2
}

function getTempFile {
	local tempFile
	tempFile=$(mktemp --quiet --tmpdir "$MKTEMP_TEMPLATE") || \
		exitError "Unable to create temporary file"

	echo "$tempFile"
}

function getPathCanonical {
	if [[ $2 == "nocheck" ]]; then
		readlink --canonicalize-missing --no-newline "$1"

	else
		# note: will return error = 1 if any path component non-exists (except final) - hence || :
		readlink --canonicalize --no-newline "$1" || :
	fi
}

function loadConfiguration {
	# attempt to load a global configuration file inline with the canonical script path
	# note: global config file may not exist, that's fine
	local globalConfigFile=$(getPathCanonical "$0")
	globalConfigFile="$(dirname "$globalConfigFile")/$DEPLOY_CONFIG_FILE"
	[[ -f $globalConfigFile ]] && . "$globalConfigFile"

	# now load application config file - must exist otherwise fatal error
	local appConfigFile="$DIRNAME/$DEPLOY_CONFIG_FILE"
	[[ -f $appConfigFile ]] || exitError "Unable to locate $appConfigFile."
	. "$appConfigFile"
}

function validateConfiguration {
	# YUI compressor/Google closure compiler jars exist?
	[[ -z $JAR_YUI_COMPRESSOR ]] && exitError "JAR_YUI_COMPRESSOR config parameter not defined."
	[[ -f $JAR_YUI_COMPRESSOR ]] || exitError "Unable to locate YUI compressor jar at $JAR_YUI_COMPRESSOR."

	[[ -z $JAR_GOOGLE_CLOSURE ]] && exitError "JAR_GOOGLE_CLOSURE config parameter not defined."
	[[ -f $JAR_GOOGLE_CLOSURE ]] || exitError "Unable to locate Google Closure Compiler jar at $JAR_GOOGLE_CLOSURE."

	# validate config settings - application source directory
	[[ -z $SOURCE_DIR ]] && exitError "SOURCE_DIR config parameter not defined."

	# canonicalize $SOURCE_DIR and validate directory exists
	sourceDirCanonical=$(getPathCanonical "$DIRNAME/$SOURCE_DIR")
	[[ -d $sourceDirCanonical ]] || exitError "Unable to locate source directory at $sourceDirCanonical"

	# validate config settings - build source filter
	[[ -z $BUILD_SOURCE_FILTER ]] && exitError "BUILD_SOURCE_FILTER config parameter not defined."

	# validate config settings - target server details
	[[ -z $SERVER_HOSTNAME ]] && exitError "SERVER_HOSTNAME config parameter not defined."
	[[ -z $SERVER_SSH_USER ]] && exitError "SERVER_SSH_USER config parameter not defined."
	[[ -z $SERVER_SSH_PORT ]] && exitError "SERVER_SSH_PORT config parameter not defined."

	[[ -z $SERVER_RSYNC_MODULE ]] && exitError "SERVER_RSYNC_MODULE config parameter not defined."
	[[ -z $SERVER_RSYNC_CHMOD ]] && exitError "SERVER_RSYNC_CHMOD config parameter not defined."

	# return truthy
	:
}

function rsyncSourceToBuildDir {
	# create temp file to hold source copy to build dir rsync filter rules
	local filterTmp=$(getTempFile)
	echo "$BUILD_SOURCE_FILTER" >"$filterTmp"

	rsync \
		--filter ". $filterTmp" \
		--out-format "%n" \
		--recursive \
		--times \
		"$sourceDirCanonical/" "$buildDir"

	echo

	rm --force "$filterTmp"
}

function gzipResource {
	# source file exists?
	[[ -f $1 ]] || return

	# compress file and give identical timestamp to source
	# for use with the nginx ngx_http_gzip_static_module module
	# See: https://nginx.org/en/docs/http/ngx_http_gzip_static_module.html
	echo "Compressing resource:"
	echo "Source: $1"
	echo "Target: $1.gz"
	echo

	gzip --best --stdout "$1" >"$1.gz"
	touch --no-create --reference "$1" "$1.gz"
}

function buildSass {
	# if no Sass files defined for build - exit
	[[ -z $BUILD_SASS_LIST ]] && return

	local sassBuildItem

	local IFS=$'\n'
	for sassBuildItem in $BUILD_SASS_LIST; do
		# ensure $sassBuildItem is in [SOURCE_SCSS|TARGET_CSS] format
		if [[ $sassBuildItem =~ ^([^|]+)\|([^|]+)$ ]]; then
			# fetch Sass source and CSS target parts canonicalized
			local sassSource=$(getPathCanonical "$sourceDirCanonical/${BASH_REMATCH[1]}")
			local cssTarget=$(getPathCanonical "$buildDir/${BASH_REMATCH[2]}" "nocheck")

			# source Sass document exists?
			if [[ -f $sassSource ]]; then
				echo "Compiling Sass -> CSS:"
				echo "Source: $sassSource"
				echo "Target: $cssTarget"
				echo

				# create parent directory structure in build target for generated CSS document
				mkdir --parents "$(dirname "$cssTarget")"

				# now compile Sass document to output CSS
				sass \
					--load-path "$(dirname "$sassSource")" \
					--no-cache \
					--require sass-globbing \
					--scss \
					--sourcemap=none \
					"$sassSource" "$cssTarget"

				# minify built CSS using YUI compressor then compress
				cat "$cssTarget" | \
					java -jar "$JAR_YUI_COMPRESSOR" \
					--type css -o "$cssTarget"

				gzipResource "$cssTarget"

			else
				writeWarning "Unable to locate $sassSource for CSS compile"
				echo
			fi

		else
			writeWarning "Invalid Sass build item definition: $sassBuildItem"
			echo
		fi
	done
}

function buildJavaScript {
	# if no JavaScript build files defined - exit
	[[ -z $BUILD_JAVASCRIPT_LIST ]] && return

	local javaScriptBuildItem

	local IFS=$'\n'
	for javaScriptBuildItem in $BUILD_JAVASCRIPT_LIST; do

		# ensure $javaScriptBuildItem is in [SOURCE_JAVASCRIPT_LIST|TARGET_JAVASCRIPT] format
		if [[ $javaScriptBuildItem =~ ^([^|]+)\|([^|]+)$ ]]; then
			local javaScriptBuildTarget=$(getPathCanonical "$buildDir/${BASH_REMATCH[2]}" "nocheck")
			local javaScriptTempConcatTarget=$(getTempFile)
			local buildStepHeaderWritten

			# work over each source JavaScript list item glob
			local javaScriptSourceGlobItem

			local IFS=","
			for javaScriptSourceGlobItem in ${BASH_REMATCH[1]}; do

				# grab file(s) matched by source JavaScript source item
				local javaScriptSourceFileItem
				local globMatch

				# note: don't quote $javaScriptSourceGlobItem as may contain glob patterns
				local IFS=$'\n'
				for javaScriptSourceFileItem in "$sourceDirCanonical/"$javaScriptSourceGlobItem; do

					# get canonical path to source JavaScript file
					javaScriptSourceFileItem=$(getPathCanonical "$javaScriptSourceFileItem")

					if [[ -f $javaScriptSourceFileItem ]]; then
						globMatch=:
						if [[ ! $buildStepHeaderWritten ]]; then
							echo "Concatenate/minifying source JavaScript -> JavaScript:"
							buildStepHeaderWritten=:
						fi

						# add JavaScript to concatenate file target
						echo "Source: $javaScriptSourceFileItem"
						cat "$javaScriptSourceFileItem" >>"$javaScriptTempConcatTarget"
					fi
				done

				if [[ ! $globMatch ]]; then
					# resolved [$sourceDirCanonical/$javaScriptSourceGlobItem] glob path didn't match anything
					writeWarning "JavaScript source glob $javaScriptSourceGlobItem did not match"
				fi
			done

			if [[ -s $javaScriptTempConcatTarget ]]; then
				# successfully concatenated one or more source JavaScript files to target file
				echo "Target: $javaScriptBuildTarget"
				echo

				# create parent directory structure in build target for final JavaScript source file
				mkdir --parents "$(dirname "$javaScriptBuildTarget")"

				# minify temporary JavaScript concatenate target to final build location then compress
				cat "$javaScriptTempConcatTarget" | \
					java -jar "$JAR_GOOGLE_CLOSURE" \
						--js_output_file "$javaScriptBuildTarget" \
						--rewrite_polyfills false

				gzipResource "$javaScriptBuildTarget"

			else
				writeWarning "Unable to create $javaScriptBuildTarget from source JavaScript file(s)"
				echo
			fi

			# delete temporary JavaScript concatenate target
			rm --force "$javaScriptTempConcatTarget"

		else
			writeWarning "Invalid JavaScript build item definition: $javaScriptBuildItem"
			echo
		fi
	done
}

function SSHRsyncBuildDirToServer {
	# create temp file to hold server exclude filter rules for rsync - empty file if not defined
	local filterTmp=$(getTempFile)
	[[ -n $SERVER_EXCLUDE_FILTER ]] && echo "$SERVER_EXCLUDE_FILTER" >"$filterTmp"

	rsync \
		--chmod "$SERVER_RSYNC_CHMOD" \
		--compress \
		--delete \
		--exclude-from "$filterTmp" \
		--itemize-changes \
		--recursive \
		--rsh "ssh -l \"$SERVER_SSH_USER\" -p \"$SERVER_SSH_PORT\"" \
		--times \
		${optionRsyncDryRunOnly:+--dry-run} \
		"$buildDir/" "$SERVER_HOSTNAME::$SERVER_RSYNC_MODULE" || :

	echo

	rm --force "$filterTmp"
}


# parse command line options
optionRsyncDryRunOnly=
optionRetainBuildResultDir=
while getopts ":dth" optKey; do
	case "$optKey" in
		d)
			optionRsyncDryRunOnly=:
			;;
		t)
			optionRetainBuildResultDir=:
			;;
		h|*)
			usage
			;;
	esac
done

# ensure rsync, java and sass all present
[[ ! -x $(command -v rsync) ]] && exitError "Unable to locate rsync, installed?"
[[ ! -x $(command -v java) ]] && exitError "Unable to locate Java, installed?"
[[ ! -x $(command -v sass) ]] && exitError "Unable to locate Sass, installed?"

# load and validate (optional) global and application configuration files
loadConfiguration
validateConfiguration

# everything validated - lets start the build process
echo "Application source: $sourceDirCanonical"
[[ $optionRsyncDryRunOnly ]] && writeNotice "Rsync dry-run deployment only"
[[ $optionRetainBuildResultDir ]] && writeNotice "Retaining temporary build directory after deployment"

# create build directory
buildDir=$(mktemp --directory --tmpdir "$MKTEMP_TEMPLATE")
echo "Build target: $buildDir"
echo

# rsync application source to build directory
rsyncSourceToBuildDir

# build Sass source files to minified/gzipped CSS
buildSass

# build JavaScript source files to bundled/minified/gzipped JavaScript
buildJavaScript

# if defined, run pre deployment hook function now
if [[ $(type -t preDeployHook) == "function" ]]; then
	preDeployHook "$sourceDirCanonical" "$buildDir"
fi

# rsync build directory to destination server via SSH transit
SSHRsyncBuildDirToServer

if [[ $optionRetainBuildResultDir ]]; then
	# retaining build directory
	echo "Build directory retained at: $buildDir"

else
	# remove build directory
	echo "Removing build target work area: $buildDir"
	rm --force --recursive "$buildDir"
fi
