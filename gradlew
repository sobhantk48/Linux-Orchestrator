#!/usr/bin/env sh

#
# Copyright 2015 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Add default JVM options here. You can also use JAVA_OPTS and GRADLE_OPTS to pass any JVM options to Gradle.
DEFAULT_JVM_OPTS=""

APP_NAME="Gradle"
APP_BASE_NAME=`basename "$0"`

# Use the maximum available, or set MAX_FD != -1 to use that value.
MAX_FD="maximum"

warn () {
    echo "$*"
}

die () {
    echo
    echo "ERROR: $*"
    echo
    exit 1
}

# OS specific support (must be 'true' or 'false').
cygwin=false
msys=false
darwin=false
nonstop=false
case "`uname`" in
  CYGWIN* )
    cygwin=true
    ;;
  Darwin* )
    darwin=true
    ;;
  MINGW* )
    msys=true
    ;;
  NONSTOP* )
    nonstop=true
    ;;
esac

CLASSPATH_SEPARATOR=:
if $cygwin || $msys; then
  CLASSPATH_SEPARATOR=";"
fi

# Attempt to set APP_HOME
# Resolve links: $0 may be a link
PRG="$0"
# Need this for relative symlinks.
while [ -h "$PRG" ] ; do
    ls=`ls -ld "$PRG"`
    link=`expr "$ls" : '.*-> \(.*\)$'`
    if expr "$link" : '/.*' > /dev/null; then
        PRG="$link"
    else
        PRG=`dirname "$PRG"`"/$link"
    fi
done

APP_HOME=`dirname "$PRG"`

# For Cygwin, ensure paths are in UNIX format before anything is touched
if $cygwin ; then
    [ -n "$APP_HOME" ] &&
        APP_HOME=`cygpath --unix "$APP_HOME"`
    [ -n "$JAVA_HOME" ] &&
        JAVA_HOME=`cygpath --unix "$JAVA_HOME"`
    [ -n "$GRADLE_HOME" ] &&
        GRADLE_HOME=`cygpath --unix "$GRADLE_HOME"`
fi

# We use  ( )  instead of  { }  on the path resolution to avoid potential
# interpretation issues on systems that have a space in a path component.
APP_HOME=`cd "$APP_HOME" && pwd`

# Add a hint for the user if the gradle script is moved out of the distribution
if [ ! -f "$APP_HOME/gradle/wrapper/gradle-wrapper.jar" ]; then
    warn "The \`$APP_BASE_NAME\` script is meant to be run from the root of the project."
    warn "It appears it has been moved, and the script may not work correctly."
    warn ""
    warn "You can try to set the \$GRADLE_USER_HOME environment variable to the path of the distribution."
    warn "Current directory is `pwd`"
    warn "Script location is $APP_HOME"
fi


# Read relative path to wrapper jar from properties file
WRAPPER_JAR_PATH=
WRAPPER_PROPS_PATH="$APP_HOME/gradle/wrapper/gradle-wrapper.properties"
if [ -f "$WRAPPER_PROPS_PATH" ]; then
    while IFS= read -r line; do
        # Stop processing at the first empty line
        [ -z "$line" ] && break
        # Skip lines starting with #
        echo "$line" | grep -q "^#" && continue

        # Process lines containing distributionUrl
        if echo "$line" | grep -q "distributionUrl"; then
            # Extract the path from the URL
            url_path=$(echo "$line" | sed -n 's/distributionUrl=.*\/\(.*\)/\1/p')
            # Construct the relative path to the jar
            dir_name=$(echo "$url_path" | sed -n 's/\(.*\)-[a-z]*.zip/\1/p')
            WRAPPER_JAR_PATH="wrapper/dists/$url_path/$dir_name/lib/gradle-wrapper.jar"
            break
        fi
    done < "$WRAPPER_PROPS_PATH"
fi


# If the wrapper jar path was not found, fall back to a default
if [ -z "$WRAPPER_JAR_PATH" ]; then
    WRAPPER_JAR_PATH="wrapper/dists/gradle-8.7-bin/9wbydzuqumvpcc4bbls7dft0b/gradle-wrapper-8.7.jar"
fi
GRADLE_WRAPPER_JAR_PATH="$APP_HOME/gradle/$WRAPPER_JAR_PATH"

# Set GRADLE_USER_HOME if not set
if [ -z "$GRADLE_USER_HOME" ] ; then
    GRADLE_USER_HOME="$HOME/.gradle"
fi

# Set the GRADLE_OPTS environment variable if not set
if [ -z "$GRADLE_OPTS" ] ; then
    GRADLE_OPTS="-Dorg.gradle.daemon=true"
fi

# Find a valid Java installation
if [ -n "$JAVA_HOME" ] ; then
    if [ -x "$JAVA_HOME/jre/sh/java" ] ; then
        # IBM's JDK on AIX uses strange locations for the executables
        JAVACMD="$JAVA_HOME/jre/sh/java"
    else
        JAVACMD="$JAVA_HOME/bin/java"
    fi
    if [ ! -x "$JAVACMD" ] ; then
        die "ERROR: JAVA_HOME is set to an invalid directory: $JAVA_HOME

Please set the JAVA_HOME variable in your environment to match the
location of your Java installation."
    fi
else
    JAVACMD="java"
    which java >/dev/null 2>&1 || die "ERROR: JAVA_HOME is not set and no 'java' command could be found in your PATH.

Please set the JAVA_HOME variable in your environment to match the
location of your Java installation."
fi

# Increase the maximum number of open files
if ! $cygwin && ! $msys; then
    if [ "$MAX_FD" = "maximum" -o "$MAX_FD" = "max" ]; then
        # Increase the maximum number of open file descriptors to the allowed limit.
        ulimit -n `ulimit -Hn`
    elif [ "$MAX_FD" != "unlimited" -a "$MAX_FD" != "n/a" ]; then
        if [ $MAX_FD -gt `ulimit -Hn` ]; then
            warn "Value of MAX_FD is too large ($MAX_FD), using `ulimit -Hn`"
        fi
        ulimit -n $MAX_FD
    fi
fi

# For Cygwin, switch paths to Windows format before running java
if $cygwin ; then
    APP_HOME=`cygpath --path --windows "$APP_HOME"`
    JAVA_HOME=`cygpath --path --windows "$JAVA_HOME"`
    GRADLE_USER_HOME=`cygpath --path --windows "$GRADLE_USER_HOME"`
    GRADLE_WRAPPER_JAR_PATH=`cygpath --path --windows "$GRADLE_WRAPPER_JAR_PATH"`
fi

# Split up the JVM options only if the variable is not empty.
if [ -n "$DEFAULT_JVM_OPTS" ] ; then
    JAVA_OPTS=($DEFAULT_JVM_OPTS $JAVA_OPTS)
fi

# Escape the arguments that are passed to Gradle. This is necessary to preserve
# quoted arguments that might contain spaces. This is done by replacing every
# single quote with '\'', and by wrapping the whole argument in single quotes.
# This is a simplified version of what GNU Make does.
for arg in "$@"
do
  # The "" is intentionally not quoted. This is to allow for shell expansion
  # of the contents of the argument.
  # shellcheck disable=SC2086
  ESCAPED_ARG="'"$(echo $arg | sed "s/'/'\\\\''/g")"'"
  # The "" is intentionally not quoted. This is to allow for shell expansion
  # of the contents of the variables.
  # shellcheck disable=SC2086
  GRADLE_ARGS="$GRADLE_ARGS $ESCAPED_ARG"
done

# Collect all arguments for the java command, following recommended memory settings.
GRADLE_JAVA_OPTS=("-Xmx64m" "-Xms64m")
if [ -n "$JAVA_OPTS" ]; then
    GRADLE_JAVA_OPTS=($JAVA_OPTS)
fi
if [ -n "$GRADLE_OPTS" ]; then
    # The "" is intentionally not quoted. This is to allow for shell expansion of the contents of the variable.
    # shellcheck disable=SC2086
    GRADLE_JAVA_OPTS=(${GRADLE_OPTS})
fi

exec "$JAVACMD" "${GRADLE_JAVA_OPTS[@]}" -Dorg.gradle.appname="$APP_BASE_NAME" -classpath "$GRADLE_WRAPPER_JAR_PATH" org.gradle.wrapper.GradleWrapperMain $GRADLE_ARGS
