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

  -d    dry-run rsync
  -t    retain build directory after deployment
  -h    display help
EOM

	exit 2
}

function getTempFile {

	local tempFile
	tempFile=$(mktemp -q --tmpdir "$MKTEMP_TEMPLATE") || \
		exitError "Unable to create temporary file"

	echo "$tempFile"
}

function getPathCanonical {

	if [[ $2 == "nocheck" ]]; then
		readlink -mn "$1"

	else
		# note: will return error = 1 if any path component non-exists (except final) - hence || :
		readlink -fn "$1" || :
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

	rsync -rt \
		--out-format "%n" \
		--filter ". $filterTmp" \
		"$sourceDirCanonical/" "$buildDir"

	echo

	rm -f "$filterTmp"
}

function gzipResource {

	# source file exists?
	[[ -f $1 ]] || return

	# compress file and give identical timestamp to source
	# for use with the nginx ngx_http_gzip_static_module module
	# See: http://nginx.org/en/docs/http/ngx_http_gzip_static_module.html
	echo "Compressing resource:"
	echo "Source: $1"
	echo "Target: $1.gz"
	echo

	gzip -c9 "$1" >"$1.gz"
	touch -c --reference "$1" "$1.gz"
}

function buildSass {

	# if no Sass files defined for build - exit
	[[ -z $BUILD_SASS_LIST ]] && return

	IFS=$'\n'
	local sassBuildItem

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
				mkdir -p "$(dirname "$cssTarget")"

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

	unset IFS
}

function buildJavaScript {

	# if no JavaScript build files defined - exit
	[[ -z $BUILD_JAVASCRIPT_LIST ]] && return

	IFS=$'\n'
	local javaScriptBuildItem

	for javaScriptBuildItem in $BUILD_JAVASCRIPT_LIST; do
		unset IFS

		# ensure $javaScriptBuildItem is in [SOURCE_JAVASCRIPT_LIST|TARGET_JAVASCRIPT] format
		if [[ $javaScriptBuildItem =~ ^([^|]+)\|([^|]+)$ ]]; then
			local javaScriptBuildTarget=$(getPathCanonical "$buildDir/${BASH_REMATCH[2]}" "nocheck")
			local javaScriptTempConcatTarget=$(getTempFile)
			local buildStepHeaderWritten

			# work over each source JavaScript list item glob
			IFS=","
			local javaScriptSourceGlobItem

			for javaScriptSourceGlobItem in ${BASH_REMATCH[1]}; do
				unset IFS

				# grab file(s) matched by source JavaScript source item
				IFS=$'\n'
				local javaScriptSourceFileItem
				local globMatch

				# note: don't quote [$sourceDirCanonical/$javaScriptSourceGlobItem] as may contain glob patterns
				for javaScriptSourceFileItem in $sourceDirCanonical/$javaScriptSourceGlobItem; do
					unset IFS

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
				mkdir -p "$(dirname "$javaScriptBuildTarget")"

				# minify temporary JavaScript concatenate target to final build location then compress
				cat "$javaScriptTempConcatTarget" | \
					java -jar "$JAR_GOOGLE_CLOSURE" \
					--js_output_file "$javaScriptBuildTarget"

				gzipResource "$javaScriptBuildTarget"

			else
				writeWarning "Unable to create $javaScriptBuildTarget from source JavaScript file(s)"
				echo
			fi

			# delete temporary JavaScript concatenate target
			rm -f "$javaScriptTempConcatTarget"

		else
			writeWarning "Invalid JavaScript build item definition: $javaScriptBuildItem"
			echo
		fi
	done

	unset IFS
}

function SSHRsyncBuildDirToServer {

	# create temp file to hold server exclude filter rules for rsync - empty file if not defined
	local filterTmp=$(getTempFile)
	[[ -n $SERVER_EXCLUDE_FILTER ]] && echo "$SERVER_EXCLUDE_FILTER" >"$filterTmp"

	rsync -irtz \
		--chmod "$SERVER_RSYNC_CHMOD" \
		--delete \
		${optionRsyncDryRunOnly:+--dry-run} \
		--exclude-from "$filterTmp" \
		--rsh "ssh -l $SERVER_SSH_USER -p $SERVER_SSH_PORT" \
		"$buildDir/" "$SERVER_HOSTNAME::$SERVER_RSYNC_MODULE" || :

	echo

	rm -f "$filterTmp"
}


# parse command line options
optionRsyncDryRunOnly=
optionRetainBuildResultDir=
while getopts ":dth" optKey; do
	case $optKey in
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
[[ -z $(which rsync) ]] && exitError "Unable to locate rsync, installed?"
[[ -z $(which java) ]] && exitError "Unable to locate Java, installed?"
[[ -z $(which sass) ]] && exitError "Unable to locate Sass, installed?"

# load and validate (optional) global and application configuration files
loadConfiguration
validateConfiguration

# everything validated - lets start the build process
echo "Application source: $sourceDirCanonical"
[[ $optionRsyncDryRunOnly ]] && writeNotice "Rsync dry-run deployment only"
[[ $optionRetainBuildResultDir ]] && writeNotice "Retaining temporary build directory after deployment"

# create build directory
buildDir=$(mktemp -d --tmpdir "$MKTEMP_TEMPLATE")
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
	echo "Build directory located at: $buildDir"

else
	# remove build directory
	echo "Removing build target work area: $buildDir"
	rm -rf "$buildDir"
fi

# success
exit 0
