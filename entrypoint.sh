#!/bin/bash

# Parse the tag we're on, do nothing if there isn't one
TAG=$(echo ${GITHUB_REF} | grep tags | grep -o "[^/]*$")
if [[ -z "${TAG}" ]]; then
    echo "Not a tag push, skipping"
    exit 0
fi

# Validate the version string we're building
if ! echo "${TAG}" | grep -P --quiet '^(v)?\d+\.\d+\.\d+$'; then
    echo "Bad version, needs to be (v)%u.%u.%u"
    exit 1
fi

# Strip "v" if it is prepended to the semver
VERSION=$TAG
if [[ "${TAG:0:1}" == "v" ]]; then
  VERSION="${TAG:1}"
fi

INFO_VERSION=$(jq -r '.version' info.json)
# Make sure the info.json is parseable and has the expected version number
if ! [[ "${INFO_VERSION}" == "${VERSION}" ]]; then
    echo "Tag version ${VERSION} doesn't match info.json version ${INFO_VERSION} (or info.json is invalid), failed"
    exit 1
fi
# Pull the mod name from info.json
NAME=$(jq -r '.name' info.json)

# Create the zip
git archive --prefix "${NAME}_$VERSION/" -o "/github/workspace/${NAME}_$VERSION.zip" "${TAG}"
FILESIZE=$(stat --printf="%s" "${NAME}_${VERSION}.zip")
echo "File zipped, ${FILESIZE} bytes"
unzip -v "${NAME}_${VERSION}.zip"

# Get a CSRF token by loading the login form
CSRF=$(curl -b cookiejar.txt -c cookiejar.txt -s https://factorio.com/login?mods=1 | grep csrf_token | sed -r -e 's/.*value="(.*)".*/\1/')

# Authenticate with the credential secrets and the CSRF token, getting a session cookie for the authorized user
curl -b cookiejar.txt -c cookiejar.txt -s -e https://factorio.com/login?mods=1 -F "csrf_token=${CSRF}" -F "username_or_email=${FACTORIO_USER}" -F "password=${FACTORIO_PASSWORD}" -o /dev/null https://factorio.com/login

# Query the mod info, verify the version number we're trying to push doesn't already exist
curl -b cookiejar.txt -c cookiejar.txt -s "https://mods.factorio.com/api/mods/${NAME}/full" | jq -e ".releases[] | select(.version == \"${VERSION}\")"
# store the return code before running anything else
STATUS_CODE=$?

if [[ $STATUS_CODE -ne 4 ]]; then
    echo "Release already exists, skipping"
    exit 0
fi
echo "Release doesn't exist for ${VERSION}, uploading"

# Load the upload form, getting an upload token
UPLOAD_TOKEN=$(curl -b cookiejar.txt -c cookiejar.txt -s "https://mods.factorio.com/mod/${NAME}/downloads/edit" | grep token | sed -r -e "s/.*token: '(.*)'.*/\1/")
if [[ -z "${UPLOAD_TOKEN}" ]]; then
    echo "Couldn't get an upload token, failed"
    exit 1
fi

# Upload the file, getting back a response with details to send in the final form submission to complete the upload
UPLOAD_RESULT=$(curl -b cookiejar.txt -c cookiejar.txt -s -F "file=@${NAME}_${VERSION}.zip;type=application/x-zip-compressed" "https://direct.mods-data.factorio.com/upload/mod/${UPLOAD_TOKEN}")

# Parse 'em and stat the file for the form fields
CHANGELOG=$(echo "${UPLOAD_RESULT}" | jq -r '@uri "\(.changelog)"')
INFO=$(echo "${UPLOAD_RESULT}" | jq -r '@uri "\(.info)"')
FILENAME=$(echo "${UPLOAD_RESULT}" | jq -r '.filename')
THUMBNAIL=$(echo "${UPLOAD_RESULT}" | jq -r '.thumbnail // empty')

if [[ "${FILENAME}" == "null" ]] || [[ -z "${FILENAME}" ]]; then
    echo "Upload failed"
    exit 1
fi
echo "Uploaded ${NAME}_${VERSION}.zip to ${FILENAME}, submitting as new version"

# Post the form, completing the release
curl -b cookiejar.txt -c cookiejar.txt -s -X POST -d "file=&info_json=${INFO}&changelog=${CHANGELOG}&filename=${FILENAME}&file_size=${FILESIZE}&thumbnail=${THUMBNAIL}" -H "Content-Type: application/x-www-form-urlencoded" -o /dev/null "https://mods.factorio.com/mod/${NAME}/downloads/edit"
# TODO if that had a failure exit code then report failure, exit 1

echo "Completed"
