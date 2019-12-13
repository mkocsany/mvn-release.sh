#!/bin/bash

function die_with() {
	echo "$*" >&2
	exit 1
}

function has_command() {
	which "$1" >/dev/null 2>/dev/null || return 1
	return 0
}

function has_xmllint_with_xpath() {
	if [ "$(xmllint 2>&1 | grep xpath | wc -l)" = "0" ] ; then
		return 1
	else
		return 0
	fi
}

function die_unless_xmllint_has_xpath() {
	has_command xmllint || die_with "Missing xmllint command, please install it (from libxml2)"

	has_xmllint_with_xpath || die_with "xmllint command is missing the --xpath option, please install the libxml2 version"
}

function die_without_command() {
	while [ -n "$1" ]
	do
		has_command "$1" || die_with "Missing required command: $1"
		shift
	done
}

function rollback_and_die_with() {
	echo "$*" >&2

	echo "Resetting release commit to return you to the same working state as before attempting a deploy"
	echo "> git reset --hard HEAD^1"
	git reset --hard HEAD^1 || echo "Git reset command failed!"

	exit 1
}

function usage() {
	echo "Maven git release script v1.0 (c) 2014 Peter Wright"
	echo ""
	echo "Usage:"
	echo "  $0 [-a | [ -r RELEASE_VERSION ] [ -n NEXT_DEV_VERSION ] ]  [ -c ASSUMED_POM_VERSION ] [ -s ] [-i]"
	echo "Updates release version, then builds and commits it"
	echo ""
	echo "  -a    Shorthand for -a auto -n auto"
	echo "  -r    Sets the release version number to use ('auto' to use the version in pom.xml)"
	echo "  -n    Sets the next development version number to use (or 'auto' to increment release version)"
	echo "  -c    Assume this as pom.xml version without inspecting it with xmllint"
	echo "  -i    Ignore untracked git files"
	echo ""
	echo "  -h    For this message"
	echo ""
}

###############################
# HANDLE COMMAND-LINE OPTIONS #
###############################

while getopts "ahr:n:c:i" o; do
	case "${o}" in
		a)
			RELEASE_VERSION="auto"
			NEXT_VERSION="auto"
			;;
		r)
			RELEASE_VERSION="${OPTARG}"
			;;
		n)
			NEXT_VERSION="${OPTARG}"
			;;
		c)
			CURRENT_VERSION="${OPTARG}"
			;;
		i)
			IGNORE_UNTRACKED=true
			;;
		h)
			usage
			exit 0
			;;
		*)
			usage
			die_with "Unrecognised option ${o}"
			;;
	esac
done
shift $((OPTIND-1))

###############################################
# MAKE SURE SCRIPT DEPENDENCIES ARE INSTALLED #
###############################################

die_without_command git perl wc

if [ -z "$MVN" ] ; then
	die_without_command mvn
	MVN=mvn
else
	die_without_command $MVN
fi

echo "Using maven command: $MVN"


#########################################
# BAIL IF THERE ARE UNCOMMITTED CHANGES #
#########################################

# If there are any uncommitted changes we must abort immediately, if IGNORE_UNTRACKED is true git will ignore untracked files
if [ "$IGNORE_UNTRACKED" = true ] ; then
	if [ $(git status -suno | wc -l) != "0" ] ; then
		git status -suno
		die_with "There are uncommitted changes, please commit or stash them to continue with the release:"
	else
		echo "Good, no uncommitted changes found"
	fi
else
	if [ $(git status -s | wc -l) != "0" ] ; then
		git status -s
		die_with "There are uncommitted changes, please commit or stash them to continue with the release:"
	else
		echo "Good, no uncommitted changes found"
	fi
fi


#################################################################
# FIGURE OUT RELEASE VERSION NUMBER AND NEXT DEV VERSION NUMBER #
#################################################################

if [ -z "$CURRENT_VERSION" ] ; then
	# Extract the current version (requires xmlllint with xpath suport)
	die_unless_xmllint_has_xpath
	CURRENT_VERSION=$(xmllint --xpath "/*[local-name() = 'project']/*[local-name() = 'version']/text()" pom.xml)
fi

echo "Current pom.xml version: $CURRENT_VERSION"
echo ""

# Prompt for release version (or compute it automatically if requested)
RELEASE_VERSION_DEFAULT=$(echo "$CURRENT_VERSION" | perl -pe 's/-SNAPSHOT//')
if [ -z "$RELEASE_VERSION" ] ; then
	read -p "Version to release [${RELEASE_VERSION_DEFAULT}]:" RELEASE_VERSION

	if [ -z "$RELEASE_VERSION" ] ; then
		RELEASE_VERSION=$RELEASE_VERSION_DEFAULT
	fi
elif [ "$RELEASE_VERSION" = "auto" ] ; then
	RELEASE_VERSION=$RELEASE_VERSION_DEFAULT
fi

if [ "$RELEASE_VERSION" = "$CURRENT_VERSION" ] ; then
	die_with "Release version requested is exactly the same as the current pom.xml version (${CURRENT_VERSION})! Is the version in pom.xml definitely a -SNAPSHOT version?"
fi


# Prompt for next version (or compute it automatically if requested)
NEXT_VERSION_DEFAULT=$(echo "$RELEASE_VERSION" | perl -pe 's{^(([0-9]\.)+)?([0-9]+)$}{$1 . ($3 + 1)}e')
if [ -z "$NEXT_VERSION" ] ; then
	read -p "Next snapshot version [${NEXT_VERSION_DEFAULT}]:" NEXT_VERSION

	if [ -z "$NEXT_VERSION" ] ; then
		NEXT_VERSION=$NEXT_VERSION_DEFAULT
	fi
elif [ "$NEXT_VERSION" = "auto" ] ; then
	NEXT_VERSION=$NEXT_VERSION_DEFAULT
fi

# Add -SNAPSHOT to the end (and make sure we don't accidentally have it twice)
NEXT_VERSION="$(echo "$NEXT_VERSION" | perl -pe 's/-SNAPSHOT//gi')-SNAPSHOT"

if [ "$NEXT_VERSION" = "${RELEASE_VERSION}-SNAPSHOT" ] ; then
	die_with "Release version and next version are the same version!"
fi


echo ""
echo "Using $RELEASE_VERSION for release"
echo "Using $NEXT_VERSION for next development version"

#############################
# START THE RELEASE PROCESS #
#############################

VCS_RELEASE_TAG="v${RELEASE_VERSION}"

# if a release tag of this version already exists then abort immediately
if [ $(git tag -l "${VCS_RELEASE_TAG}" | wc -l) != "0" ] ; then
	die_with "A tag already exists ${VCS_RELEASE_TAG} for the release version ${RELEASE_VERSION}"
fi
 
# Commit the updated pom.xml files

echo "-------------------------------"
echo "------Push release branch -----"
echo "-------------------------------"

git checkout -b release/${VCS_RELEASE_TAG}
git merge develop
# Update the pom.xml versions
$MVN versions:set -DgenerateBackupPoms=false -DnewVersion=$RELEASE_VERSION || die_with "Failed to set release version on pom.xml files"
git commit -a -m "Release version ${RELEASE_VERSION}" || die_with "Failed to commit updated pom.xml versions for release!"
git push origin release/${VCS_RELEASE_TAG} || rollback_and_die_with "Build/Deploy failure. Release failed."


echo "-------------------------------"
echo "------Push Master branch-------"
echo "-------------------------------"

git checkout master
git merge release/${VCS_RELEASE_TAG}
git push origin master || rollback_and_die_with "Build/Deploy failure. Release failed."

# tag the release (N.B. should this be before perform the release?)
git tag "v${RELEASE_VERSION}" || die_with "Failed to create tag ${RELEASE_VERSION}! Release has been deployed, however"
git push --tags || die_with "Failed to push tags. Please do this manually"


######################################
# START THE NEXT DEVELOPMENT PROCESS #
######################################

echo "--------------------------------"
echo "---Set new version to develop---"
echo "--------------------------------"

git checkout develop
git merge master
$MVN versions:set -DgenerateBackupPoms=false "-DnewVersion=${NEXT_VERSION}" || die_with "Failed to set next dev version on pom.xml files, please do this manually"
git commit -a -m "Start next development version ${NEXT_VERSION}" || die_with "Failed to commit updated pom.xml versions for next dev version! Please do this manually"

git push origin develop || die_with "Failed to push commits. Please do this manually"

read -p 'Ready ....'