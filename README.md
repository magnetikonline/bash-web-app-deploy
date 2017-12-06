# Bash web application deployer
A web application build & deployment script written in pure Bash, with per-project setup controlled by a simple configuration file.

- [Features](#features)
- [Requirements](#requirements)
- [Configuration](#configuration)
	- [Source application](#source-application)
		- [Settings](#settings)
		- [Pre-deploy hook](#pre-deploy-hook)
	- [Target server](#target-server)
- [Deploying](#deploying)

## Features
Script is rather opinionated in what is provided - fitting preferences for components/technologies/tools used with web applications I'm actively developing - it might prove useful for a few developers, or possibly no-one:

- Deployment of source files to target server controlled by a simple include/exclude path filter list.
- Compilation of one or more [Sass](http://sass-lang.com/) style sheets to build target with automated minification.
- Concatenation and minification of one or more source JavaScript file(s) to build target.
- Automatic creation of gzipped CSS/JavaScript resources placed alongside uncompressed versions for use with the Nginx [`ngx_http_gzip_static_module` module](https://nginx.org/en/docs/http/ngx_http_gzip_static_module.html) all at the maximum compression level offered by `gzip`.
- An optional pre-deployment hook bash function to apply any final programmatic changes to built application, such as [Git SHA1 based build versioning](#pre-deploy-hook).
- Rsync over SSH based deployments from source to target.

## Requirements
- Deployment system of Debian/Ubuntu Linux (or variant).
- [Rsync](https://download.samba.org/pub/rsync/rsync.html) installed on both deployment source and target systems.
- [Sass](http://sass-lang.com) for compilation of source `.scss` style sheets to `.css`. Using original Ruby based version.
- [Sass Globbing](https://github.com/chriseppstein/sass-globbing) plugin for (Ruby based) Sass - enables wildcard `@include` of Sass documents.
- [YUI Compressor](https://yui.github.io/yuicompressor/) and [Google Closure Compiler](https://developers.google.com/closure/compiler/) for CSS and JavaScript minification tasks respectively.
- A Java CLI - required by both YUI Compressor and Google Closure Compiler.
- Working SSH access to target system via suitable keys.

## Configuration
Setup of script is in two parts - the source application and target server.

### Source application
It's assumed the script will be placed at a central location to be shared, via a symlink placed in each web application's source repository. For example:

```sh
$ git clone https://github.com/magnetikonline/bashwebappdeploy.git /target/path/for/bashwebappdeploy
$ cd /path/to/my/web/application
$ ln -s /target/path/for/bashwebappdeploy/deploy.sh ./script
$ git add ./script/deploy.sh
$ git commit -m 'Added symlink for bashwebappdeploy'
```

Configuration is via `deploy.config` file(s), loaded from (in the following order):
- Inline with the full canonical path to `deploy.sh`, and..
- Inline with symlink to `deploy.sh` (from above example, this would be `./script/deploy.sh`).

This allows for both global (system); and per-application configuration settings.

#### Settings
- `JAR_YUI_COMPRESSOR` - Location of [YUI Compressor](https://yui.github.io/yuicompressor/) jar archive on source system.
- `JAR_GOOGLE_CLOSURE` - Location of [Google Closure Compiler](https://developers.google.com/closure/compiler/) jar archive on source system.
- `SOURCE_DIR` - Application source, relative to `deploy.sh` (or called symlink to it). For example if `deploy.sh` symlink and `deploy.config` are located under a `/script/` directory, `SOURCE_DIR` could simply be given as `"../"` to reference the application source root.
- `BUILD_SOURCE_FILTER` - Include/exclude rules for directories and files to be added from application source to the build. Specified via Rsync format filter rules - refer to `FILTER RULES` at the [Rsync man page](https://download.samba.org/pub/rsync/rsync.html) for filter rule format/usage.
- `BUILD_SASS_LIST` - Sass style sheets for compilation to CSS, minified and gzip version created during the build process.

	Each line item given as a SCSS document source path and target CSS document path within the build target, separated via a pipe (`|`) character. Example:

	```
	/public/css/style.scss|/public/css/style.css
	/assets/scss/themes.scss|/docroot/themes.css
	```

- `BUILD_JAVASCRIPT_LIST` - JavaScript source files to be (optionally) combined, minified and gzip version created during the build process.

	Each JavaScript file is specified as one or more code paths from the application source - comma (`,`) separated and followed by a target JavaScript source path within the build target, separated via a pipe (`|`) character. Source JavaScript code paths in addition supports [globs](https://en.wikipedia.org/wiki/Glob_(programming)). Example:

	```
	/public/js/lib/picoh.js,/public/js/app/*.js|/public/js/app.js
	/src/javascript/page.js|/docroot/page.js
	```

- `SERVER_HOSTNAME` - Target SSH server where application will be deployed to.
- `SERVER_SSH_USER` - SSH deployment username.
- `SERVER_SSH_PORT` - Deployment target SSH listening port (typically will be `22`).
- `SERVER_RSYNC_MODULE` - Receiving Rsync module name at target server (see [Target server](#target-server) section below).
- `SERVER_RSYNC_CHMOD` - The permissions Rsync will set on directories/files transfered to target, using the syntax of Rsync's `--chmod` argument.

	For example to set:
	* Read/execute permissions for _all directories_.
	* Read permissions for _all files_.
	* Write permissions for _both_ directories/files for the *owner only*.

	```
	a-rwx,Da+rx,Fa+r,u+w
	```

- `SERVER_EXCLUDE_FILTER` - Exclude rules for directories and files on target server that will not be considered. Useful for items such as logs or application generated files (e.g. caches), ensuring Rsync transfer does not clean-up/delete given paths. Specified via a simplified form of Rsync filter rules - refer to `FILTER RULES` at the [Rsync man page](https://download.samba.org/pub/rsync/rsync.html).

#### Pre-deploy hook
In addition to above settings a bash function of `preDeployHook` can be defined, which will be called just prior to Rsync deployment of the generated build to the target server - allowing for any final custom/programmatic modifications. The function is passed arguments of the source application root and build target directories.

As an example, to apply the current application source Git SHA1 to placeholder(s) within a HTML file for use as a build identifier:

```sh
function preDeployHook {

	# fetch current Git revision SHA1
	local gitSHA1=$(git --git-dir "$1/.git" rev-parse HEAD)

	# apply SHA1 to /index.html at token location of [BUILD_SHA1]
	# note: only using first 16 characters of SHA1
	local sedSearch="\[BUILD_SHA1\]"
	local sedReplace="${gitSHA1:0:16}"

	sed \
		--in-place \
		--regexp-extended \
		"s/$sedSearch/$sedReplace/" "$2/index.html"
}
```

The provided [deploy.config](example/script/deploy.config) example should help understand all these settings and their usage together.

### Target server
Configuration of target server involves the creation of an Rsync module to receive the built application files and place them in the desired web root/directory.

The following example would exist in the home folder of our `SERVER_SSH_USER` named `~/rsyncd.conf` and provides:
- Two modules named `site-domain.com` and `site-anotherdomain.com` respectively.
- Read and write permissions to both modules.
- Fairly detailed logging of all transfer activity to a `~/rsyncd.log` file.

```
list = false
log file = rsyncd.log
log format = %i %f [%l]
read only = false
transfer logging = true
use chroot = false


[site-domain.com]
path = /srv/http/domain.com

[site-anotherdomain.com]
path = /srv/http/anotherdomain.com
```

## Deploying
Starting a deployment is as easy as running `./deploy.sh`. The script will generate the application build in a temporary directory as defined from source - then push the result to the target server via Rsync over SSH.

A few optional command line switches are provided:

```
Usage: deploy.sh [OPTION]...

  -d    dry run deployment
  -t    retain build directory after completion
  -h    display help
```

- The `-d` switch will complete all steps, but _simulate_ the Rsync deployment step by using Rsync's `--dry-run` mode.
- To complete a build/deploy process, but retain the temporary directory of built application, provide the `-t` switch - handy to couple with `-d` while authoring a new deployment configuration.
