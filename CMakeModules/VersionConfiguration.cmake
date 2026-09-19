# Get the current date.
string(TIMESTAMP CURRENT_DATE "%Y-%m-%d")

option(UPGRADE_DEBUG "" OFF)

# Read version from VERSION file
file(READ "${CMAKE_SOURCE_DIR}/VERSION" VERSION_STRING)
string(STRIP "${VERSION_STRING}" VERSION_STRING)

# The tag wins, when there is one.
#
# The two numbers had drifted apart and nothing in the build could notice. A
# release is cut by pushing a tag; every file the release contains is named
# from the VERSION file; and nothing connected the two. So `v1.0.2-mahfin`
# published `MahfinDesktop-1.0.0-x64.exe`, the About box said 1.0.0, and the
# update check compared against 1.0.0 — three different ways for a build to
# claim it is a version that was released twice already, none of them visible
# until somebody reads the assets list and wonders.
#
# Taking the number from the ref that caused the build closes it for good:
# there is no longer a second place to remember to edit, because the thing that
# names the release is the thing that names the binaries. `v1.0.2-mahfin`
# becomes `1.0.2` — the leading `v` and the fork suffix are how the tag is
# spelled, not part of the version, and Inno Setup and CPack both want a bare
# dotted triple.
#
# Only for a tag. A branch build keeps whatever the VERSION file says, which is
# what a developer building locally wants and what a CI run on `main` should
# report.
if(DEFINED ENV{GITHUB_REF_TYPE} AND "$ENV{GITHUB_REF_TYPE}" STREQUAL "tag")
  set(TAG_NAME "$ENV{GITHUB_REF_NAME}")
  string(REGEX MATCH "([0-9]+\\.[0-9]+\\.[0-9]+)" TAG_VERSION "${TAG_NAME}")
  if(TAG_VERSION)
    if(NOT TAG_VERSION STREQUAL VERSION_STRING)
      message(STATUS "Building from tag ${TAG_NAME}: using ${TAG_VERSION} "
                     "rather than ${VERSION_STRING} from the VERSION file")
    endif()
    set(VERSION_STRING "${TAG_VERSION}")
  else()
    # A tag nobody can read a version out of is worth saying out loud rather
    # than quietly falling back — it means a release is about to be published
    # under a number that has nothing to do with its name.
    message(WARNING "Tag '${TAG_NAME}' carries no version number; "
                    "falling back to ${VERSION_STRING} from the VERSION file")
  endif()
endif()

# Extract major.minor.patch for places that need it
string(REGEX MATCH "^[0-9]+\\.[0-9]+\\.[0-9]+" VERSION_BASE "${VERSION_STRING}")
if(NOT VERSION_BASE)
  set(VERSION_BASE "0.0.0")
endif()

set(VERSION_STRING_SHORT "${VERSION_BASE}")
set(CANONICAL_VERSION_STRING "${VERSION_BASE}")

configure_file(src/core/Version.cpp.in src/core/Version.cpp)
